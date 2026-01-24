//  ViewController 2.swift
//  SUWARERU
//  Created by Sugitani on 2026/01/15.

import UIKit
import SceneKit
import ARKit
import Vision
import ImageIO
import AVFoundation


final class ViewController: UIViewController, ARSCNViewDelegate,AVSpeechSynthesizerDelegate {

    // MARK: - IBOutlets
    @IBOutlet weak var sceneView: ARSCNView!
    @IBOutlet weak var debugTextView: UITextView!
    @IBOutlet weak var TextView: UITextView!
    @IBOutlet weak var arrivalPanelView: UIView!
    @IBOutlet weak var startGuidanceButton: UIButton!
    @IBOutlet weak var arrivalContinueButton: UIButton!
    @IBOutlet weak var arrivalFinishButton: UIButton!
    

    // MARK: - Scene / Display
    let bubbleDepth: Float = 0.01
    let autoLabelsRoot = SCNNode() // 自動ラベルの親ノード
    private var viewSize: CGSize = .zero // メインでのみ更新（BGからUIViewを触らない）

    // 最新ラベル（任意のデバッグ用）
    var latestPrediction: String = "…"
    var isGuidancePaused = true
    var shouldStartGuidanceOnAppear = false
    
    private var directionFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let arrivalFeedback = UINotificationFeedbackGenerator()
    private var directionHapticTimer: DispatchSourceTimer?
    private var currentHapticStyle: UIImpactFeedbackGenerator.FeedbackStyle = .medium
    private var currentHapticIntensity: CGFloat = 0.6
    private var currentHapticInterval: TimeInterval = 0.8
    // MARK: - CoreML / Vision
    var visionRequests: [VNRequest] = []
    let dispatchQueueML = DispatchQueue(label: "com.hw.dispatchqueueml")
    let stateQueue = DispatchQueue(label: "com.hw.statequeue")
    private var isMLLoopRunning = false
    var lastMLTime: TimeInterval = 0
    let mlInterval: TimeInterval = 0.4
    // 2Dのバウンディングボックス描画用オーバーレイ
    var bboxOverlayView: UIView!
    var bboxLayers: [CAShapeLayer] = []


    // ======= 検出対象/上限などのポリシー =======
    let allowedLabels: Set<String> = ["person","chair"]     // ← モデルの identifier に合わせて
    let seatLabels: Set<String> = ["chair"]
    // person が chair にどのくらい重なっていたら「occupied」とみなすか
    let personChairIoUThreshold: CGFloat = 0.15   // 好みに応じて 0.2〜0.4 あたりで調整
    let maxTracksPerLabel: Int = 1  // ラベルごとの同時3Dテキスト上限
    let maxTextsPerFrame: Int = 2   // 全体の同時3Dテキスト上限
    let minConfidence: VNConfidence = 0.80      // 信頼度しきい値

    // ======= トラッキング/マッチングのパラメータ =======
    let iouThreshold: CGFloat = 0.55       // IOU がこの値以上なら同一物体
    let distanceCoeff: CGFloat = 0.60      // 自適応距離しきい値の係数 (0.6 × 長辺)
    let minDistancePx: CGFloat = 24.0      // 自適応距離の下限 (px)
    let smoothingAlpha: Float = 0.15       // 位置スムージング（0=据え置き, 1=即反映）
    let trackTimeout: TimeInterval = 4.0   // 見失い判定 (秒)
    let cooldown: TimeInterval = 0.6       // 同ラベル新規作成のクールダウン (秒)

    // ======= 深さ（LiDAR）関連 =======
    let depthThresholdMeters: Float = 2.0  // 深さ一致の許容（0.4〜0.7m 目安）
    
    // ======= 音声案内（TTS）関連 =======
    var sfxPlayer: AVAudioPlayer?
    // 既存があれば値だけ変更でOK
    let tts = AVSpeechSynthesizer()
    // 消えるまで一定間隔で発話したい → false
    var speakOnCreateOnly = false
    // 繰り返し発話の間隔（秒）※好みで調整
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
    let arrivalThresholdMeters: Float = 1.0
    var askExitOnArrivalEnabled: Bool = true
    
    // ======= 空席なし監視用（Timerベース） =======
    var noSeatTimer: Timer?
    /// 空席ゼロ状態になり始めた時刻
    var noSeatStartTime: TimeInterval? = nil
    /// 1回目の「左右を写してください」を喋ったか
    var noSeatFirstWarningSpoken = false
    /// 1回目を喋った時刻（ここから追加時間を測る）
    var noSeatFirstWarningTime: TimeInterval? = nil
    /// 2回目の「終了します」を喋ったか
    var noSeatFinalWarningSpoken = false
    /// 空席ゼロになってから1回目を出すまでの秒数
    let noSeatFirstDelay: TimeInterval = 6.0
    /// 「1回目のアナウンスから」2回目（終了）まで待つ秒数
    let noSeatAfterFirstDelay: TimeInterval = 8.0


    // ======= データ構造 =======
    struct Detection {
        let id: UUID
        let label: String
        let confidence: Float
        let screenPoint: CGPoint   // 画面中心（UIKit座標）
        let screenRect: CGRect     // 画面上BBox（UIKit座標）
        let t: TimeInterval
    }

    struct Track {
        var id: UUID
        var label: String
        var node: SCNNode
        var lastScreenPoint: CGPoint
        var lastScreenRect: CGRect
        var worldTransform: simd_float4x4
        var lastSeen: TimeInterval
        var createdAt: TimeInterval
        var confidence: Float
        var depthMeters: Float
        var centerAngleDeg: Float?
        var arrivalAnnounced: Bool = false
    }

    var pendingDetections: [Detection] = []

    var tracks: [UUID: Track] = [:]
    var lastProcessTime: TimeInterval = 0
    private var lastEmptySeatCount: Int = 0
    private var lastPersonCount: Int = 0
    private var isSituationCheckInProgress = false
    private var situationCheckTimer: Timer?
    private var situationEmptySeatCounts: [Int: Int] = [:]
    private var situationPersonCounts: [Int: Int] = [:]
    private let situationCheckDuration: TimeInterval = 7.0
    
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

        bboxOverlayView = UIView(frame: sceneView.bounds)
        bboxOverlayView.backgroundColor = .clear
        bboxOverlayView.isUserInteractionEnabled = false
        bboxOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.addSubview(bboxOverlayView)
        
        // Vision / CoreML セットアップ
        guard let model = try? VNCoreMLModel(for: yolo11n().model) else {
            fatalError("Could not load CoreML model (yolo11n). Make sure the .mlmodel is added to the target.")
        }
        let request = VNCoreMLRequest(model: model, completionHandler: classificationCompleteHandler)
        request.imageCropAndScaleOption = .scaleFit
        visionRequests = [request]
        tts.delegate = self
        configureAccessibility()
        directionFeedback.prepare()
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
        noSeatStartTime = nil
        noSeatFirstWarningSpoken = false
        noSeatFinalWarningSpoken = false

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

    // MARK: - Vision Loop
    func startCoreMLLoopIfNeeded() {
        guard !isMLLoopRunning else { return }
        isMLLoopRunning = true
        scheduleNextCoreMLUpdate()
    }

    func scheduleNextCoreMLUpdate() {
        dispatchQueueML.asyncAfter(deadline: .now() + mlInterval) { [weak self] in
            guard let self = self, self.isMLLoopRunning else { return }
            self.updateCoreML()
            self.scheduleNextCoreMLUpdate()
        }
    }

    /// 検出結果のBBOXを画面上に表示する（2Dオーバーレイ）
    func updateBoundingBoxes(with detections: [Detection]) {
        // 既存の枠を全部消す
        for layer in bboxLayers {
            layer.removeFromSuperlayer()
        }
        bboxLayers.removeAll()

        guard !detections.isEmpty else { return }

        for det in detections {
            let rect = det.screenRect    // UIKit座標の矩形（左上原点）

            let boxLayer = CAShapeLayer()
            boxLayer.frame = rect
            boxLayer.path = UIBezierPath(rect: CGRect(origin: .zero,
                                                      size: rect.size)).cgPath

            boxLayer.strokeColor = UIColor.systemYellow.cgColor   // 枠線の色
            boxLayer.fillColor   = UIColor.clear.cgColor          // 塗りつぶし無し
            boxLayer.lineWidth   = 2.0
            bboxOverlayView.layer.addSublayer(boxLayer)
            bboxLayers.append(boxLayer)
        }
    }

    
    func updateCoreML() {
        let now = CACurrentMediaTime()
        if now - lastMLTime < mlInterval {
            return
        }
        lastMLTime = now

        guard let pb = sceneView.session.currentFrame?.capturedImage else { return }
        let orientation = ViewController.cgImageOrientationForDevice()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: orientation, options: [:])
        do {
            try handler.perform(visionRequests)
        } catch {
            print("VNImageRequestHandler error:", error)
        }
    }

    // MARK: - Vision Callback
    func classificationCompleteHandler(request: VNRequest, error: Error?) {
        if let error = error {
            print("Vision error:", error.localizedDescription)
            return
        }
        guard let objects = request.results as? [VNRecognizedObjectObservation] else { return }
        if objects.isEmpty {
            stateQueue.sync {
                self.lastEmptySeatCount = 0
                self.lastPersonCount = 0
                if self.isSituationCheckInProgress {
                    self.recordSituationCounts(emptySeatCount: 0, personCount: 0)
                }
                self.pendingDetections.removeAll()
            }
            DispatchQueue.main.async { [weak self] in
                self?.debugTextView.text = ""
                self?.updateBoundingBoxes(with: [])
            }
            return
        }
        // viewSize が 0 の場合はメインスレッドで拾ってから続行
        if viewSize.width <= 0 || viewSize.height <= 0 {
            DispatchQueue.main.async {
                self.viewSize = self.sceneView.bounds.size
            }
            return
        }

        let W = viewSize.width, H = viewSize.height
        if W <= 0 || H <= 0 { return }

        let now = CACurrentMediaTime()
        var newDetections: [Detection] = []

        for obs in objects {
            guard let top = obs.labels.first,
                  top.confidence >= minConfidence else { continue }
            guard allowedLabels.contains(top.identifier) else { continue }

            // Vision正規化BBox(左下原点) → UIKit座標(左上原点)
            let bb = obs.boundingBox
            let centerNorm = CGPoint(x: bb.midX, y: bb.midY)
            let uiPoint = CGPoint(x: centerNorm.x * W,
                                  y: (1.0 - centerNorm.y) * H)
            let uiRect = CGRect(x: bb.minX * W,
                                y: (1.0 - bb.maxY) * H,
                                width: bb.width * W,
                                height: bb.height * H)

            newDetections.append(
                Detection(id: UUID(),
                          label: top.identifier,
                          confidence: top.confidence,
                          screenPoint: uiPoint,
                          screenRect: uiRect,
                          t: now)
            )
        }

        // person と重なっている chair を除外する
        let chairDetections  = newDetections.filter { $0.label == "chair" }
        let personDetections = newDetections.filter { $0.label == "person" }

        // person と重なっていない chair だけ「空席」として残す
        let emptyChairs = chairDetections.filter { chair in
            !isChairOccupied(chair, persons: personDetections)
        }

        // person は今回はトラッキングに使わないので pendingDetections には積まない
        let filteredDetections = emptyChairs
        stateQueue.sync {
            self.lastEmptySeatCount = emptyChairs.count
            self.lastPersonCount = personDetections.count
            if self.isSituationCheckInProgress {
                self.recordSituationCounts(
                    emptySeatCount: emptyChairs.count,
                    personCount: personDetections.count
                )
            }
        }
        
        guard !filteredDetections.isEmpty else {
            // 検出が無いときはBBOXを全部消す
            DispatchQueue.main.async { [weak self] in
                self?.updateBoundingBoxes(with: [])
            }
            return
        }

        // 古い検出を掃除し、高信頼順で積む
        let cutoff = now - 0.5
        let sorted = filteredDetections.sorted(by: { $0.confidence > $1.confidence })
        stateQueue.sync {
            self.pendingDetections.removeAll(where: { $0.t < cutoff })
            self.pendingDetections.append(contentsOf: sorted)
        }

        // デバッグ表示（任意）
        let lines = sorted.prefix(2).map { "\($0.label) - \(Int($0.confidence * 100))%" }.joined(separator: "\n")
        DispatchQueue.main.async {
            self.debugTextView.text = lines
            if let first = sorted.first { self.latestPrediction = first.label }
            // このフレームで検出した BBOX を画面に反映
            self.updateBoundingBoxes(with: sorted)
        }
    }

    // MARK: - Per-frame placement & tracking
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // 約5Hzで更新
        if time - self.lastProcessTime < 0.4 { return }
        self.lastProcessTime = time

        var angleLines = ""
        var tracksToSpeak: [Track] = []
        var shouldShowArrivalPanel = false
        var didProcessDetections = false
        var currentEmptySeatCount = 0
        var currentPersonCount = 0

        stateQueue.sync {
            // 安全な掃除
            let staleKeys = self.tracks
                .filter { entry in
                    let track = entry.value
                    guard time - track.lastSeen > self.trackTimeout else { return false }
                    
                    if self.seatLabels.contains(track.label) {
                        let liveDistance: Float? = self.sceneView.session.currentFrame == nil
                        ? nil
                        : self.liveDistanceMeters(for: track)
                        if let liveDistance, liveDistance <= 2.0 {
                            return false
                        }
                    }
                    return true
                }
                .map { $0.key }

            for key in staleKeys {
                if let node = self.tracks[key]?.node {
                    node.removeFromParentNode()
                }
                self.tracks.removeValue(forKey: key)
            }

            currentEmptySeatCount = self.lastEmptySeatCount
            currentPersonCount = self.lastPersonCount
            
            guard !self.pendingDetections.isEmpty else { return }
            didProcessDetections = true

            // 高信頼順に処理
            let sortedDet = self.pendingDetections.sorted { $0.confidence > $1.confidence }
            var createdCount = 0

            for det in sortedDet {
                // 1) 既存トラックにマッチ（同ラベル + 2D + 深さゲート）
                if let (tid, _) = self.findMatchingTrack(for: det) {
                    // ※ 位置・深さ・角度は更新しない（据え置き）
                    self.tracks[tid]?.lastScreenPoint = det.screenPoint
                    self.tracks[tid]?.lastScreenRect  = det.screenRect
                    self.tracks[tid]?.confidence      = det.confidence
                    self.tracks[tid]?.lastSeen        = time
                }
                // 2) 新規作成（上限まで）
                else if (self.tracks.count + createdCount) < self.maxTextsPerFrame {

                    // ラベルごとの上限チェック
                    let sameCount = self.tracks.values.filter { $0.label == det.label }.count
                    if sameCount >= self.maxTracksPerLabel {
                        // 既に同ラベルが上限数いれば、最も近いのを更新だけしてスキップ（任意）
                        if let (tid, _) = self.findNearestTrackOfSameLabel(det: det) {
                            self.tracks[tid]?.lastScreenPoint = det.screenPoint
                            self.tracks[tid]?.lastScreenRect  = det.screenRect
                            self.tracks[tid]?.confidence      = det.confidence
                            self.tracks[tid]?.lastSeen        = time
                        }
                        continue
                    }

                    // クールダウン（直近に同ラベルを作った直後は少し待つ）
                    let recentSame = self.tracks.values.contains {
                        $0.label == det.label && (time - $0.createdAt) < self.cooldown
                    }
                    if recentSame { continue }

                    // 本当に新規作成（深度優先→Raycast）
                    guard let (wt, depth) = self.worldTransformAndDepthFirst(at: det.screenPoint) else { continue }
                    let node = self.createNewBubbleParentNode(det.label)
                    node.simdTransform = wt
                    self.autoLabelsRoot.addChildNode(node)

                    // 角度は水平Yawで保存
                    let p = simd_float3(wt.columns.3.x, wt.columns.3.y, wt.columns.3.z)
                    let angle = self.yawAngleToCameraCenter(worldPos: p)

                    let t = Track(id: UUID(),
                                  label: det.label,
                                  node: node,
                                  lastScreenPoint: det.screenPoint,
                                  lastScreenRect: det.screenRect,
                                  worldTransform: wt,
                                  lastSeen: time,
                                  createdAt: time,
                                  confidence: det.confidence,
                                  depthMeters: depth,
                                  centerAngleDeg: angle)
                    self.tracks[t.id] = t
                    createdCount += 1

                    // 新規作成時に音声案内（必要なら）
                    tracksToSpeak.append(t)
                }


                if self.tracks.count >= self.maxTextsPerFrame { break }
            }

            // 角度＆距離を TextView に出力（中心に近い順で上限数）
            angleLines = self.tracks.values
                // 角度はライブ再計算。中心に近い順（絶対値の小さい順）でソート
                .sorted {
                    let p0 = simd_float3($0.worldTransform.columns.3.x, $0.worldTransform.columns.3.y, $0.worldTransform.columns.3.z)
                    let p1 = simd_float3($1.worldTransform.columns.3.x, $1.worldTransform.columns.3.y, $1.worldTransform.columns.3.z)
                    let a0 = abs(self.yawAngleToCameraCenter(worldPos: p0) ?? 9999)
                    let a1 = abs(self.yawAngleToCameraCenter(worldPos: p1) ?? 9999)
                    return a0 < a1
                }
                .prefix(self.maxTextsPerFrame)
                .compactMap { tr -> String? in
                    // ★ 毎回最新の角度・距離を計算
                    let wp = simd_float3(tr.worldTransform.columns.3.x,
                                         tr.worldTransform.columns.3.y,
                                         tr.worldTransform.columns.3.z)
                    guard let liveYaw = self.yawAngleToCameraCenter(worldPos: wp) else { return nil }
                    let liveDist = self.liveDistanceMeters(for: tr)

                    let angleStr = String(format: "%.0f", liveYaw)
                    let depthStr = String(format: "%.1f", liveDist)
                    return "\(tr.label): \(angleStr)°  (\(depthStr)m)"
                }
                .joined(separator: "\n")

            // speakOnCreateOnly = false のとき、まだ生きているTrackを一定間隔で案内
            if self.speakOnCreateOnly == false {
                let now = CACurrentMediaTime()
                for (_, tr) in self.tracks {
                    // lastSeen は renderer の time と同じ時計で比較する
                    if time - tr.lastSeen <= self.trackTimeout {
                        let last = self.lastSpokenAt[tr.id] ?? 0
                        // 最終発話から規定秒数経っていれば発話
                        if now - last >= self.ttsRepeatInterval {
                            tracksToSpeak.append(tr)
                        }
                    }
                }
            }

            // 距離がしきい値以下になったTrackに一度だけ到着アナウンス
            if self.arrivalAnnounceEnabled {
                for (tid, tr) in self.tracks {
                    // まだ表示存続中のものだけ対象
                    if time - tr.lastSeen <= self.trackTimeout, tr.arrivalAnnounced == false {
                        let dist = self.liveDistanceMeters(for: tr)
                        if dist <= self.arrivalThresholdMeters {
                            // フラグを立てる（以降は繰り返さない）
                            self.tracks[tid]?.arrivalAnnounced = true
                            // 終了確認を表示
                            if self.askExitOnArrivalEnabled && !self.isGuidancePaused {
                                shouldShowArrivalPanel = true
                            }
                        }
                    }
                }
            }

            // 検出を使い切る（必要なら残す設計でもOK）
            self.pendingDetections.removeAll()
        }
        let activeSeatTracks = self.tracks.values.filter { tr in
            self.seatLabels.contains(tr.label) && time - tr.lastSeen <= self.trackTimeout
        }
        let targetTrack = activeSeatTracks.min { lhs, rhs in
            self.liveDistanceMeters(for: lhs) < self.liveDistanceMeters(for: rhs)
        }
        self.updateDirectionHaptics(for: targetTrack)
        let statusSummary = "状況確認中\n空席: \(currentEmptySeatCount)  人: \(currentPersonCount)"
        guard didProcessDetections || isGuidancePaused else { return }

        DispatchQueue.main.async {
            if self.isGuidancePaused {
                self.TextView.text = statusSummary
                self.TextView.accessibilityValue = statusSummary
            } else {
                self.TextView.text = angleLines   // 空でも毎回更新してOK（好み）
                self.TextView.accessibilityValue = angleLines.isEmpty ? "検出なし" : angleLines
            }
            if shouldShowArrivalPanel {
                self.showArrivalPanel()
            }
        }

        if !isGuidancePaused {
            for track in tracksToSpeak {
                self.speak(track: track)
            }
        }
    }
    
    /// 1秒ごとに呼ばれて、空席がしばらく見つからないときにアナウンスする
    @objc func checkNoSeatState() {
        let now = CACurrentMediaTime()

        // 座席としてカウントするTrackが1つでもあるか？
        let hasSeat = self.tracks.values.contains { tr in
            seatLabels.contains(tr.label)
        }


        if hasSeat {
            // 空席が見つかったら全部リセット
            noSeatStartTime = nil
            noSeatFirstWarningSpoken = false
            noSeatFirstWarningTime = nil
            noSeatFinalWarningSpoken = false
            return
        }

        // ここに来た時点で「座席Trackがひとつも無い」

        // 空席ゼロになり始めた時刻をセット
        if noSeatStartTime == nil {
            noSeatStartTime = now
            noSeatFirstWarningSpoken = false
            noSeatFirstWarningTime = nil
            noSeatFinalWarningSpoken = false
            return
        }

        // 空席ゼロになってからの経過時間
        let elapsedFromStart = now - (noSeatStartTime ?? now)

        // まだ1回目を喋っていない → noSeatFirstDelay 経過で1回目
        if !noSeatFirstWarningSpoken && elapsedFromStart >= noSeatFirstDelay {
            noSeatFirstWarningSpoken = true
            noSeatFirstWarningTime = now
            speakNoSeatWarning()
            return
        }

        // 1回目は喋った → 「1回目から」の経過時間を見る
        if noSeatFirstWarningSpoken,
           !noSeatFinalWarningSpoken,
           let firstTime = noSeatFirstWarningTime {

            let elapsedFromFirst = now - firstTime
            if elapsedFromFirst >= noSeatAfterFirstDelay {
                noSeatFinalWarningSpoken = true
                speakNoSeatFinalAndExit()
            }
        }
    }



    // MARK: - Matching helpers (2D+Depth)
    func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// chair のBBOXに person が重なっていたら「埋まっている」とみなす
    func isChairOccupied(_ chair: Detection, persons: [Detection]) -> Bool {
        for p in persons where p.label == "person" {
            let overlap = iou(chair.screenRect, p.screenRect)
            // chair と person の BBOX の IoU がしきい値以上なら「人が座っている」と判断
            if overlap >= personChairIoUThreshold {
                return true
            }
        }
        return false
    }

    /// 優先: (深さゲートを満たす) IOU >= iouThreshold → ダメなら距離も
    func findMatchingTrack(for det: Detection) -> (UUID, Track)? {
        // 検出の深さ（取れない時は nil）
        let detDepth: Float? = {
            if let (_, dd) = self.worldTransformAndDepthFirst(at: det.screenPoint) { return dd }
            return nil
        }()

        // 1) IOU最大（深さが両方あればゲート）
        var bestIOU: (UUID, Track, CGFloat)? = nil
        for (tid, tr) in tracks where tr.label == det.label {
            if let dd = detDepth, abs(dd - tr.depthMeters) > depthThresholdMeters { continue }
            let i = iou(det.screenRect, tr.lastScreenRect)
            if bestIOU == nil || i > bestIOU!.2 { bestIOU = (tid, tr, i) }
        }
        if let b = bestIOU, b.2 >= iouThreshold { return (b.0, b.1) }

        // 2) 中心距離（自適応しきい値）で補完
        var bestDist: (UUID, Track, CGFloat)? = nil
        for (tid, tr) in tracks where tr.label == det.label {
            if let dd = detDepth, abs(dd - tr.depthMeters) > depthThresholdMeters { continue }
            let d = hypot(tr.lastScreenPoint.x - det.screenPoint.x,
                          tr.lastScreenPoint.y - det.screenPoint.y)
            let longEdge = max(det.screenRect.width, det.screenRect.height)
            let thresh = max(minDistancePx, distanceCoeff * longEdge)
            if d <= thresh {
                if bestDist == nil || d < bestDist!.2 { bestDist = (tid, tr, d) }
            }
        }
        if let b = bestDist { return (b.0, b.1) }

        // フォールバック（深さなし時、2Dのみ・やや厳しめ）
        if detDepth == nil {
            var fb: (UUID, Track, CGFloat)? = nil
            for (tid, tr) in tracks where tr.label == det.label {
                let i = iou(det.screenRect, tr.lastScreenRect)
                if fb == nil || i > fb!.2 { fb = (tid, tr, i) }
            }
            if let f = fb, f.2 >= iouThreshold * 1.2 { return (f.0, f.1) }
        }
        return nil
    }

    /// 同ラベルの既存トラックで画面距離が最小のもの
    func findNearestTrackOfSameLabel(det: Detection) -> (UUID, Track)? {
        var best: (UUID, Track, CGFloat)? = nil
        for (tid, tr) in tracks where tr.label == det.label {
            let d = hypot(tr.lastScreenPoint.x - det.screenPoint.x,
                          tr.lastScreenPoint.y - det.screenPoint.y)
            if best == nil || d < best!.2 { best = (tid, tr, d) }
        }
        if let b = best { return (b.0, b.1) }
        return nil
    }

    /// 位置のみスムージング（回転はビルボード任せ）
    func blendTransform(old: simd_float4x4, new: simd_float4x4, alpha: Float) -> simd_float4x4 {
        var out = new
        let op = simd_float3(old.columns.3.x, old.columns.3.y, old.columns.3.z)
        let np = simd_float3(new.columns.3.x, new.columns.3.y, new.columns.3.z)
        let bp = op * (1 - alpha) + np * alpha
        out.columns.3.x = bp.x
        out.columns.3.y = bp.y
        out.columns.3.z = bp.z
        return out
    }

    // MARK: - Depth-first world pos / Raycast fallback
    /// 画面座標ptに対応する 3Dワールド座標を「深度」から推定（成功時）＋距離[m]
    func worldPositionFromDepth(at pt: CGPoint) -> (simd_float3, Float)? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        // 深度マップ（smoothed優先）
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthPB = depthData.depthMap // CVPixelBuffer (meter)

        // 画面座標→深度画像座標（displayTransform で整合）
        let size = sceneView.bounds.size
        let norm = CGPoint(x: pt.x / size.width, y: pt.y / size.height)
        let disp = frame.displayTransform(for: .portrait, viewportSize: size) // 端末の実向きに合わせて
        let normDepth = norm.applying(disp) // 0..1

        let w = CVPixelBufferGetWidth(depthPB)
        let h = CVPixelBufferGetHeight(depthPB)
        var x = Int(round(normDepth.x * CGFloat(w)))
        var y = Int(round((1 - normDepth.y) * CGFloat(h))) // Y反転
        x = max(0, min(w - 1, x))
        y = max(0, min(h - 1, y))

        CVPixelBufferLockBaseAddress(depthPB, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthPB, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthPB) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(depthPB) / MemoryLayout<Float32>.size
        let buf = base.assumingMemoryBound(to: Float32.self)

        // 3×3 近傍の中央値で頑健化
        var samples: [Float] = []
        for ky in -1...1 {
            for kx in -1...1 {
                let sx = max(0, min(w - 1, x + kx))
                let sy = max(0, min(h - 1, y + ky))
                let d = buf[sy * stride + sx]
                if d.isFinite && d > 0 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        let depthM = samples[samples.count / 2] // 中央値[m]

        // 画像座標 → カメラ座標へ逆投影（深度画像座標を近似的に使用）
        let intr = frame.camera.intrinsics
        let u = Float(x), v = Float(y)
        let fx = intr.columns.0.x, fy = intr.columns.1.y
        let cx = intr.columns.2.x, cy = intr.columns.2.y
        let Xc = (u - cx) / fx * depthM
        let Yc = (v - cy) / fy * depthM
        let Zc = depthM
        let camPoint = simd_float4(Xc, Yc, Zc, 1.0)

        // カメラ→ワールド
        let world4 = frame.camera.transform * camPoint
        let world3 = simd_float3(world4.x, world4.y, world4.z)

        // カメラからの距離[m]
        let camPos = simd_float3(frame.camera.transform.columns.3.x,
                                 frame.camera.transform.columns.3.y,
                                 frame.camera.transform.columns.3.z)
        let distance = simd_length(world3 - camPos)
        return (world3, distance)
    }

    /// 深度が取れればそれを優先し、ダメなら Raycast で simd_float4x4 と距離を返す
    func worldTransformAndDepthFirst(at pt: CGPoint) -> (simd_float4x4, Float)? {
        if let (pos, dist) = worldPositionFromDepth(at: pt) {
            var t = matrix_identity_float4x4
            t.columns.3 = simd_float4(pos.x, pos.y, pos.z, 1)
            return (t, dist)
        }
        // フォールバック：従来の Raycast
        if let wt = worldTransform(at: pt),
           let frame = sceneView.session.currentFrame {
            let hit = simd_float3(wt.columns.3.x, wt.columns.3.y, wt.columns.3.z)
            let cam = simd_float3(frame.camera.transform.columns.3.x,
                                  frame.camera.transform.columns.3.y,
                                  frame.camera.transform.columns.3.z)
            let d = simd_length(hit - cam)
            return (wt, d)
        }
        return nil
    }

    /// 画面座標から、平面→推定平面→特徴点(最遠; 0.5m未満は捨て)の順でワールド位置を取得
    func worldTransform(at pt: CGPoint) -> simd_float4x4? {
        if let q1 = sceneView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .any) {
            if let hit = sceneView.session.raycast(q1).first { return hit.worldTransform }
        }
        if let q2 = sceneView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .any) {
            if let hit = sceneView.session.raycast(q2).first { return hit.worldTransform }
        }
        return nil
    }

    // MARK: - カメラ角度ヘルパ
    /// カメラの位置と軸ベクトル（world座標系）
    func cameraPose() -> (pos: simd_float3, forward: simd_float3, right: simd_float3, up: simd_float3)? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        let m = frame.camera.transform
        let pos = simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let right = simd_float3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let up    = simd_float3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let back  = simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let forward = -back // ARKitの前方は -Z
        return (pos, forward, right, up)
    }

    /// 任意ワールド位置とカメラ中心視線のなす角 [deg]
    func angleToCameraCenter(worldPos: simd_float3) -> Float? {
        guard let cam = cameraPose() else { return nil }
        let dir = simd_normalize(worldPos - cam.pos)  // カメラ→対象
        let cosθ = simd_dot(cam.forward, dir)
        let clamped = max(-1.0 as Float, min(1.0 as Float, cosθ))
        let rad = acos(clamped)
        return rad * 180.0 / .pi
    }
    /// world座標Pに対する「水平（Yaw）角度」[deg]。+右 / -左。上下は完全に無視（worldUp基準）。
    func yawAngleToCameraCenter(worldPos P: simd_float3) -> Float? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        let M = frame.camera.transform

        // カメラ位置（world）
        let C = simd_float3(M.columns.3.x, M.columns.3.y, M.columns.3.z)

        // world の真上（重力方向）。ARKitの world は Y+ が上
        let worldUp = simd_float3(0, 1, 0)

        // カメラ前方（world）
        let camForward = -simd_float3(M.columns.2.x, M.columns.2.y, M.columns.2.z)

        // ---- 水平面（worldUp直交平面）への厳密投影 ----
        // 対象方向ベクトル（C→P）を水平面に投影して正規化
        let vWorld = P - C
        let vH = simd_normalize(vWorld - simd_dot(vWorld, worldUp) * worldUp)

        // カメラ前方も水平面に投影して正規化（カメラが上下を向いていてもOK）
        let fH = simd_normalize(camForward - simd_dot(camForward, worldUp) * worldUp)

        // 右方向（水平）の基底：worldUp × fH
        let rightH = simd_normalize(simd_cross(worldUp, fH))

        // vH を (fH, rightH) 平面上で極座標化
        let x = simd_dot(vH, rightH)  // 右が +、左が -
        let z = simd_dot(vH, fH)      // 前が +
        let yaw = atan2f(x, z)        // -π..+π

        return yaw * 180.0 / .pi
    }

    
    // MARK: - Util
    
    /// Trackの現在位置から、発話直前に「水平Yaw角[deg]」を再計算
    func liveYawDeg(for track: Track) -> Float? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        let t = track.worldTransform
        // 垂直方向は無視して水平面だけで角度を計算する
        let cameraY = frame.camera.transform.columns.3.y
        let p = simd_float3(t.columns.3.x, cameraY, t.columns.3.z)
        return self.yawAngleToCameraCenter(worldPos: p)
    }
    
    func liveDistanceMeters(for track: Track) -> Float {
        guard let frame = sceneView.session.currentFrame else { return track.depthMeters }
        let cam = simd_float3(frame.camera.transform.columns.3.x,
                              frame.camera.transform.columns.3.y,
                              frame.camera.transform.columns.3.z)
        let t = track.worldTransform
        let p = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        return simd_length(p - cam)
    }
    
    /// 角度の方向化
    func directionPhrase(fromYawDeg yaw: Float?) -> String? {
        guard let yaw = yaw else { return nil }
        var clockDeg = -yaw  // yaw の右正→左正 に変換
        if clockDeg < 0 { clockDeg += 360 }
        if clockDeg >= 360 { clockDeg -= 360 }

        // clockDeg を 12分割して「何時」に変換（1つ30度）
        let hour = Int(round(clockDeg / 30.0))
        let hour12 = (hour % 12 == 0) ? 12 : (hour % 12)

        return "\(hour12)時方向"
    }

    /// 距離の読み上げ用丸め
    func distancePhrase(fromMeters m: Float) -> String {
        if m < 1.0 { return String(format: "残り%.1fメートル", m) }      // 0.8m → 0.8メートル
        if m < 3.0 { return String(format: "残り%.1fメートル", m) }      // 2.3m → 2.3メートル
        return String(format: "残り%.0fメートル", round(m))               // 5.2m → 5メートル
    }
    
    /// 方向フレーズを基準にした角度差（0〜180）を算出
    func directionDifferenceAngleDeg(fromYawDeg yaw: Float?) -> Float? {
        guard let yaw = yaw, let phrase = directionPhrase(fromYawDeg: yaw) else { return nil }
        let hourString = phrase.replacingOccurrences(of: "時方向", with: "")
        guard let hour = Int(hourString) else { return nil }

        let targetDeg = Float(hour % 12) * 30.0
        var clockDeg = -yaw
        if clockDeg < 0 { clockDeg += 360 }
        if clockDeg >= 360 { clockDeg -= 360 }

        let diff = abs(clockDeg - targetDeg)
        return min(diff, 360 - diff)
    }

    private func hapticConfig(for angleDiff: Float) -> (style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat, interval: TimeInterval) {
        switch angleDiff {
        case 0...5:
            return (.heavy, 1.0, 0.2)
        case 5...15:
            return (.medium, 0.75, 0.4)
        case 15...30:
            return (.light, 0.5, 0.7)
        default:
            return (.light, 0.3, 1.2)
        }
    }

    private func stopDirectionHaptics() {
        directionHapticTimer?.cancel()
        directionHapticTimer = nil
    }

    private func updateDirectionHaptics(for track: Track?) {
        guard !isGuidancePaused,
              !isFinishingNavigation,
              let track = track,
              let yaw = liveYawDeg(for: track),
              let angleDiff = directionDifferenceAngleDeg(fromYawDeg: yaw) else {
            stopDirectionHaptics()
            return
        }

        let config = hapticConfig(for: angleDiff)
        let needsStyleUpdate = config.style != currentHapticStyle
        let needsIntervalUpdate = config.interval != currentHapticInterval
        let needsIntensityUpdate = config.intensity != currentHapticIntensity

        if needsStyleUpdate {
            directionFeedback = UIImpactFeedbackGenerator(style: config.style)
            currentHapticStyle = config.style
        }
        if needsIntervalUpdate {
            currentHapticInterval = config.interval
        }
        if needsIntensityUpdate {
            currentHapticIntensity = config.intensity
        }

        if needsStyleUpdate || needsIntervalUpdate || needsIntensityUpdate || directionHapticTimer == nil {
            directionFeedback.prepare()
        }

        if needsIntervalUpdate || directionHapticTimer == nil {
            stopDirectionHaptics()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: currentHapticInterval)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                if #available(iOS 13.0, *) {
                    self.directionFeedback.impactOccurred(intensity: self.currentHapticIntensity)
                } else {
                    self.directionFeedback.impactOccurred()
                }
                self.directionFeedback.prepare()
            }
            directionHapticTimer = timer
            timer.activate()
        }
    }
    /// いま話している内容やキューを全部止めて、すぐ新しいテキストを読み上げる
    func interruptAndSpeak(text: String,
                           rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.0,
                           pitch: Float = 1.0,
                           volume: Float = 1.0) {
        if isVoiceOverRunning() {
            announceForAccessibility(text)
            return
        }
        // しゃべっていたら即停止（キューも含めて破棄）
        tts.stopSpeaking(at: .immediate)
        // クールダウン管理をしているなら、ここでリセットしておく
        lastSpokenAt.removeAll()

        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utt.rate  = rate
        utt.pitchMultiplier = pitch
        utt.volume = volume

        DispatchQueue.main.async { [weak self] in
            self?.speakWithSFX(utt)
        }
    }

    
    func speak(track: Track, labelOverride: String? = nil) {
        // 終了処理中／到着パネル表示中はナビ音声を出さない
        if isFinishingNavigation || isAwaitingArrivalDecision || isGuidancePaused {
            return
        }
        
        let now = CACurrentMediaTime()
        // クールダウン（あまり頻度が高すぎないように）
        if let last = lastSpokenAt[track.id],
           now - last < ttsCooldownSeconds {
            return
        }

        // ★ すでに何かしゃべっている最中ならスキップする
        if tts.isSpeaking { return }

        // ここまで来たら「いまは無音 or しゃべり終わり直後」なので
        // すぐにこの Track を実際に読み上げてOK
        lastSpokenAt[track.id] = now

        // ---- ここから先は、これまでの文言生成ロジックそのままでOK ----
        let t = track.worldTransform
        let p = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let yawDeg = self.yawAngleToCameraCenter(worldPos: p)

        var parts: [String] = ["空席"]
        if let dir = directionPhrase(fromYawDeg: yawDeg) {
            parts.append(dir)   // 例: "3時方向"
        }
        parts.append(distancePhrase(fromMeters: liveDistanceMeters(for: track)))
        let sentence = parts.joined(separator: "、")

        if isVoiceOverRunning() {
            announceForAccessibility(sentence)
            return
        }

        let utt = AVSpeechUtterance(string: sentence)
        utt.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utt.rate  = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utt.pitchMultiplier = 0.9
        utt.volume = 1.0

        DispatchQueue.main.async { [weak self] in
            self?.tts.speak(utt)
        }
    }



    func speakNoSeatWarning() {
        // パネル中はしゃべらない
        if isAwaitingArrivalDecision || isGuidancePaused { return }
        if isVoiceOverRunning() {
            announceForAccessibility("空席が見つかりません。カメラで左右を写してください。")
            return
        }
        interruptAndSpeak(
            text: "空席が見つかりません。カメラで左右を写してください。",
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitch: 0.9,
            volume: 1.0
        )
    }

    func speakArrivalPanelGuide() {
        if isGuidancePaused { return }
        let utt = AVSpeechUtterance(string: "空席に到着しました。ナビを終了しますか？終了するには画面左側、続けるには画面右側をタップしてください。")
            utt.voice = AVSpeechSynthesisVoice(language: "ja-JP")
            utt.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utt.pitchMultiplier = 0.9
            utt.volume = 1.0
        DispatchQueue.main.async { [weak self] in
            if self?.isVoiceOverRunning() == true {
                self?.announceForAccessibility(utt.speechString)
                return
            }
            self?.speakWithSFX(utt)
            }
    }

    
    func speakNoSeatFinalAndExit() {
        // パネル表示中なら、そもそもここも入れたくないなら return でもOK
        if isAwaitingArrivalDecision || isGuidancePaused { return }
        let text = "空席が見つかりませんでした。空席ナビを終了します。"
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utt.rate  = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utt.pitchMultiplier = 0.9
        utt.volume = 1.0

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // ★ここを追加：いま話しているもの＆キューを即座に止める（割り込み）
            self.tts.stopSpeaking(at: .immediate)
            // クールダウン管理しているなら、リセットしておくと安全
            self.lastSpokenAt.removeAll()

            // 終了アナウンスを新しく再生
            if self.isVoiceOverRunning() {
                self.announceForAccessibility(utt.speechString)
            } else {
                self.tts.speak(utt)
                self.announceForAccessibility("空席が見つかりませんでした。案内を終了します。")
            }

            // 少し待ってから自動終了（テキストの長さに合わせて調整）
            let delay: TimeInterval = 4.0
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
    }

    
    func speakFinishGreeting() {
        interruptAndSpeak(
            text: "お疲れ様でした。",
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitch: 0.9,
            volume: 1.0
        )
    }

    @IBAction func onExit(_ sender: UIButton) {

        // 終了処理中
        isFinishingNavigation = true

        // パネル表示中なら解除
        isAwaitingArrivalDecision = false

        // 繰り返しタイマー停止
        arrivalPanelRepeatTimer?.invalidate()
        arrivalPanelRepeatTimer = nil
        noSeatTimer?.invalidate()
        noSeatTimer = nil
        stopDirectionHaptics()
        
        // 音声を即停止
        tts.stopSpeaking(at: .immediate)
        lastSpokenAt.removeAll()

        // ARセッション停止
        sceneView.session.pause()

        // 画面を閉じる
        if let nav = navigationController {
            nav.popViewController(animated: true)
        } else {
            dismiss(animated: true, completion: nil)
        }
    }

    
    @IBAction func onTapArrivalContinue(_ sender: UIButton) {
        // パネルを隠してナビ続行
        arrivalPanelView.isHidden = true
        // パネルを閉じて、フラグOFF
        isAwaitingArrivalDecision = false
        
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

        // タイマー停止
            arrivalPanelRepeatTimer?.invalidate()
            arrivalPanelRepeatTimer = nil
        
        // それまで再生中 or キューにたまっている音声を一旦全部止める
        tts.stopSpeaking(at: .immediate)
        // ナビ用のクールダウン管理もリセット（任意だが安全）
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
        announceForAccessibility("案内を開始します。")
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
            self.arrivalFeedback.notificationOccurred(.success)
            self.announceForAccessibility("空席に到着しました。終了するか続けるか選択してください。")
            UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.arrivalPanelView)

            // まず最初の1回をすぐ案内
            self.speakArrivalPanelGuide()

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
                if self.tts.isSpeaking { return }

                // 再度、ボタンの位置案内をしゃべる
                self.speakArrivalPanelGuide()
            }
        }
    }


    
    func stopAllTTS() {
        // ただちに読み上げを止める（キューに入ってる分も含めて）
        tts.stopSpeaking(at: .immediate)

        // クールダウン管理用の履歴もリセットしておく
        lastSpokenAt.removeAll()
    }

    private func configureAccessibility() {
        arrivalPanelView.isAccessibilityElement = true
        arrivalPanelView.accessibilityLabel = "到着確認"
        arrivalPanelView.accessibilityHint = "終了するか続けるかを選択してください。"
        
        startGuidanceButton.isAccessibilityElement = false
        startGuidanceButton.accessibilityElementsHidden = true

        arrivalContinueButton.isAccessibilityElement = true
        arrivalContinueButton.accessibilityLabel = "案内を続ける"
        arrivalContinueButton.accessibilityHint = "空席案内を続行します。"

        arrivalFinishButton.isAccessibilityElement = true
        arrivalFinishButton.accessibilityLabel = "案内を終了する"
        arrivalFinishButton.accessibilityHint = "空席案内を終了します。"
        
        debugTextView.isAccessibilityElement = false
        debugTextView.accessibilityElementsHidden = true
        
        TextView.isAccessibilityElement = false
    }
    
    private func startSituationCheckIfNeeded() {
        guard isGuidancePaused else { return }
        guard !isSituationCheckInProgress else { return }

        stateQueue.sync {
            isSituationCheckInProgress = true
            situationEmptySeatCounts.removeAll()
            situationPersonCounts.removeAll()
        }

        interruptAndSpeak(
            text: "周囲を確認します。",
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitch: 0.9,
            volume: 1.0
        )

        situationCheckTimer?.invalidate()
        situationCheckTimer = Timer.scheduledTimer(withTimeInterval: situationCheckDuration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let summary: String = self.stateQueue.sync {
                self.isSituationCheckInProgress = false
                let emptySeats = self.modeCount(from: self.situationEmptySeatCounts)
                let people = self.modeCount(from: self.situationPersonCounts)
                return self.situationSummaryText(emptySeatCount: emptySeats, personCount: people)
            }
            self.interruptAndSpeak(
                text: "\(summary)案内を開始してください。",
                rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                pitch: 0.9,
                volume: 1.0
            )
        }
    }

    private func stopSituationCheck() {
        situationCheckTimer?.invalidate()
        situationCheckTimer = nil
        stateQueue.sync {
            isSituationCheckInProgress = false
        }
    }
    
    private func recordSituationCounts(emptySeatCount: Int, personCount: Int) {
        situationEmptySeatCounts[emptySeatCount, default: 0] += 1
        situationPersonCounts[personCount, default: 0] += 1
    }

    private func modeCount(from counts: [Int: Int]) -> Int {
        guard let (value, _) = counts.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }) else {
            return 0
        }
        return value
    }
    
    private func situationSummaryText(emptySeatCount: Int, personCount: Int) -> String {
        let personCountText: String
        switch personCount {
        case 1:
            personCountText = "ひとり"
        case 2:
            personCountText = "ふたり"
        default:
            personCountText = "\(personCount)人"
        }
        if emptySeatCount == 0 {
            return "空席はありません。周囲の人は\(personCountText)です。"
        }
        if personCount == 0 {
            return "空席は\(emptySeatCount)席、周囲の人は\(personCountText)です。"
        }
        return "空席は\(emptySeatCount)席、周囲の人は\(personCount)人です。"
    }


    private func announceForAccessibility(_ message: String) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message)
    }

    private func isVoiceOverRunning() -> Bool {
        UIAccessibilityIsVoiceOverRunning()
    }
    
    func playSFX(named filename: String, completion: (() -> Void)? = nil) {
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            print("SFX file not found: \(filename)")
            completion?()
            return
        }

        do {
            sfxPlayer = try AVAudioPlayer(contentsOf: url)
            sfxPlayer?.prepareToPlay()

            // 再生後に completion を呼ぶ
            sfxPlayer?.play()

            if let comp = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + (sfxPlayer?.duration ?? 0.1)) {
                    comp()
                }
            }

        } catch {
            print("Error loading SFX: \(error)")
            completion?()
        }
    }
    
    func speakWithSFX(_ utterance: AVSpeechUtterance) {
        // 効果音 → 発話 の順
        playSFX(named: "NaviSound01.mp3") { [weak self] in
            self?.tts.speak(utterance)
        }
    }

    static func cgImageOrientationForDevice() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default:
            let o = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.interfaceOrientation
            switch o {
            case .portrait: return .right
            case .portraitUpsideDown: return .left
            case .landscapeLeft: return .up
            case .landscapeRight: return .down
            default: return .right
            }
        }
    }

    func createNewBubbleParentNode(_ text: String) -> SCNNode {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return SCNNode() }

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y

        let scnText = SCNText(string: t, extrusionDepth: CGFloat(bubbleDepth))
        var font = UIFont(name: "Futura", size: 0.15)
        font = font?.withTraits(traits: .traitBold)
        scnText.font = font
        scnText.alignmentMode = kCAAlignmentCenter
        scnText.firstMaterial?.diffuse.contents = UIColor.orange
        scnText.firstMaterial?.specular.contents = UIColor.white
        scnText.firstMaterial?.isDoubleSided = true
        scnText.chamferRadius = CGFloat(bubbleDepth)

        let (minB, maxB) = scnText.boundingBox
        let textNode = SCNNode(geometry: scnText)
        textNode.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x)/2, minB.y, bubbleDepth/2)
        textNode.scale = SCNVector3(0.2, 0.2, 0.2)

        let dot = SCNSphere(radius: 0.005)
        dot.firstMaterial?.diffuse.contents = UIColor.cyan
        let dotNode = SCNNode(geometry: dot)

        let parent = SCNNode()
        parent.addChildNode(textNode)
        parent.addChildNode(dotNode)
        parent.constraints = [billboard]
        return parent
    }
}

// MARK: - UIFont helper
private extension UIFont {
    func withTraits(traits: UIFontDescriptor.SymbolicTraits...) -> UIFont {
        let d = fontDescriptor.withSymbolicTraits(UIFontDescriptor.SymbolicTraits(traits))
        return UIFont(descriptor: d!, size: 0)
    }
}
