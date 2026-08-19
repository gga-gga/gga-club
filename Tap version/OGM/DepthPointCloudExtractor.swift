//
//  DepthPointCloudExtractor.swift
//  占有格子地図（OGM）— 深度取得〜ワールド座標変換（[1]〜[3]）
//

import ARKit
import simd

final class DepthPointCloudExtractor {
    /// 画素間引き幅（全画素を使うと重いため）
    let pixelStride: Int

    init(pixelStride: Int = 4) {
        self.pixelStride = pixelStride
    }

    /// 深度マップ + 信頼度マップからワールド座標点群を抽出する。
    /// confidenceMap が `.high` 未満の画素は破棄する（[1]）。
    /// 実機テストで、円状に誤って占有判定されるセルが確認された。カメラ近傍・浅い入射角の
    /// 床面はLiDARのノイズが乗りやすく、`.medium`まで許可すると誤検出が入りやすいため、
    /// `.high`のみ採用するよう厳しくした。
    func extractWorldPoints(from frame: ARFrame) -> [simd_float3] {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return [] }
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let depthBuf = depthBase.assumingMemoryBound(to: Float32.self)

        var confidenceBuf: UnsafeMutablePointer<UInt8>?
        var confidenceRowStride = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceRowStride = CVPixelBufferGetBytesPerRow(confidenceMap)
            confidenceBuf = CVPixelBufferGetBaseAddress(confidenceMap)?.assumingMemoryBound(to: UInt8.self)
        }
        defer {
            if confidenceMap != nil { CVPixelBufferUnlockBaseAddress(confidenceMap!, .readOnly) }
        }

        // カメラ内部パラメータは capturedImage(RGB) 基準のため、深度マップ解像度へスケーリングする
        let intr = frame.camera.intrinsics
        let imageW = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageH = Float(CVPixelBufferGetHeight(frame.capturedImage))
        guard imageW > 0, imageH > 0 else { return [] }
        let sx = Float(width) / imageW
        let sy = Float(height) / imageH
        let fx = intr.columns.0.x * sx
        let fy = intr.columns.1.y * sy
        let cx = intr.columns.2.x * sx
        let cy = intr.columns.2.y * sy

        let cameraToWorld = frame.camera.transform

        var points: [simd_float3] = []
        points.reserveCapacity((width / pixelStride) * (height / pixelStride))

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                if let confidenceBuf {
                    let confidence = confidenceBuf[y * confidenceRowStride + x]
                    if confidence < UInt8(ARConfidenceLevel.high.rawValue) {
                        x += pixelStride
                        continue
                    }
                }

                let depth = depthBuf[y * depthRowStride + x]
                if depth.isFinite,
                   depth >= OGMConfig.minValidRangeMeters,
                   depth <= OGMConfig.maxValidRangeMeters {
                    let u = Float(x), v = Float(y)
                    // ピンホールカメラモデルで逆投影（[2]）
                    let xc = (u - cx) / fx * depth
                    let yc = (v - cy) / fy * depth
                    let zc = -depth // ARKitのカメラ座標系は -Z が前方
                    let camPoint = simd_float4(xc, yc, zc, 1.0)

                    // camera-to-world 行列を適用（[3]）
                    let worldPoint = cameraToWorld * camPoint
                    points.append(simd_float3(worldPoint.x, worldPoint.y, worldPoint.z))
                }
                x += pixelStride
            }
            y += pixelStride
        }
        return points
    }
}
