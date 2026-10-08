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
    func planPath(toward target: Track?, from cameraPosition: simd_float3) -> PathPlan {
        guard let target else { return PathPlan() }

        switch ogmEngine.planPath(from: cameraPosition, toward: target.worldPosition) {
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
}
