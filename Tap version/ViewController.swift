//  ViewController.swift
//  SUWARERU
//  Created by Sugitani on 2026/01/15.
//
//  空席ナビ画面の司令塔。ここにはライフサイクル、毎フレームの処理の順序、ボタン操作だけを置き、
//  各機能の実体は以下に分けている:
//    Detection/     YOLOによる検出と空席判定、推論ループ
//    Localization/  画面上の点 → 3Dワールド座標
//    Tracking/      検出のトラック化（対応付け・寿命管理・案内対象の選択）
//    Guidance/      角度・距離の計算、音声、振動、空席なし監視、状況確認
//    UI/            BBox表示、3Dラベル、アクセシビリティ
//    OGM/           占有格子地図

import UIKit
import SceneKit
import ARKit
import AVFoundation

final class ViewController: UIViewController, ARSCNViewDelegate {

    // MARK: - IBOutlets
    @IBOutlet weak var sceneView: ARSCNView!
    @IBOutlet weak var debugTextView: UITextView!
    @IBOutlet weak var TextView: UITextView!
    @IBOutlet weak var arrivalPanelView: UIView!
    @IBOutlet weak var startGuidanceButton: UIButton!
    @IBOutlet weak var arrivalContinueButton: UIButton!
    @IBOutlet weak var arrivalFinishButton: UIButton!
    @IBOutlet weak var exitButton: UIButton!

    // MARK: - 機能モジュール
    var seatDetector: SeatDetector!
    var positionEstimator: WorldPositionEstimator!
    let trackMatcher = TrackMatcher()
    let directionHaptics = DirectionHapticsController()
    let speechOutput = SpeechOutput()
    let arrivalFeedback = UINotificationFeedbackGenerator()

    // MARK: - Scene / Display
    let autoLabelsRoot = SCNNode() // 自動ラベルの親ノード
    var bboxOverlay: BoundingBoxOverlayView!
    var viewSize: CGSize = .zero // メインでのみ更新（BGからUIViewを触らない）

    var isGuidancePaused = true
    var shouldStartGuidanceOnAppear = false

    // MARK: - CoreML / Vision
    let dispatchQueueML = DispatchQueue(label: "com.hw.dispatchqueueml")
    let stateQueue = DispatchQueue(label: "com.hw.statequeue")
    var isMLLoopRunning = false
    var lastMLTime: TimeInterval = 0
    let mlInterval: TimeInterval = 0.4

    // ======= トラッキングのポリシー =======
    let seatLabels: Set<String> = ["chair"]
    let maxTracksPerLabel: Int = 1  // ラベルごとの同時3Dテキスト上限
    let maxTextsPerFrame: Int = 2   // 全体の同時3Dテキスト上限
    let trackTimeout: TimeInterval = 4.0   // 見失い判定 (秒)
    let cooldown: TimeInterval = 0.6       // 同ラベル新規作成のクールダウン (秒)

    // ======= トラッキングの状態（stateQueue で保護） =======
    var pendingDetections: [Detection] = []
    var tracks: [UUID: Track] = [:]
    var lastProcessTime: TimeInterval = 0
    var lastEmptySeatCount: Int = 0
    var lastPersonCount: Int = 0

    // ======= 音声案内（TTS）関連 =======
    // 消えるまで一定間隔で発話したい → false
    var speakOnCreateOnly = false
    // 繰り返し発話の間隔（秒）
    var ttsRepeatInterval: TimeInterval = 3.0
    // クールダウン（speak(track:) で使用）
    var ttsCooldownSeconds: TimeInterval = 3.0
    // Trackごとの最終発話時刻
    var lastSpokenAt: [UUID: TimeInterval] = [:]
    // 到着パネル表示中（ボタン待ち）のとき true
    var isAwaitingArrivalDecision = false
    // パネル表示中に案内を繰り返すためのタイマー
    var arrivalPanelRepeatTimer: Timer?
    // 何秒おきに繰り返すか
    let arrivalPanelRepeatInterval: TimeInterval = 10.0
    // 終了処理中（「お疲れ様でした」再生〜画面を閉じるまで）は true
    var isFinishingNavigation = false

    // [ARRIVAL] 到着アナウンスの有効/無効 と 距離しきい値（m）
    var arrivalAnnounceEnabled: Bool = true
    let arrivalThresholdMeters: Float = 1.3
    var askExitOnArrivalEnabled: Bool = true

    // ======= 空席なし監視用（Timerベース） =======
    var noSeatTimer: Timer?
    var noSeatMonitor = NoSeatMonitor()

    // ======= 状況確認（案内開始前） =======
    var isSituationCheckInProgress = false
    var situationCheckTimer: Timer?
    var situationTally = SituationTally()
    let situationCheckDuration: TimeInterval = 7.0

    // ======= 占有格子地図（OGM） =======
    let ogmEngine = OGMNavigationEngine()
    var lastOGMUpdateTime: TimeInterval = 0

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()

        sceneView.delegate = self
        sceneView.showsStatistics = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.scene = SCNScene()
        sceneView.scene.rootNode.addChildNode(autoLabelsRoot)

        bboxOverlay = BoundingBoxOverlayView(frame: sceneView.bounds)
        bboxOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.addSubview(bboxOverlay)

        // Vision / CoreML セットアップ
        seatDetector = SeatDetector()
        positionEstimator = WorldPositionEstimator(sceneView: sceneView)
        configureAccessibility()
        directionHaptics.prepare()
        arrivalFeedback.prepare()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutStartGuidance),
            name: ShortcutAction.startGuidance.notificationName,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // ここでサイズが有効
        self.viewSize = self.sceneView.bounds.size
        // 連続推論ループ開始
        self.startCoreMLLoopIfNeeded()
        startGuidanceButton.isHidden = !isGuidancePaused
        if shouldStartGuidanceOnAppear {
            shouldStartGuidanceOnAppear = false
            handleShortcutStartGuidance()
        }
        if ShortcutActionCenter.shared.consume(.startGuidance) {
            handleShortcutStartGuidance()
        }
        startGuidanceButton.isHidden = !isGuidancePaused
        if isGuidancePaused {
            startSituationCheckIfNeeded()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]

        // LiDAR 深度（平滑化優先）とメッシュを有効化（対応端末のみ）
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            config.sceneReconstruction = .meshWithClassification
        }

        sceneView.session.run(config)

        // 空席監視の状態リセット
        noSeatMonitor.reset()

        // Timer 開始（すでにあれば無効化して作り直し）
        noSeatTimer?.invalidate()
        noSeatTimer = Timer.scheduledTimer(timeInterval: 1.0,
                                           target: self,
                                           selector: #selector(checkNoSeatState),
                                           userInfo: nil,
                                           repeats: true)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // Timer 停止
        noSeatTimer?.invalidate()
        noSeatTimer = nil
        stopSituationCheck()
        isMLLoopRunning = false

        // 画面を離れるときは読み上げも止める
        stopAllTTS()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sceneView.session.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        viewSize = sceneView.bounds.size // メインでキャッシュ
    }

    // MARK: - Per-frame placement & tracking
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // OGMは検出/トラッキングの間引き（下の0.4s）とは独立に、仕様書通り約10fpsで更新する
        self.updateOGMIfNeeded(time: time)

        // 0.4秒ごとに更新
        if time - self.lastProcessTime < 0.4 { return }
        self.lastProcessTime = time

        let step = runTrackingStep(time: time)

        let targetTrack = selectTargetTrack(time: time)
        self.updateDirectionHaptics(for: targetTrack)
        let statusSummary = "状況確認中\n空席: \(step.currentEmptySeatCount)  人: \(step.currentPersonCount)"
        guard step.didProcessDetections || isGuidancePaused else { return }

        DispatchQueue.main.async {
            if self.isGuidancePaused {
                self.TextView.text = statusSummary
                self.TextView.accessibilityValue = statusSummary
            } else {
                self.TextView.text = step.angleLines   // 空でも毎回更新してOK（好み）
                self.TextView.accessibilityValue = step.angleLines.isEmpty ? "検出なし" : step.angleLines
            }
            if step.shouldShowArrivalPanel {
                self.showArrivalPanel()
            }
        }

        if !isGuidancePaused {
            for track in step.tracksToSpeak {
                self.speak(track: track)
            }
        }
    }

    // MARK: - 案内開始・中断・終了
    @IBAction func onExit(_ sender: UIButton) {
        prepareForExit()
        transitionToStartViewController()
    }

    private func prepareForExit() {
        // 終了処理中
        isFinishingNavigation = true

        // パネル表示中なら解除
        isAwaitingArrivalDecision = false

        // 繰り返しタイマー停止
        arrivalPanelRepeatTimer?.invalidate()
        arrivalPanelRepeatTimer = nil
        noSeatTimer?.invalidate()
        noSeatTimer = nil
        stopSituationCheck()
        directionHaptics.stop()

        isMLLoopRunning = false

        // 音声を即停止
        speechOutput.stop()
        lastSpokenAt.removeAll()

        // ARセッション停止
        sceneView.session.pause()
    }

    // 画面を閉じる
    func transitionToStartViewController() {
        if let nav = navigationController {
            nav.popToRootViewController(animated: true)
        } else if presentingViewController != nil {
            dismiss(animated: true, completion: nil)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    @IBAction func onTapArrivalContinue(_ sender: UIButton) {
        // パネルを隠してナビ続行
        arrivalPanelView.isHidden = true
        // パネルを閉じて、フラグOFF
        isAwaitingArrivalDecision = false
        updateAccessibilityForCurrentState()
        // タイマー停止
        arrivalPanelRepeatTimer?.invalidate()
        arrivalPanelRepeatTimer = nil
    }

    @IBAction func onTapArrivalFinish(_ sender: UIButton) {
        // 終了処理中フラグON（この間は他の案内は一切禁止）
        isFinishingNavigation = true
        // 到着パネル待ち終了
        isAwaitingArrivalDecision = false
        // パネルを隠す
        arrivalPanelView.isHidden = true
        updateAccessibilityForCurrentState()
        // タイマー停止
        arrivalPanelRepeatTimer?.invalidate()
        arrivalPanelRepeatTimer = nil

        // それまで再生中 or キューにたまっている音声を一旦全部止める
        speechOutput.stop()
        // ナビ用のクールダウン管理もリセット
        lastSpokenAt.removeAll()

        // 「お疲れ様でした。」を読み上げ
        speakFinishGreeting()

        // 読み上げが終わるタイミングでナビ終了処理
        let delay: TimeInterval = 2.2   // 実際の長さに合わせて調整
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }

            self.stopAllTTS()
            self.sceneView.session.pause()

            if let nav = self.navigationController {
                nav.popViewController(animated: true)
            } else {
                self.dismiss(animated: true, completion: nil)
            }
        }
    }

    @IBAction func onTapStartGuidance(_ sender: UIButton) {
        isGuidancePaused = false
        startGuidanceButton.isHidden = true
        stopSituationCheck()
        updateAccessibilityForCurrentState()

        noSeatMonitor.startCounting(at: CACurrentMediaTime())

        let situationCheckAnnouncementDelay: TimeInterval = 1.5
        DispatchQueue.main.asyncAfter(deadline: .now() + situationCheckAnnouncementDelay) { [weak self] in
            self?.interruptAndSpeak(
                text: "空席への誘導を開始します。",
                rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                pitch: 0.9,
                volume: 1.0
            )
        }
    }

    @objc private func handleShortcutStartGuidance() {
        guard isViewLoaded else { return }
        guard startGuidanceButton.isHidden == false else { return }
        onTapStartGuidance(startGuidanceButton)
    }

    func showArrivalPanel() {
        DispatchQueue.main.async {
            // パネル待ち中フラグON
            self.isAwaitingArrivalDecision = true

            // パネルを表示
            self.arrivalPanelView.isHidden = false
            self.updateAccessibilityForCurrentState()
            self.arrivalFeedback.notificationOccurred(.success)
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.arrivalPanelView)

            let situationCheckAnnouncementDelay: TimeInterval = 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + situationCheckAnnouncementDelay) { [weak self] in
                self?.speakArrivalPanelGuide()
            }

            // すでにタイマーが動いていたら止める
            self.arrivalPanelRepeatTimer?.invalidate()

            // 10秒おきに繰り返し案内するタイマーをスタート
            self.arrivalPanelRepeatTimer = Timer.scheduledTimer(
                withTimeInterval: self.arrivalPanelRepeatInterval,
                repeats: true
            ) { [weak self] _ in
                guard let self = self else { return }

                // すでにパネルが閉じられていたら何もしない
                guard self.isAwaitingArrivalDecision else { return }

                // すでに何かしゃべっている最中ならスキップ（キューに溜めない）
                if self.speechOutput.isSpeaking { return }

                // 再度、ボタンの位置案内をしゃべる
                self.speakArrivalPanelGuide()
            }
        }
    }
}
