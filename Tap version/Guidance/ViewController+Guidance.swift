//
//  ViewController+Guidance.swift
//  SUWARERU
//
//  現在のカメラ姿勢を使った角度・距離、方向振動、空席なし監視、案内開始前の状況確認。
//

import ARKit
import AVFoundation
import UIKit
import simd

/// 案内先の方向と距離（描画スレッドで計算し、メインスレッドの読み上げ・振動に渡す）
struct TargetGuidance {
    let trackID: UUID
    /// 案内する方向の水平角度[deg]（右が +）。経路があれば次に向かう点、無ければ空席そのもの
    let yawDeg: Float
    /// 空席そのものの水平角度[deg]（デバッグ表示用）
    let seatYawDeg: Float
    /// 経路に沿って案内しているか（false＝経路が無く空席の方向を直接案内している）
    let followsPath: Bool
    /// 空席までの水平距離[m]
    let distance: Float

    var isBehind: Bool { abs(yawDeg) >= 90 }

    init(target: Track, cameraTransform: simd_float4x4, steeringPoint: simd_float3?) {
        trackID = target.id
        seatYawDeg = GuidanceMath.yawAngleDeg(to: target.worldPosition, cameraTransform: cameraTransform)
        if let steeringPoint {
            yawDeg = GuidanceMath.yawAngleDeg(to: steeringPoint, cameraTransform: cameraTransform)
            followsPath = true
        } else {
            yawDeg = seatYawDeg
            followsPath = false
        }
        let camera = cameraTransform.columns.3
        distance = simd_length(simd_float2(target.worldPosition.x - camera.x,
                                           target.worldPosition.z - camera.z))
    }
}

extension ViewController {
    // MARK: - 角度・距離（現在のカメラ姿勢基準）

    /// world座標Pに対する「水平（Yaw）角度」[deg]
    func yawAngleToCameraCenter(worldPos P: simd_float3) -> Float? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        return GuidanceMath.yawAngleDeg(to: P, cameraTransform: frame.camera.transform)
    }

    // MARK: - 方向振動

    /// メインスレッドから呼ぶ。案内中で、到着パネル・終了処理中でないときだけ振動させる
    func updateDirectionHaptics(for guidance: TargetGuidance?) {
        guard !isGuidancePaused,
              !isFinishingNavigation,
              !isAwaitingArrivalDecision,
              let guidance else {
            directionHaptics.stop()
            return
        }
        directionHaptics.update(yawDeg: guidance.yawDeg)
    }

    // MARK: - 空席なし監視

    /// 1秒ごとに呼ばれて、空席がしばらく見つからないときにアナウンスする
    @objc func checkNoSeatState() {
        let now = CACurrentMediaTime()

        // 案内できる空席（確定済み・空席判定）が1つでもあるか？
        let hasSeat = stateQueue.sync { self.seatTracker.hasAvailableSeat }

        switch noSeatMonitor.tick(now: now, isGuidancePaused: isGuidancePaused, hasSeat: hasSeat) {
        case .firstWarning:
            speakNoSeatWarning()
        case .finalWarning:
            speakNoSeatAndRestartSituationCheck()
        case .idle:
            break
        }
    }

    // MARK: - 状況確認（案内開始前）

    /// - Parameter announcesStart: 開始時に「計測をしています」と読み上げるか
    ///   （床を確認できずにやり直すときは、やり直しの案内を先に読み上げているので読み上げない）
    func startSituationCheckIfNeeded(announcesStart: Bool = true) {
        guard isGuidancePaused else { return }
        guard !isSituationCheckInProgress else { return }

        stateQueue.sync {
            isSituationCheckInProgress = true
            situationTally.reset()
        }
        if announcesStart {
            let situationCheckAnnouncementDelay: TimeInterval = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + situationCheckAnnouncementDelay) { [weak self] in
                self?.interruptAndSpeak(
                    text: "人数と空席数の計測をしています。",
                    rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                    pitch: 0.9,
                    volume: 1.0
                )
            }
        }
        // 位置推定が正常だった時間だけを数え、situationCheckDuration に達したら終える
        situationCheckStartedAt = CACurrentMediaTime()
        situationCheckStableElapsed = 0
        situationCheckTimer?.invalidate()
        situationCheckTimer = Timer.scheduledTimer(withTimeInterval: Self.situationCheckTickInterval, repeats: true) { [weak self] _ in
            self?.tickSituationCheck()
        }
    }

    static let situationCheckTickInterval: TimeInterval = 0.25

    private func tickSituationCheck() {
        let isNormal = stateQueue.sync { trackingQuality.isNormal }
        if isNormal {
            situationCheckStableElapsed += Self.situationCheckTickInterval
        }
        let timedOut = CACurrentMediaTime() - situationCheckStartedAt >= situationCheckMaxDuration
        guard situationCheckStableElapsed >= situationCheckDuration || timedOut else { return }

        situationCheckTimer?.invalidate()
        situationCheckTimer = nil
        finishSituationCheck()
    }

    // MARK: - 位置推定が不安定なときの案内

    /// 位置推定が正常でない状態がこの秒数続いたら、ゆっくり動くよう伝える
    static let trackingUnstableNoticeDelay: TimeInterval = 5.0
    /// 不安定な状態が続く間は、この間隔で繰り返し伝える
    static let trackingUnstableNoticeRepeat: TimeInterval = 15.0

    /// メインスレッドから定期的に呼ぶ（renderer の0.4秒ごとの処理）
    func updateTrackingStabilityNotice(quality: ARTrackingQuality, now: TimeInterval) {
        if quality.isNormal {
            trackingUnstableSince = nil
            lastTrackingUnstableNoticeAt = nil
            return
        }
        let since = trackingUnstableSince ?? now
        trackingUnstableSince = since

        guard !isFinishingNavigation, !isAwaitingArrivalDecision else { return }
        guard now - since >= Self.trackingUnstableNoticeDelay else { return }
        if let last = lastTrackingUnstableNoticeAt, now - last < Self.trackingUnstableNoticeRepeat { return }
        // 他の案内を話している間は割り込まず、終わってから伝える
        guard !speechOutput.isBusy else { return }

        lastTrackingUnstableNoticeAt = now
        speechOutput.speakWithSFX(speechOutput.makeUtterance("周囲の認識が不安定です。ゆっくり動いてください。"))
    }

    /// 状況確認の終了：結果を読み上げる。床を一度も推定できていなければ、空席の有無を判断できない
    /// （座面の推定に床の高さが必要なため、空席があっても0席になる）ので、「空席なし」とは言わずにやり直す
    private func finishSituationCheck() {
        let result: (summary: String, seatCount: Int)? = stateQueue.sync { () -> (summary: String, seatCount: Int)? in
            isSituationCheckInProgress = false
            guard latestFloorY != nil else { return nil }
            let seatCount = seatTracker.availableSeatCount
            return (situationTally.summaryText(seatCount: seatCount), seatCount)
        }

        guard let result = result else {
            interruptAndSpeak(
                text: "周囲の床を確認できなかったため、空席を数えられませんでした。もう一度確認します。少し離れた床が見えるように、ゆっくり周囲を見回してください。",
                rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                pitch: 0.9,
                volume: 1.0
            )
            startSituationCheckIfNeeded(announcesStart: false)
            return
        }

        // 背面タップ：3回＝誘導を開始、2回＝もう一度確認（ViewController+BackTap）。
        // 空席が無いときは誘導を始められないので、やり直し方だけを伝える
        let prompt = result.seatCount > 0
            ? "誘導を開始するには背面を3回、もう一度確認するには2回タップしてください。"
            : "もう一度確認するには、背面を2回タップしてください。"
        interruptAndSpeak(text: result.summary + prompt)
    }

    /// 誘導を止めて、状況確認からやり直す（誘導中に空席が見つからない状態が続いたとき）
    func returnToSituationCheck() {
        isGuidancePaused = true
        abortConfirmationDeadline = nil
        noSeatMonitor.reset()
        directionHaptics.stop()
        updateAccessibilityForCurrentState()
        startSituationCheckIfNeeded(announcesStart: false)
    }

    func stopSituationCheck() {
        situationCheckTimer?.invalidate()
        situationCheckTimer = nil
        stateQueue.sync {
            isSituationCheckInProgress = false
        }
    }
}
