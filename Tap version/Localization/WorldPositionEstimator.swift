//
//  WorldPositionEstimator.swift
//  SUWARERU
//
//  画面上の点 → 3Dワールド座標。LiDAR深度を優先し、取れなければ ARKit の raycast にフォールバックする。
//
//  ※既知の問題（段階1・2で作り直す予定。現状の挙動を変えないためにそのまま移設している）
//   - 画面座標→深度画像座標に displayTransform（本来は画像→画面）をそのまま適用している
//   - 逆投影で Y を反転していない（Yc = (v - cy)/fy * d）
//   - LiDAR未使用の端末では深度経路は常に nil になり、raycast だけが使われる
//

import ARKit
import SceneKit
import UIKit
import simd

final class WorldPositionEstimator {
    private weak var sceneView: ARSCNView?

    init(sceneView: ARSCNView) {
        self.sceneView = sceneView
    }

    // MARK: - サンプル点・床除外

    /// 検出から3D位置を取る画面上の点
    static func preferredSamplePoint(for det: Detection) -> CGPoint {
        // chair はBBox中心だと床を拾いやすいため、やや上側を使う
        if det.label == "chair" {
            return CGPoint(x: det.screenRect.midX,
                           y: det.screenRect.minY + det.screenRect.height * 0.35)
        }
        return det.screenPoint
    }

    static func isLikelyFloorPosition(_ worldPos: simd_float3, cameraTransform: simd_float4x4) -> Bool {
        // カメラ位置から大きく下にある点は floor の誤ヒットとして除外
        let camY = cameraTransform.columns.3.y
        return worldPos.y < camY - 1.2
    }

    // MARK: - Depth-first world pos / Raycast fallback

    /// 深度が取れればそれを優先し、ダメなら Raycast で simd_float4x4 と距離を返す
    func worldTransformAndDepthFirst(at pt: CGPoint) -> (simd_float4x4, Float)? {
        if let (pos, dist) = worldPositionFromDepth(at: pt) {
            var t = matrix_identity_float4x4
            t.columns.3 = simd_float4(pos.x, pos.y, pos.z, 1)
            return (t, dist)
        }
        // フォールバック：従来の Raycast
        if let wt = worldTransform(at: pt),
           let frame = sceneView?.session.currentFrame {
            let hit = simd_float3(wt.columns.3.x, wt.columns.3.y, wt.columns.3.z)
            let cam = simd_float3(frame.camera.transform.columns.3.x,
                                  frame.camera.transform.columns.3.y,
                                  frame.camera.transform.columns.3.z)
            let d = simd_length(hit - cam)
            return (wt, d)
        }
        return nil
    }

    /// 画面座標ptに対応する 3Dワールド座標を「深度」から推定（成功時）＋距離[m]
    func worldPositionFromDepth(at pt: CGPoint) -> (simd_float3, Float)? {
        guard let sceneView = sceneView,
              let frame = sceneView.session.currentFrame else { return nil }
        // 深度マップ（smoothed優先）
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthPB = depthData.depthMap // CVPixelBuffer (meter)

        // 画面座標→深度画像座標（displayTransform で整合）
        let size = sceneView.bounds.size
        let norm = CGPoint(x: pt.x / size.width, y: pt.y / size.height)
        let disp = frame.displayTransform(for: currentInterfaceOrientation(), viewportSize: size)
        let normDepth = norm.applying(disp) // 0..1

        let w = CVPixelBufferGetWidth(depthPB)
        let h = CVPixelBufferGetHeight(depthPB)
        var x = Int(round(normDepth.x * CGFloat(w)))
        var y = Int(round((1 - normDepth.y) * CGFloat(h))) // Y反転
        x = max(0, min(w - 1, x))
        y = max(0, min(h - 1, y))

        CVPixelBufferLockBaseAddress(depthPB, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthPB, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthPB) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(depthPB) / MemoryLayout<Float32>.size
        let buf = base.assumingMemoryBound(to: Float32.self)

        // 3×3 近傍の中央値で頑健化
        var samples: [Float] = []
        for ky in -1...1 {
            for kx in -1...1 {
                let sx = max(0, min(w - 1, x + kx))
                let sy = max(0, min(h - 1, y + ky))
                let d = buf[sy * stride + sx]
                if d.isFinite && d > 0 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        let depthM = samples[samples.count / 2] // 中央値[m]

        // 画像座標 → カメラ座標へ逆投影
        // intrinsics は capturedImage 基準なので depthMap 解像度へスケーリングする
        let intr = frame.camera.intrinsics
        let imageW = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageH = Float(CVPixelBufferGetHeight(frame.capturedImage))
        let depthW = Float(w)
        let depthH = Float(h)
        let sx = depthW / imageW
        let sy = depthH / imageH
        let u = Float(x), v = Float(y)
        let fx = intr.columns.0.x * sx
        let fy = intr.columns.1.y * sy
        let cx = intr.columns.2.x * sx
        let cy = intr.columns.2.y * sy
        let Xc = (u - cx) / fx * depthM
        let Yc = (v - cy) / fy * depthM
        let Zc = -depthM
        let camPoint = simd_float4(Xc, Yc, Zc, 1.0)

        // カメラ→ワールド
        let world4 = frame.camera.transform * camPoint
        let world3 = simd_float3(world4.x, world4.y, world4.z)

        // カメラからの距離[m]
        let camPos = simd_float3(frame.camera.transform.columns.3.x,
                                 frame.camera.transform.columns.3.y,
                                 frame.camera.transform.columns.3.z)
        let distance = simd_length(world3 - camPos)
        return (world3, distance)
    }

    /// 画面座標から、平面→推定平面の順でワールド位置を取得
    func worldTransform(at pt: CGPoint) -> simd_float4x4? {
        guard let sceneView = sceneView else { return nil }
        if let q1 = sceneView.raycastQuery(from: pt, allowing: .existingPlaneGeometry, alignment: .any) {
            if let hit = sceneView.session.raycast(q1).first { return hit.worldTransform }
        }
        if let q2 = sceneView.raycastQuery(from: pt, allowing: .estimatedPlane, alignment: .any) {
            if let hit = sceneView.session.raycast(q2).first { return hit.worldTransform }
        }
        return nil
    }

    private func currentInterfaceOrientation() -> UIInterfaceOrientation {
        let sceneOrientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation
        return sceneOrientation ?? .portrait
    }
}
