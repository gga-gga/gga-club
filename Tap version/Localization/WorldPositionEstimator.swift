//
//  WorldPositionEstimator.swift
//  SUWARERU
//
//  検出（BBox）→ 3Dワールド座標。推論に使ったのと同じ ARFrame の LiDAR 深度だけを使う。
//  深度が取れない場合は「位置なし」とし、raycast へのフォールバックはしない
//  （LiDAR端末限定・正確さ優先の方針。経路が2つあると位置の食い違いに気づけないため）。
//
//  ※段階2で「BBox内の座面の点群から推定する」方式に置き換える予定。
//    段階1では1点（BBox上側35%）の3×3中央値のまま、座標変換だけを正しくしている。
//

import ARKit
import UIKit
import simd

/// 検出1件について求めた3D位置
struct SeatPlacement {
    let worldPosition: simd_float3
    /// 推定に使ったフレームのカメラ位置
    let cameraPosition: simd_float3
    /// 深度を読んだ点（サンプル点）の画面座標
    let expectedScreenPoint: CGPoint
    /// 求めた3D位置を、同じフレームのカメラで画面に投影し直した点
    let reprojectedScreenPoint: CGPoint

    /// カメラからの水平距離[m]（高さの差は無視）
    var horizontalDistance: Float {
        simd_length(simd_float2(worldPosition.x - cameraPosition.x,
                                worldPosition.z - cameraPosition.z))
    }

    /// 再投影誤差[pt]。座標変換と逆投影が正しければ、画面のどこでも数pt以内になる
    var reprojectionError: CGFloat {
        hypot(reprojectedScreenPoint.x - expectedScreenPoint.x,
              reprojectedScreenPoint.y - expectedScreenPoint.y)
    }
}

enum WorldPositionEstimator {
    /// 深度を読む点（Vision座標）
    static func preferredVisionSamplePoint(for det: Detection) -> CGPoint {
        let r = det.normalizedRect
        // chair はBBox中心だと床を拾いやすいため、やや上側を使う（Vision は左下原点なので maxY が上端）
        if det.label == "chair" {
            return CGPoint(x: r.midX, y: r.maxY - r.height * 0.35)
        }
        return CGPoint(x: r.midX, y: r.midY)
    }

    static func isLikelyFloorPosition(_ worldPos: simd_float3, cameraPosition: simd_float3) -> Bool {
        // カメラ位置から大きく下にある点は floor の誤ヒットとして除外
        return worldPos.y < cameraPosition.y - 1.2
    }

    /// 検出の3D位置を、推論に使ったフレームの深度から求める
    static func estimatePlacement(for det: Detection,
                                  frame: ARFrame,
                                  interfaceOrientation: UIInterfaceOrientation,
                                  viewportSize: CGSize) -> SeatPlacement? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }

        let visionPoint = preferredVisionSamplePoint(for: det)
        let native = ImageCoordinates.nativePoint(fromVision: visionPoint, orientation: det.imageOrientation)
        guard (0...1).contains(native.x), (0...1).contains(native.y) else { return nil }

        guard let depthM = medianDepth(at: native, depthData: depthData) else { return nil }

        // native正規化座標 → capturedImage の画素座標（画素中心が整数になる流儀に合わせて0.5引く）
        let intr = frame.camera.intrinsics
        let imageW = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageH = Float(CVPixelBufferGetHeight(frame.capturedImage))
        guard imageW > 0, imageH > 0 else { return nil }
        let u = Float(native.x) * imageW - 0.5
        let v = Float(native.y) * imageH - 0.5
        let fx = intr.columns.0.x
        let fy = intr.columns.1.y
        let cx = intr.columns.2.x
        let cy = intr.columns.2.y

        // 画像座標(vは下向きに増える) → ARKitカメラ座標(Yは上向き・前方は-Z)なので Y と Z を反転する。
        // AStarDebugger の DepthPointCloudExtractor と同じ式（実機で左右反転が直ることを確認済み）。
        let cameraPoint = simd_float4((u - cx) / fx * depthM,
                                      -(v - cy) / fy * depthM,
                                      -depthM,
                                      1)
        let world4 = frame.camera.transform * cameraPoint
        let worldPosition = simd_float3(world4.x, world4.y, world4.z)

        let m = frame.camera.transform
        let cameraPosition = simd_float3(m.columns.3.x, m.columns.3.y, m.columns.3.z)

        // 検証用：狙った点と、求めた3D位置を投影し直した点（どちらも同じフレーム基準）
        let displayTransform = frame.displayTransform(for: interfaceOrientation, viewportSize: viewportSize)
        let expected = ImageCoordinates.screenPoint(fromNative: native,
                                                    displayTransform: displayTransform,
                                                    viewportSize: viewportSize)
        let reprojected = frame.camera.projectPoint(worldPosition,
                                                    orientation: interfaceOrientation,
                                                    viewportSize: viewportSize)

        return SeatPlacement(worldPosition: worldPosition,
                             cameraPosition: cameraPosition,
                             expectedScreenPoint: expected,
                             reprojectedScreenPoint: reprojected)
    }

    /// native座標の点を中心とした 3×3 画素の深度の中央値[m]。信頼度 low の画素は使わない
    private static func medianDepth(at native: CGPoint, depthData: ARDepthData) -> Float? {
        let depthMap = depthData.depthMap
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let centerX = max(0, min(w - 1, Int(native.x * CGFloat(w))))
        let centerY = max(0, min(h - 1, Int(native.y * CGFloat(h))))

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let depthBuf = depthBase.assumingMemoryBound(to: Float32.self)

        let confidenceMap = depthData.confidenceMap
        var confidenceBuf: UnsafeMutablePointer<UInt8>?
        var confidenceRowStride = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceRowStride = CVPixelBufferGetBytesPerRow(confidenceMap)
            confidenceBuf = CVPixelBufferGetBaseAddress(confidenceMap)?.assumingMemoryBound(to: UInt8.self)
        }
        defer {
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        var samples: [Float] = []
        for ky in -1...1 {
            for kx in -1...1 {
                let sx = centerX + kx
                let sy = centerY + ky
                guard sx >= 0, sx < w, sy >= 0, sy < h else { continue }
                if let confidenceBuf,
                   confidenceBuf[sy * confidenceRowStride + sx] < UInt8(ARConfidenceLevel.medium.rawValue) {
                    continue
                }
                let d = depthBuf[sy * depthRowStride + sx]
                if d.isFinite && d > 0 { samples.append(d) }
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}
