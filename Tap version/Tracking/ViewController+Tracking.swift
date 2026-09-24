//
//  ViewController+Tracking.swift
//  SUWARERU
//
//  毎フレーム（約0.4秒ごと）のトラック更新：古いトラックの掃除、検出との対応付け・新規作成、
//  読み上げ対象と到着の判定、案内対象の選択。
//
//  ※既知の問題（段階3で作り直す予定。現状の挙動を変えないためにそのまま移設している）
//   - 椅子のトラックは1つだけ（maxTracksPerLabel=1）で、別の椅子の検出でも lastSeen が更新される
//   - トラックの位置は作成時のまま更新されない
//   - 距離2m以内の椅子トラックはタイムアウトしても消えない
//

import ARKit
import SceneKit
import UIKit
import simd

/// 1回のトラック更新の結果（UI・音声への反映は呼び出し側で行う）
struct TrackingStepResult {
    var angleLines = ""
    var tracksToSpeak: [Track] = []
    var shouldShowArrivalPanel = false
    var didProcessDetections = false
    var currentEmptySeatCount = 0
    var currentPersonCount = 0
}

extension ViewController {
    func runTrackingStep(time: TimeInterval) -> TrackingStepResult {
        var result = TrackingStepResult()

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

            result.currentEmptySeatCount = self.lastEmptySeatCount
            result.currentPersonCount = self.lastPersonCount

            guard !self.pendingDetections.isEmpty else { return }
            result.didProcessDetections = true

            // 高信頼順に処理
            let sortedDet = self.pendingDetections.sorted { $0.confidence > $1.confidence }
            var createdCount = 0

            for det in sortedDet {
                // 検出の3D位置（深度優先→Raycast）。対応付けの深さゲートと新規作成の両方で使う
                let samplePoint = WorldPositionEstimator.preferredSamplePoint(for: det)
                let placement = self.positionEstimator.worldTransformAndDepthFirst(at: samplePoint)

                // 1) 既存トラックにマッチ（同ラベル + 2D + 深さゲート）
                if let (tid, _) = self.trackMatcher.findMatchingTrack(for: det,
                                                                     detectionDepth: placement?.1,
                                                                     in: self.tracks) {
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
                        if let (tid, _) = self.trackMatcher.findNearestTrackOfSameLabel(det: det, in: self.tracks) {
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

                    // 本当に新規作成
                    guard let (wt, depth) = placement,
                          let frame = self.sceneView.session.currentFrame else { continue }

                    let worldPos = simd_float3(wt.columns.3.x, wt.columns.3.y, wt.columns.3.z)
                    if WorldPositionEstimator.isLikelyFloorPosition(worldPos, cameraTransform: frame.camera.transform) {
                        continue
                    }
                    let node = LabelNodeFactory.makeBubbleNode(text: det.label)
                    node.simdTransform = wt
                    self.autoLabelsRoot.addChildNode(node)

                    // 角度は水平Yawで保存
                    let angle = self.yawAngleToCameraCenter(worldPos: worldPos)

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
                    result.tracksToSpeak.append(t)
                }

                if self.tracks.count >= self.maxTextsPerFrame { break }
            }

            // 角度＆距離を TextView に出力（中心に近い順で上限数）
            result.angleLines = self.tracks.values
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
                            result.tracksToSpeak.append(tr)
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
                                result.shouldShowArrivalPanel = true
                            }
                        }
                    }
                }
            }

            // 検出を使い切る
            self.pendingDetections.removeAll()
        }

        return result
    }

    /// 案内対象：まだ生きている座席トラックのうち最も近いもの
    func selectTargetTrack(time: TimeInterval) -> Track? {
        let activeSeatTracks = self.tracks.values.filter { tr in
            self.seatLabels.contains(tr.label) && time - tr.lastSeen <= self.trackTimeout
        }
        return activeSeatTracks.min { lhs, rhs in
            self.liveDistanceMeters(for: lhs) < self.liveDistanceMeters(for: rhs)
        }
    }
}
