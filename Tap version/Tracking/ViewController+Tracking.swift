//
//  ViewController+Tracking.swift
//  SUWARERU
//
//  描画側の定期処理（約0.4秒ごと）：古いトラックを忘れる、案内先の更新、到着判定、3Dラベルの更新。
//  検出の取り込み（SeatTracker.integrate）は推論直後に ViewController+Detection で行っている。
//

import ARKit
import SceneKit
import UIKit
import simd

/// 1回の定期処理の結果（UI・音声・振動への反映は呼び出し側で行う）
struct TrackingStepResult {
    var targetEvent: TargetEvent = .unchanged
    var target: Track?
    /// 確定済みのトラック（3Dラベル・一覧表示用）
    var confirmedTracks: [Track] = []
    var shouldShowArrivalPanel = false
    var currentEmptySeatCount = 0
    var currentPersonCount = 0
}

extension ViewController {
    func runTrackingStep(now: TimeInterval, cameraPosition: simd_float3) -> TrackingStepResult {
        stateQueue.sync { () -> TrackingStepResult in
            var result = TrackingStepResult()

            seatTracker.prune(now: now)
            result.targetEvent = seatTracker.updateTarget(from: cameraPosition, now: now)

            // 到着判定は案内中の案内先だけ。一度到着したら同じ席では繰り返さない
            // （状況確認中に近くにいただけで「到着済み」にしてしまわないよう、案内中に限る）
            if !isGuidancePaused, let target = seatTracker.target, !target.arrivalAnnounced,
               horizontalDistance(from: cameraPosition, to: target) <= arrivalThresholdMeters {
                seatTracker.markArrivalAnnounced(target.id)
                if askExitOnArrivalEnabled {
                    result.shouldShowArrivalPanel = true
                }
            }

            result.target = seatTracker.target
            result.confirmedTracks = seatTracker.confirmedTracks
            result.currentEmptySeatCount = lastEmptySeatCount
            result.currentPersonCount = lastPersonCount
            return result
        }
    }

    /// 確定済みトラックの3Dラベルを作成・移動・削除する（描画スレッドから呼ぶ）。
    /// 色：案内先＝オレンジ、その他の空席＝白、埋まっている席＝灰色
    func updateTrackNodes(confirmedTracks: [Track], targetID: UUID?) {
        let liveIDs = Set(confirmedTracks.map { $0.id })
        for (id, node) in trackNodes where !liveIDs.contains(id) {
            node.removeFromParentNode()
            trackNodes.removeValue(forKey: id)
        }

        for track in confirmedTracks {
            let node: SCNNode
            if let existing = trackNodes[track.id] {
                node = existing
            } else {
                node = LabelNodeFactory.makeBubbleNode(text: track.label)
                autoLabelsRoot.addChildNode(node)
                trackNodes[track.id] = node
            }
            node.simdPosition = track.worldPosition

            let color: UIColor
            if track.id == targetID {
                color = .orange
            } else if track.isEmpty {
                color = .white
            } else {
                color = .gray
            }
            LabelNodeFactory.setColor(color, of: node)
        }
    }

    /// 画面の一覧表示：確定済みの席を近い順に（★＝案内先）
    func trackListText(confirmedTracks: [Track], targetID: UUID?, cameraPosition: simd_float3) -> String {
        confirmedTracks
            .sorted { horizontalDistance(from: cameraPosition, to: $0) < horizontalDistance(from: cameraPosition, to: $1) }
            .prefix(3)
            .map { track -> String in
                let mark = track.id == targetID ? "★" : "  "
                let state = track.isEmpty ? "空席" : "埋まり"
                let yaw = yawAngleToCameraCenter(worldPos: track.worldPosition).map { String(format: "%+.0f°", $0) } ?? "-"
                let distance = String(format: "%.1fm", horizontalDistance(from: cameraPosition, to: track))
                return "\(mark)\(state) \(yaw) (\(distance))"
            }
            .joined(separator: "\n")
    }

    private func horizontalDistance(from cameraPosition: simd_float3, to track: Track) -> Float {
        simd_length(simd_float2(track.worldPosition.x - cameraPosition.x,
                                track.worldPosition.z - cameraPosition.z))
    }
}
