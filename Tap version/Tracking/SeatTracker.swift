//
//  SeatTracker.swift
//  SUWARERU
//
//  座席トラックの管理と、案内先の選択。
//
//   - 対応付け：座面の3D位置どうしの水平距離で行う（画面上の BBox の重なりは使わない）
//   - 確定：同じ位置で一定時間・一定回数観測されたトラックだけを読み上げ・案内の対象にする
//   - 位置：直近の観測の各軸中央値（作成時の1回に固定しない）
//   - 空席らしさ：空席として観測されたら +1、座面に人が重なって見えたら -2 のスコアを積む。
//     画面に映っていないときはスコアを変えない（振り返っただけで忘れない）
//   - 案内先：候補を一定時間集めてから最も近い空席を選び、埋まるか見失うまで固定する
//
//  すべての操作は呼び出し側で stateQueue に乗せること（推論スレッドと描画スレッドの両方から使う）。
//

import ARKit
import UIKit
import simd

enum SeatTrackingConfig {
    /// 新しい観測を既存トラックに対応付ける水平距離[m]。ロングシート1席分（約0.45m）の半分より小さくする
    static let associationRadius: Float = 0.25
    /// 位置の中央値を取る直近の観測数
    static let positionHistoryCount = 10
    /// 確定の条件：この回数以上、この秒数以上にわたって、この広がり以内で観測されること
    static let confirmationMinObservations = 3
    static let confirmationMinDuration: TimeInterval = 1.0
    static let confirmationMaxSpread: Float = 0.2
    /// 空席らしさのスコア。空席として観測 +1、人が重なって観測 -2（埋まった方向に早く反応させる）
    static let emptyEvidence = 1
    static let occupiedEvidence = -2
    static let scoreMax = 10
    static let scoreMin = -10
    /// この秒数だけ観測（空席・人あり）がなければ忘れる。確定前のものは早めに捨てる
    static let forgetConfirmedAfter: TimeInterval = 60
    static let forgetTentativeAfter: TimeInterval = 3
    /// 最初の案内先を選ぶ前に候補を集める秒数
    static let targetSelectionWindow: TimeInterval = 2.0
    /// 同時に持つトラックの上限
    static let maxTracks = 8
}

struct Track {
    let id: UUID
    let label: String
    /// 座面の中心（直近の観測の各軸中央値）
    var worldPosition: simd_float3
    var recentObservations: [simd_float3]
    let firstObservedAt: TimeInterval
    /// 空席・人あり、いずれかの観測があった最後の時刻
    var lastEvidenceAt: TimeInterval
    var observationCount: Int
    var isConfirmed = false
    var emptinessScore: Int
    var arrivalAnnounced = false

    var isEmpty: Bool { emptinessScore > 0 }

    init(label: String, position: simd_float3, now: TimeInterval) {
        self.id = UUID()
        self.label = label
        self.worldPosition = position
        self.recentObservations = [position]
        self.firstObservedAt = now
        self.lastEvidenceAt = now
        self.observationCount = 1
        self.emptinessScore = SeatTrackingConfig.emptyEvidence
    }

    /// 空席として観測された
    mutating func addEmptyObservation(_ position: simd_float3, now: TimeInterval) {
        recentObservations.append(position)
        if recentObservations.count > SeatTrackingConfig.positionHistoryCount {
            recentObservations.removeFirst(recentObservations.count - SeatTrackingConfig.positionHistoryCount)
        }
        worldPosition = Self.median(of: recentObservations)
        observationCount += 1
        applyEvidence(SeatTrackingConfig.emptyEvidence, now: now)

        if !isConfirmed,
           observationCount >= SeatTrackingConfig.confirmationMinObservations,
           now - firstObservedAt >= SeatTrackingConfig.confirmationMinDuration,
           horizontalSpread <= SeatTrackingConfig.confirmationMaxSpread {
            isConfirmed = true
        }
    }

    mutating func applyEvidence(_ delta: Int, now: TimeInterval) {
        emptinessScore = min(SeatTrackingConfig.scoreMax, max(SeatTrackingConfig.scoreMin, emptinessScore + delta))
        lastEvidenceAt = now
    }

    /// 直近の観測が中央値からどれだけ散らばっているか（最大の水平距離）
    private var horizontalSpread: Float {
        recentObservations.map {
            simd_length(simd_float2($0.x - worldPosition.x, $0.z - worldPosition.z))
        }.max() ?? 0
    }

    private static func median(of points: [simd_float3]) -> simd_float3 {
        func median(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        return simd_float3(median(points.map { $0.x }),
                           median(points.map { $0.y }),
                           median(points.map { $0.z }))
    }
}

/// 案内先を失った理由
enum TargetLossReason {
    /// 座面に人が重なって見えた（スコアが0以下になった）
    case occupied
    /// 長時間観測されず忘れた
    case lostSight
}

/// 案内先の変化
enum TargetEvent {
    case unchanged
    /// 最初の案内先が決まった
    case selected(Track)
    /// 案内先を失い、別の空席に切り替えた
    case switched(reason: TargetLossReason, to: Track)
    /// 案内先を失い、代わりの空席が無い
    case lost(reason: TargetLossReason)
}

final class SeatTracker {
    private(set) var tracks: [UUID: Track] = [:]
    private(set) var targetID: UUID?
    private var selectionWindowStart: TimeInterval?

    var target: Track? { targetID.flatMap { tracks[$0] } }
    var confirmedTracks: [Track] { tracks.values.filter { $0.isConfirmed } }
    /// 案内できる空席（確定済み・空席判定）が1つでもあるか
    var hasAvailableSeat: Bool { tracks.values.contains { $0.isConfirmed && $0.isEmpty } }

    /// 1回の推論結果を取り込む。座面の位置と person の BBox は、どちらも同じフレームのもの
    /// - Parameters:
    ///   - seatPositions: 空席として検出され、座面の位置が推定できたもの
    ///   - personRects: 同じフレームの person の BBox（画面座標）
    func integrate(seatPositions: [simd_float3],
                   personRects: [CGRect],
                   label: String,
                   frame: ARFrame,
                   interfaceOrientation: UIInterfaceOrientation,
                   viewportSize: CGSize,
                   now: TimeInterval) {
        // 1) 人がいる観測：画面に映っているトラックの座面中心が person の BBox に入っていたら -2
        if !personRects.isEmpty {
            for (id, track) in tracks {
                guard let screenPoint = Self.screenPointIfVisible(track.worldPosition,
                                                                  frame: frame,
                                                                  interfaceOrientation: interfaceOrientation,
                                                                  viewportSize: viewportSize) else { continue }
                if personRects.contains(where: { $0.contains(screenPoint) }) {
                    tracks[id]?.applyEvidence(SeatTrackingConfig.occupiedEvidence, now: now)
                }
            }
        }

        // 2) 空席の観測：最も近い既存トラックに対応付け、無ければ新しく作る
        var matched = Set<UUID>()
        for position in seatPositions {
            let nearest = tracks.values
                .filter { !matched.contains($0.id) }
                .map { (id: $0.id, distance: Self.horizontalDistance($0.worldPosition, position)) }
                .filter { $0.distance <= SeatTrackingConfig.associationRadius }
                .min { $0.distance < $1.distance }

            if let nearest {
                tracks[nearest.id]?.addEmptyObservation(position, now: now)
                matched.insert(nearest.id)
            } else if tracks.count < SeatTrackingConfig.maxTracks {
                let track = Track(label: label, position: position, now: now)
                tracks[track.id] = track
                matched.insert(track.id)
            }
        }
    }

    /// 長く観測されていないトラックを忘れる
    func prune(now: TimeInterval) {
        tracks = tracks.filter { _, track in
            let limit = track.isConfirmed
                ? SeatTrackingConfig.forgetConfirmedAfter
                : SeatTrackingConfig.forgetTentativeAfter
            return now - track.lastEvidenceAt <= limit
        }
    }

    /// 案内先を更新する。今の案内先が有効な間は変えない
    func updateTarget(from cameraPosition: simd_float3, now: TimeInterval) -> TargetEvent {
        guard let id = targetID else {
            return selectReplacement(lossReason: nil, cameraPosition: cameraPosition, now: now)
        }
        if let current = tracks[id], current.isEmpty { return .unchanged }

        // 案内先を失った：忘れた（prune で消えた）か、埋まった（スコアが0以下）か
        let reason: TargetLossReason = tracks[id] == nil ? .lostSight : .occupied
        targetID = nil
        return selectReplacement(lossReason: reason, cameraPosition: cameraPosition, now: now)
    }

    func markArrivalAnnounced(_ id: UUID) {
        tracks[id]?.arrivalAnnounced = true
    }

    private func selectReplacement(lossReason: TargetLossReason?,
                                   cameraPosition: simd_float3,
                                   now: TimeInterval) -> TargetEvent {
        let candidates = tracks.values.filter { $0.isConfirmed && $0.isEmpty }
        let nearest = candidates.min {
            Self.horizontalDistance($0.worldPosition, cameraPosition) < Self.horizontalDistance($1.worldPosition, cameraPosition)
        }

        // 案内中の席を失った直後：候補はすでに集まっているので待たずに乗り換える
        if let lossReason {
            selectionWindowStart = nil
            guard let nearest else { return .lost(reason: lossReason) }
            targetID = nearest.id
            return .switched(reason: lossReason, to: nearest)
        }

        // 最初の案内先：候補が現れてから一定時間集めてから選ぶ
        guard let nearest else {
            selectionWindowStart = nil
            return .unchanged
        }
        guard let windowStart = selectionWindowStart else {
            selectionWindowStart = now
            return .unchanged
        }
        guard now - windowStart >= SeatTrackingConfig.targetSelectionWindow else { return .unchanged }
        selectionWindowStart = nil
        targetID = nearest.id
        return .selected(nearest)
    }

    private static func horizontalDistance(_ a: simd_float3, _ b: simd_float3) -> Float {
        simd_length(simd_float2(a.x - b.x, a.z - b.z))
    }

    /// 点がカメラの前方・有効距離内にあり画面内に映るなら、その画面座標を返す
    private static func screenPointIfVisible(_ point: simd_float3,
                                             frame: ARFrame,
                                             interfaceOrientation: UIInterfaceOrientation,
                                             viewportSize: CGSize) -> CGPoint? {
        let m = frame.camera.transform
        let cameraPosition = simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let forward = -simd_float3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let offset = point - cameraPosition
        guard simd_dot(offset, forward) > 0.1 else { return nil }
        guard horizontalDistance(point, cameraPosition) <= OGMConfig.maxValidRangeMeters else { return nil }
        let screenPoint = frame.camera.projectPoint(point, orientation: interfaceOrientation, viewportSize: viewportSize)
        guard CGRect(origin: .zero, size: viewportSize).contains(screenPoint) else { return nil }
        return screenPoint
    }
}
