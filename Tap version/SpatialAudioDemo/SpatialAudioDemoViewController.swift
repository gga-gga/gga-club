//
//  SpatialAudioDemoViewController.swift
//  SUWARERU
//
//  立体音響による方向案内の可能性を探るための体験画面（試作）。空席の検出や誘導とは独立している。
//
//  やること：
//   - 部屋の決まった方向に「見えない音源」を置き、イヤホンからその方向に聞こえるように音を鳴らす
//   - 参加者は、音が聞こえる方向へ体ごと向きを変える（スマートフォンは胸のポーチの中）
//   - 正面（±15°）に1秒向け続けたら成功。これを8回、方向を変えてくり返す
//   - 回ごとに、かかった時間と「最初に正しい側へ向きを変えたか」を記録して画面に出す
//
//  体の向きは ARKit のカメラの向きから求める（誘導画面と同じ：正面 = カメラの -Z、右が +）。
//  音源の方向は回の始めに「そのときの正面から右へ何度」で決め、部屋に固定する。
//
//  頭の向きと胸の向きの使い分け（どちらのイヤホンでも使えるようにしている）：
//   - 音の鳴らし方：対応イヤホン（AirPods など）なら頭の向き、それ以外は胸の向きで決める。
//     頭の向きを使うと、首を振っても音が部屋の同じ方向に留まり、前後を聞き分けやすい。
//   - 「正面に向いた」の判定・最初の向き：いつも胸（体）の向きで決める。誘導と同じく、
//     体が音の方を向いたときだけ成功にする。
//   - 頭の向きは、回の始めに「頭は体と同じ方を向いている」とみなして合わせる。
//     回の途中で受信が途切れたら、その回の残りは胸の向きで鳴らす。
//
//  操作（背面タップ。誘導画面と同じショートカットを使う）：
//   | 状態       | 2回                 | 3回                 |
//   |------------|---------------------|---------------------|
//   | 始める前   | 説明を聞く           | 始める               |
//   | 体験の途中 | 中止する             | 今の回を飛ばす        |
//  画面のボタンはスタッフ用（方向の付け方・音の種類の切り替え、結果のコピー、閉じる）。
//  方向の付け方（立体音響／左右の音量だけ）と音の種類（ビープ音／倍音ビープ／雑音パルス）を
//  別々に選べるので、「方向の付け方の差」と「音の種類の差」を分けて比べられる。
//

import ARKit
import UIKit
import simd

final class SpatialAudioDemoViewController: UIViewController, ShortcutActionHandling {

    // MARK: - 設定

    /// 回ごとの音源の方向[度]。回の始めの正面から見て、右が +、左が −。
    /// 参加者どうしで比べられるよう、順番は固定。後ろ（±135°、150°）も含めている
    static let trialOffsetsDeg: [Float] = [60, -90, 30, -135, 90, -45, 150, -30]
    /// 音源が正面からこの角度以内なら「向きが合っている」とみなす
    static let alignedToleranceDeg: Float = 15
    /// 向きが合った状態をこの秒数続けたら成功
    static let alignedHoldSeconds: TimeInterval = 1.0
    /// この秒数で見つけられなければ時間切れ
    static let trialTimeoutSeconds: TimeInterval = 30
    /// 回と回の間の休み[秒]
    static let restSeconds: TimeInterval = 2.0
    /// 回の始めからこの角度以上向きを変えたら、その向き（右か左か）を「最初の向き」として記録する
    static let firstTurnThresholdDeg: Float = 10

    // MARK: - 状態

    private enum Phase {
        case idle        // 始める前
        case briefing    // 説明を話している
        case trial       // 音を鳴らしている
        case rest        // 回と回の間
        case finished    // 終わった（結果を表示）
    }

    private enum Outcome {
        case found(seconds: TimeInterval)
        case timedOut
        case skipped
    }

    /// その回で、音の鳴らし方に何の向きを使ったか
    private enum ListeningSource {
        case head          // 最後まで頭の向き
        case chest         // 最初から胸の向き
        case headThenChest // 途中で頭の向きが途切れ、胸の向きに切り替えた

        var text: String {
            switch self {
            case .head: return "頭"
            case .chest: return "胸"
            case .headThenChest: return "頭→胸"
            }
        }
    }

    private struct TrialResult {
        let offsetDeg: Float
        let outcome: Outcome
        /// 最初に向きを変えた側が、音源のある側だったか（向きを変える前に終わったら nil）
        let firstTurnCorrect: Bool?
        let listeningSource: ListeningSource
    }

    private let arSession = ARSession()
    private let speechOutput = SpeechOutput()
    private let beacon = SpatialBeaconPlayer()
    private let headTracker = HeadOrientationTracker()
    private var displayLink: CADisplayLink?

    private var phase: Phase = .idle
    private var phaseReadyAt: TimeInterval = 0
    private var trialIndex = 0
    private var results: [TrialResult] = []
    /// 音源の方向（部屋に固定。水平面の単位ベクトルで、x = 世界座標の X、y = 世界座標の Z）
    private var targetDirection: simd_float2?
    /// 回の始めの正面の向き
    private var trialStartForward: simd_float2?
    private var trialStartedAt: TimeInterval = 0
    private var alignedSince: TimeInterval?
    private var firstTurnCorrect: Bool?
    /// 頭の向きを合わせたときの値（頭の向き・そのときの胸の正面）。頭の向きを使わない回は nil
    private var headCalibration: (yaw: Double, forward: simd_float2)?
    private var trialListeningSource: ListeningSource = .chest
    /// 体験を始めたときの設定（結果に書く）
    private var sessionRendering: SpatialBeaconPlayer.Rendering = .hrtf
    private var sessionUsesAlignedCue = true
    private var sessionTone: SpatialBeaconPlayer.Tone = .beep
    private var sessionUsesHead = true

    // MARK: - 画面の部品（スタッフ用）

    private let renderingControl = UISegmentedControl(items: ["立体音響", "左右の音量だけ"])
    private let toneControl = UISegmentedControl(items: SpatialBeaconPlayer.Tone.allCases.map { $0.displayName })
    private let cueSwitch = UISwitch()
    private let headSwitch = UISwitch()
    private let headStatusLabel = UILabel()
    private let statusLabel = UILabel()
    private let resultView = UITextView()
    private let startButton = UIButton(type: .system)

    // MARK: - ライフサイクル

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildLayout()
        updateStatus("背面を3回タップ、または「始める」で開始します。")
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        ShortcutActionCenter.shared.setHandler(self)
        UIApplication.shared.isIdleTimerDisabled = true

        // 体の向きを知るためだけに ARKit を動かす（深度や平面の検出は使わない）
        arSession.run(ARWorldTrackingConfiguration())
        beacon.start()
        // 始める前から受信しておき、対応イヤホンがつながっているかを画面に出す
        headTracker.start()

        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ShortcutActionCenter.shared.clearHandler(self)
        UIApplication.shared.isIdleTimerDisabled = false
        displayLink?.invalidate()
        displayLink = nil
        beacon.stop()
        headTracker.stop()
        speechOutput.stop()
        arSession.pause()
    }

    // MARK: - 背面タップ・VoiceOver のジェスチャ

    func handleShortcutAction(_ action: ShortcutAction) {
        guard isViewLoaded, view.window != nil else { return }
        switch phase {
        case .idle, .finished:
            switch action {
            case .primary:
                startSession()
            case .secondary:
                say("立体音響の体験です。背面を3回タップすると始まります。音が聞こえる方向へ、体ごと向きを変えてください。")
            }
        case .briefing, .trial, .rest:
            switch action {
            case .primary:
                skipCurrentTrial()
            case .secondary:
                abortSession()
            }
        }
    }

    override func accessibilityPerformMagicTap() -> Bool {
        handleShortcutAction(.primary)
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        handleShortcutAction(.secondary)
        return true
    }

    // MARK: - 体験の流れ

    private func startSession() {
        sessionRendering = renderingControl.selectedSegmentIndex == 0 ? .hrtf : .panning
        sessionUsesAlignedCue = cueSwitch.isOn
        let tones = SpatialBeaconPlayer.Tone.allCases
        sessionTone = tones.indices.contains(toneControl.selectedSegmentIndex)
            ? tones[toneControl.selectedSegmentIndex] : .beep
        sessionUsesHead = headSwitch.isOn
        beacon.rendering = sessionRendering
        beacon.tone = sessionTone
        beacon.isSounding = false
        results = []
        trialIndex = 0
        resultView.text = ""

        let count = Self.trialOffsetsDeg.count
        let cue = sessionUsesAlignedCue
            ? "音が正面に来ると、高い音に変わります。"
            : "音が正面に来たら、声でお知らせします。"
        // 頭の向きを受信できているときだけ、首を振って確かめてよいと伝える
        let usesHeadNow = sessionUsesHead && headTracker.currentYaw(now: CACurrentMediaTime()) != nil
        let headHint = usesHeadNow ? "首を振って音の方向を確かめても構いません。最後は体ごと向けてください。" : ""
        say("音の方向を当てる体験を始めます。音が聞こえる方向へ、体ごとゆっくり向きを変えてください。\(headHint)\(cue)全部で\(count)回です。")
        phase = .briefing
        phaseReadyAt = CACurrentMediaTime() + 1.0
        updateStatus("説明中…")
    }

    private func beginTrial(now: TimeInterval) {
        // 体の向きがまだ分からなければ、分かるまで待つ（次の更新でもう一度呼ばれる）
        guard let forward = currentForward() else {
            updateStatus("体の向きを確認中…（カメラを前に向けてください）")
            return
        }
        let offsetDeg = Self.trialOffsetsDeg[trialIndex]
        let offset = offsetDeg * .pi / 180
        targetDirection = cos(offset) * forward + sin(offset) * Self.right(of: forward)
        trialStartForward = forward
        trialStartedAt = now
        alignedSince = nil
        firstTurnCorrect = nil

        // 頭の向きを使うなら、ここで「頭は体と同じ方を向いている」とみなして合わせる
        if sessionUsesHead, let headYaw = headTracker.currentYaw(now: now) {
            headCalibration = (yaw: headYaw, forward: forward)
            trialListeningSource = .head
        } else {
            headCalibration = nil
            trialListeningSource = .chest
        }

        beacon.usesAlignedPing = false
        beacon.setRelativeBearing(radians: offset)
        beacon.isSounding = true
        phase = .trial
    }

    private func updateTrial(now: TimeInterval) {
        guard let target = targetDirection, let startForward = trialStartForward else { return }
        let offsetDeg = Self.trialOffsetsDeg[trialIndex]

        if let forward = currentForward() {
            // 音を聞く向き：頭の向きを受信できていれば頭、なければ胸
            var listeningForward = forward
            if let calibration = headCalibration {
                if let headYaw = headTracker.currentYaw(now: now) {
                    let turn = Float(Self.wrapAngle(headYaw - calibration.yaw))
                    listeningForward = cos(turn) * calibration.forward
                        + sin(turn) * Self.right(of: calibration.forward)
                } else {
                    // 頭の向きが途切れたら、この回の残りは胸の向きで鳴らす
                    headCalibration = nil
                    trialListeningSource = .headThenChest
                }
            }
            beacon.setRelativeBearing(radians: Self.signedAngle(from: listeningForward, to: target))

            // 「正面に向いた」の判定は、体（胸）の正面から見た音源の方向で行う（右が +）
            let bearing = Self.signedAngle(from: forward, to: target)
            let bearingDeg = bearing * 180 / .pi

            let isAligned = abs(bearingDeg) <= Self.alignedToleranceDeg
            beacon.usesAlignedPing = isAligned && sessionUsesAlignedCue

            // 最初に向きを変えた側が、音源のある側だったか
            if firstTurnCorrect == nil {
                let turnedDeg = Self.signedAngle(from: startForward, to: forward) * 180 / .pi
                if abs(turnedDeg) >= Self.firstTurnThresholdDeg {
                    firstTurnCorrect = (turnedDeg > 0) == (offsetDeg > 0)
                }
            }

            var status = "\(trialIndex + 1) / \(Self.trialOffsetsDeg.count) 回目　音の方向（体から）：\(Self.sideText(degrees: bearingDeg))"
            if headCalibration != nil {
                // 頭が体からどちらへ向いているか（頭を右へ向けて「右」と出れば、向きの符号は正しい）
                let headDeg = Self.signedAngle(from: forward, to: listeningForward) * 180 / .pi
                status += "\n頭の向き（体から）：\(Self.sideText(degrees: headDeg))"
            }
            updateStatus(status)

            if isAligned {
                let since = alignedSince ?? now
                alignedSince = since
                if now - since >= Self.alignedHoldSeconds {
                    completeTrial(.found(seconds: now - trialStartedAt), now: now)
                    return
                }
            } else {
                alignedSince = nil
            }
        }

        if now - trialStartedAt >= Self.trialTimeoutSeconds {
            completeTrial(.timedOut, now: now)
        }
    }

    private func completeTrial(_ outcome: Outcome, now: TimeInterval) {
        beacon.isSounding = false
        beacon.usesAlignedPing = false
        results.append(TrialResult(offsetDeg: Self.trialOffsetsDeg[trialIndex],
                                   outcome: outcome,
                                   firstTurnCorrect: firstTurnCorrect,
                                   listeningSource: trialListeningSource))
        headCalibration = nil
        resultView.text = resultText()
        trialIndex += 1

        let isLast = trialIndex >= Self.trialOffsetsDeg.count
        let head: String
        switch outcome {
        case .found: head = "正面です。"
        case .timedOut: head = "時間切れです。"
        case .skipped: head = "飛ばします。"
        }
        if isLast {
            finishSession(spokenHead: head)
        } else {
            say("\(head)次の音が鳴ります。")
            phase = .rest
            phaseReadyAt = now + Self.restSeconds
            updateStatus("休み…")
        }
    }

    private func skipCurrentTrial() {
        let now = CACurrentMediaTime()
        switch phase {
        case .trial:
            completeTrial(.skipped, now: now)
        case .briefing, .rest:
            // 説明や休みの途中なら、待たずに次の音を鳴らす
            speechOutput.stop()
            phaseReadyAt = now
        case .idle, .finished:
            break
        }
    }

    private func abortSession() {
        beacon.isSounding = false
        phase = .finished
        resultView.text = resultText()
        say("体験を中止しました。")
        updateStatus("中止しました。3回タップでもう一度始められます。")
    }

    private func finishSession(spokenHead: String) {
        beacon.isSounding = false
        phase = .finished
        resultView.text = resultText()
        let found = results.filter { if case .found = $0.outcome { return true } else { return false } }.count
        say("\(spokenHead)これで終わりです。\(results.count)回のうち\(found)回、音の方向を向けました。お疲れさまでした。")
        updateStatus("終了しました。3回タップでもう一度始められます。")
    }

    /// 画面の更新ごと（1秒に30回）に呼ばれる
    @objc private func tick() {
        let now = CACurrentMediaTime()
        switch phase {
        case .briefing, .rest:
            // 話し終わって、休みの時間も過ぎたら次の回へ
            if !speechOutput.isBusy && now >= phaseReadyAt {
                beginTrial(now: now)
            }
        case .trial:
            updateTrial(now: now)
        case .idle, .finished:
            break
        }
        beacon.tick(now: now)
        headTracker.tick(now: now)
        updateHeadStatus(now: now)
    }

    /// 頭の向きを受信できているかを、スタッフ向けに表示する
    private func updateHeadStatus(now: TimeInterval) {
        let text: String
        if !headSwitch.isOn {
            text = "頭の向き：使わない（胸の向きで音を鳴らす）"
        } else if !HeadOrientationTracker.hasUsageDescription {
            text = "頭の向き：使えません（Info.plist に NSMotionUsageDescription が必要）"
        } else if !headTracker.isSupported {
            text = "頭の向き：この端末では使えません（胸の向きで音を鳴らす）"
        } else if headTracker.currentYaw(now: now) == nil {
            text = "頭の向き：受信なし（対応イヤホンでない・未接続・許可なし。胸の向きで音を鳴らす）"
        } else {
            text = "頭の向き：受信中（頭の向きで音を鳴らす）"
        }
        if headStatusLabel.text != text {
            headStatusLabel.text = text
        }
    }

    // MARK: - 体の向き

    /// 今の正面の向き（水平面の単位ベクトル）。カメラが真上・真下を向いていて決められないときは nil
    private func currentForward() -> simd_float2? {
        guard let transform = arSession.currentFrame?.camera.transform else { return nil }
        // カメラの前方は -Z。その水平成分（世界座標の X と Z）
        let flat = simd_float2(-transform.columns.2.x, -transform.columns.2.z)
        guard simd_length(flat) > 0.2 else { return nil }
        return simd_normalize(flat)
    }

    /// 正面の向きに対する右向き（誘導画面と同じ：正面 × 上）
    private static func right(of forward: simd_float2) -> simd_float2 {
        simd_float2(-forward.y, forward.x)
    }

    /// a から見た b の角度[ラジアン]。b が a の右にあれば +
    private static func signedAngle(from a: simd_float2, to b: simd_float2) -> Float {
        atan2(simd_dot(b, right(of: a)), simd_dot(b, a))
    }

    /// 角度[ラジアン]を −π〜π に収める
    private static func wrapAngle(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    /// 「右 45°」「左 10°」のような表示
    private static func sideText(degrees: Float) -> String {
        "\(degrees >= 0 ? "右" : "左") \(Int(abs(degrees).rounded()))°"
    }

    // MARK: - 読み上げ・表示

    private func say(_ text: String) {
        speechOutput.stop()
        speechOutput.speak(speechOutput.makeUtterance(text))
    }

    private func updateStatus(_ text: String) {
        if statusLabel.text != text {
            statusLabel.text = text
        }
    }

    private func resultText() -> String {
        let renderingName = sessionRendering == .hrtf ? "立体音響" : "左右の音量だけ"
        var lines = ["設定：\(renderingName)・\(sessionTone.displayName)・正面の合図\(sessionUsesAlignedCue ? "あり" : "なし")・頭の向き\(sessionUsesHead ? "使う" : "使わない")"]

        var foundSeconds: [TimeInterval] = []
        var turnsJudged = 0
        var turnsCorrect = 0
        for (index, result) in results.enumerated() {
            let side = result.offsetDeg >= 0 ? "右" : "左"
            let angle = Int(abs(result.offsetDeg))
            let outcomeText: String
            switch result.outcome {
            case .found(let seconds):
                outcomeText = String(format: "%.1f秒", seconds)
                foundSeconds.append(seconds)
            case .timedOut:
                outcomeText = "時間切れ"
            case .skipped:
                outcomeText = "飛ばした"
            }
            let turnText: String
            switch result.firstTurnCorrect {
            case .some(true):
                turnText = "○"
                turnsJudged += 1
                turnsCorrect += 1
            case .some(false):
                turnText = "✕"
                turnsJudged += 1
            case .none:
                turnText = "−"
            }
            lines.append("\(index + 1)回目　\(side)\(angle)°　\(outcomeText)　最初の向き\(turnText)　聞く向き：\(result.listeningSource.text)")
        }

        if !results.isEmpty {
            lines.append("")
            lines.append("向けた回数：\(foundSeconds.count) / \(results.count)")
            if !foundSeconds.isEmpty {
                let mean = foundSeconds.reduce(0, +) / Double(foundSeconds.count)
                lines.append(String(format: "かかった時間の平均：%.1f秒", mean))
            }
            lines.append("最初の向きが合っていた回数：\(turnsCorrect) / \(turnsJudged)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 画面の組み立て

    private func buildLayout() {
        let titleLabel = UILabel()
        titleLabel.text = "立体音響の体験（試作）"
        titleLabel.font = .preferredFont(forTextStyle: .title2)

        renderingControl.selectedSegmentIndex = 0
        toneControl.selectedSegmentIndex = 0

        let renderingLabel = UILabel()
        renderingLabel.text = "方向の付け方"
        renderingLabel.font = .preferredFont(forTextStyle: .footnote)
        let toneLabel = UILabel()
        toneLabel.text = "音の種類"
        toneLabel.font = .preferredFont(forTextStyle: .footnote)

        let cueLabel = UILabel()
        cueLabel.text = "正面に来たら音を変える"
        cueSwitch.isOn = true
        let cueRow = UIStackView(arrangedSubviews: [cueLabel, cueSwitch])
        cueRow.axis = .horizontal
        cueRow.spacing = 12

        let headLabel = UILabel()
        headLabel.text = "頭の向きを使う（対応イヤホン）"
        headSwitch.isOn = true
        let headRow = UIStackView(arrangedSubviews: [headLabel, headSwitch])
        headRow.axis = .horizontal
        headRow.spacing = 12

        headStatusLabel.numberOfLines = 0
        headStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        headStatusLabel.textColor = .secondaryLabel

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .body)

        startButton.setTitle("始める", for: .normal)
        startButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        startButton.addTarget(self, action: #selector(startButtonTapped), for: .touchUpInside)

        resultView.isEditable = false
        resultView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        resultView.layer.borderColor = UIColor.separator.cgColor
        resultView.layer.borderWidth = 1
        resultView.layer.cornerRadius = 6

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("結果をコピー", for: .normal)
        copyButton.addTarget(self, action: #selector(copyResults), for: .touchUpInside)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("閉じる", for: .normal)
        closeButton.addTarget(self, action: #selector(closeDemo), for: .touchUpInside)

        let bottomRow = UIStackView(arrangedSubviews: [copyButton, closeButton])
        bottomRow.axis = .horizontal
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 12

        let stack = UIStackView(arrangedSubviews: [titleLabel, renderingLabel, renderingControl,
                                                   toneLabel, toneControl, cueRow, headRow, headStatusLabel,
                                                   statusLabel, startButton, resultView, bottomRow])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(4, after: renderingLabel)
        stack.setCustomSpacing(4, after: toneLabel)
        stack.setCustomSpacing(4, after: headRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -20)
        ])
    }

    @objc private func startButtonTapped() {
        handleShortcutAction(.primary)
    }

    @objc private func copyResults() {
        UIPasteboard.general.string = resultView.text
    }

    @objc private func closeDemo() {
        dismiss(animated: true)
    }
}
