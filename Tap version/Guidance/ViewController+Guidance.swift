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
            speakNoSeatFinalAndExit()
        case .idle:
            break
        }
    }

    // MARK: - 状況確認（案内開始前）

    func startSituationCheckIfNeeded() {
        guard isGuidancePaused else { return }
        guard !isSituationCheckInProgress else { return }

        stateQueue.sync {
            isSituationCheckInProgress = true
            situationTally.reset()
        }
        let situationCheckAnnouncementDelay: TimeInterval = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + situationCheckAnnouncementDelay) { [weak self] in
            self?.interruptAndSpeak(
                text: "人数と空席数の計測をしています。",
                rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                pitch: 0.9,
                volume: 1.0
            )
        }
        situationCheckTimer?.invalidate()
        situationCheckTimer = Timer.scheduledTimer(withTimeInterval: situationCheckDuration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            let summary: String = self.stateQueue.sync {
                self.isSituationCheckInProgress = false
                return self.situationTally.summaryText()
            }
            self.interruptAndSpeak(
                text: "\(summary)背面を3回タップして案内を開始してください。",
                rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                pitch: 0.9,
                volume: 1.0
            )
        }
    }

    func stopSituationCheck() {
        situationCheckTimer?.invalidate()
        situationCheckTimer = nil
        stateQueue.sync {
            isSituationCheckInProgress = false
        }
    }
}
