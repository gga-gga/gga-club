//
//  ViewController+OGM.swift
//  SUWARERU
//
//  占有格子地図（OGM）の更新と、案内先までの A* 経路計画。
//  OGM の更新・経路計画はどちらも描画スレッド（renderer）からだけ呼ぶこと（ogmEngine はスレッドセーフではない）。
//

import ARKit
import simd

/// 案内先までの経路計画の結果
struct PathPlan {
    enum Status {
        /// 案内先が無い（まだ決まっていない）
        case noTarget
        case success
        /// 床がまだ推定されていない
        case noFloorEstimate
        /// 現在地から到達できる観測済みのセルが無い
        case noReachableArea
        /// 目的地は決まったが経路が見つからない（本来は起きない）
        case noPath
    }

    var status: Status = .noTarget
    /// A* の経路（床の高さ。先頭＝現在地のセル）
    var path: [simd_float3] = []
    /// 次に向かう点。経路が短すぎる・計画に失敗した場合は nil（空席そのものの方向で案内する）
    var steeringPoint: simd_float3?

    var pathLength: Float { PathSteering.pathLength(path) }

    var statusText: String {
        switch status {
        case .noTarget: return "案内先なし"
        case .success: return String(format: "経路 %.1fm", pathLength)
        case .noFloorEstimate: return "床未推定"
        case .noReachableArea: return "到達できる範囲なし"
        case .noPath: return "経路なし"
        }
    }
}

extension ViewController {
    /// 深度取得〜グリッド書き込み・持続性カウンタ（仕様書[1]〜[6]）を約10fpsで実行する
    func updateOGMIfNeeded(time: TimeInterval) {
        guard time - lastOGMUpdateTime >= OGMConfig.depthCaptureInterval else { return }
        lastOGMUpdateTime = time
        guard let frame = sceneView.session.currentFrame else { return }
        ogmEngine.update(frame: frame, timestamp: time)

        let floorY = ogmEngine.floorY
        stateQueue.sync {
            self.latestFloorY = floorY
        }
    }

    /// 案内先（座面の中心）に向かう経路を計画する。座面自体は通れないので、
    /// FrontierGoalSelector が「到達できるセルのうち座面に最も近いセル」＝座席の手前を目的地に選ぶ
    func planPath(toward target: Track?, cameraTransform: simd_float4x4) -> PathPlan {
        let m = cameraTransform
        let cameraPosition = simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        // 歩いてきた場所は（未観測でも）歩けたはずなので覚えておく。案内先が無くても毎回記録する
        walkedCells.insert(ogmEngine.grid.coordinate(forWorld: cameraPosition))

        guard let target else { return PathPlan() }

        let assumedFree = walkedCells.union(blindZoneCells(cameraTransform: cameraTransform))
        switch ogmEngine.planPath(from: cameraPosition,
                                  toward: target.worldPosition,
                                  assumedFreeIfUnobserved: assumedFree) {
        case .success(let path, _):
            return PathPlan(status: .success,
                            path: path,
                            steeringPoint: PathSteering.steeringPoint(along: path))
        case .noFloorEstimate:
            return PathPlan(status: .noFloorEstimate)
        case .noReachableArea:
            return PathPlan(status: .noReachableArea)
        case .noPath:
            return PathPlan(status: .noPath)
        }
    }

    /// カメラの死角になっている足元〜前方の床のセル。
    /// スマホを胸の高さで前に向けると、足元から約1.5〜2m先までの床は映らない。
    /// ここに置かれた低い物はもともとカメラで検出できないため、通れるとみなしても
    /// 空席の方向へ直接案内していた従来より危険になることはない。観測済みのセルは観測に従う。
    func blindZoneCells(cameraTransform: simd_float4x4) -> Set<GridCoordinate> {
        let grid = ogmEngine.grid
        let cellSize = grid.cellSize
        let m = cameraTransform
        let origin = simd_float2(m.columns.3.x, m.columns.3.z)
        let back = simd_float2(m.columns.2.x, m.columns.2.z)
        guard simd_length(back) > 1e-4 else { return [] }
        let forward = -simd_normalize(back)
        let minCos = cos(BlindZoneConfig.halfAngleDegrees * .pi / 180)

        var cells: Set<GridCoordinate> = []
        let reach = Int((BlindZoneConfig.radiusMeters / cellSize).rounded(.up))
        let center = grid.coordinate(forWorld: simd_float3(origin.x, 0, origin.y))
        for dz in -reach...reach {
            for dx in -reach...reach {
                let coord = GridCoordinate(x: center.x + dx, z: center.z + dz)
                let cellCenter = simd_float2((Float(coord.x) + 0.5) * cellSize, (Float(coord.z) + 0.5) * cellSize)
                let offset = cellCenter - origin
                let distance = simd_length(offset)
                if distance <= BlindZoneConfig.footprintRadiusMeters {
                    cells.insert(coord)
                } else if distance <= BlindZoneConfig.radiusMeters,
                          simd_dot(offset / distance, forward) >= minCos {
                    cells.insert(coord)
                }
            }
        }
        return cells
    }
}

/// 足元の死角の範囲（仮値・要実測）
enum BlindZoneConfig {
    /// 前方この距離までを死角とみなす。実測で約1.5m先まで床が映らなかったため、少し余裕を持たせている
    static let radiusMeters: Float = 2.0
    /// 前方の扇形の半角[deg]（カメラの横方向の画角に合わせた目安）
    static let halfAngleDegrees: Float = 30
    /// 向きに関係なく、自分の周りのこの半径は立っている場所として含める
    static let footprintRadiusMeters: Float = 0.3
}
