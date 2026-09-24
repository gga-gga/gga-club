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

extension ViewController {
    // MARK: - 角度・距離（現在のカメラ姿勢基準）

    /// world座標Pに対する「水平（Yaw）角度」[deg]
    func yawAngleToCameraCenter(worldPos P: simd_float3) -> Float? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        return GuidanceMath.yawAngleDeg(to: P, cameraTransform: frame.camera.transform)
    }

    /// Trackの現在位置から、発話直前に「水平Yaw角[deg]」を再計算
    func liveYawDeg(for track: Track) -> Float? {
        guard let frame = sceneView.session.currentFrame else { return nil }
        let t = track.worldTransform
        // 垂直方向は無視して水平面だけで角度を計算する
        let cameraY = frame.camera.transform.columns.3.y
        let p = simd_float3(t.columns.3.x, cameraY, t.columns.3.z)
        return self.yawAngleToCameraCenter(worldPos: p)
    }

    /// ※既知の問題：3D距離なので、スマホと座面の高さの差だけ長く出る（段階1で水平距離に変更予定）
    func liveDistanceMeters(for track: Track) -> Float {
        guard let frame = sceneView.session.currentFrame else { return track.depthMeters }
        let cam = simd_float3(frame.camera.transform.columns.3.x,
                              frame.camera.transform.columns.3.y,
                              frame.camera.transform.columns.3.z)
        let t = track.worldTransform
        let p = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        return simd_length(p - cam)
    }

    // MARK: - 方向振動

    func updateDirectionHaptics(for track: Track?) {
        guard !isGuidancePaused,
              !isFinishingNavigation,
              let track = track,
              let yaw = liveYawDeg(for: track),
              let angleDiff = GuidanceMath.directionDifferenceAngleDeg(fromYawDeg: yaw) else {
            directionHaptics.stop()
            return
        }
        directionHaptics.update(angleDiff: angleDiff)
    }

    // MARK: - 空席なし監視

    /// 1秒ごとに呼ばれて、空席がしばらく見つからないときにアナウンスする
    @objc func checkNoSeatState() {
        let now = CACurrentMediaTime()

        // 座席としてカウントするTrackが1つでもあるか？
        let hasSeat = self.tracks.values.contains { tr in
            seatLabels.contains(tr.label)
        }

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
