//
//  GuidanceMath.swift
//  SUWARERU
//
//  案内に使う角度・距離の計算と、読み上げ用の言い回し。
//

import Foundation
import simd

enum GuidanceMath {
    /// world座標Pに対する「水平（Yaw）角度」[deg]。+右 / -左。上下は完全に無視（worldUp基準）。
    static func yawAngleDeg(to P: simd_float3, cameraTransform M: simd_float4x4) -> Float {
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

        // 右方向（水平）の基底：fH × worldUp
        // （以前は worldUp × fH で、これは左向き。directionPhrase の -yaw で打ち消していた）
        let rightH = simd_normalize(simd_cross(fH, worldUp))

        // vH を (fH, rightH) 平面上で極座標化
        let x = simd_dot(vH, rightH)  // 右が +、左が -
        let z = simd_dot(vH, fH)      // 前が +
        let yaw = atan2f(x, z)        // -π..+π

        return yaw * 180.0 / .pi
    }

    /// 角度の方向化
    static func directionPhrase(fromYawDeg yaw: Float?) -> String? {
        guard let yaw = yaw else { return nil }
        // 時計回り（右）が + の角度。yaw は右が + なのでそのまま使う
        var clockDeg = yaw
        if clockDeg < 0 { clockDeg += 360 }
        if clockDeg >= 360 { clockDeg -= 360 }

        // clockDeg を 12分割して「何時」に変換（1つ30度）
        let hour = Int(round(clockDeg / 30.0))
        let hour12 = (hour % 12 == 0) ? 12 : (hour % 12)

        return "\(hour12)時方向"
    }

    /// 距離の読み上げ用丸め
    static func distancePhrase(fromMeters m: Float) -> String {
        if m < 1.0 { return String(format: "残り%.1fメートル", m) }      // 0.8m → 0.8メートル
        if m < 3.0 { return String(format: "残り%.1fメートル", m) }      // 2.3m → 2.3メートル
        return String(format: "残り%.0fメートル", round(m))               // 5.2m → 5メートル
    }
}
