//
//  WorldPositionEstimator.swift
//  SUWARERU
//
//  空席の検出（BBox）→ 座面の3D位置。推論に使ったのと同じ ARFrame の LiDAR 深度だけを使う。
//
//  BBox の中には奥の壁・脚の間の床・隣の椅子・隣の人なども写り込むため、1点や単純な平均ではなく
//  「座面らしい点」だけを集めて中央値を取る：
//    1. BBox の横方向の中央だけを使い、同じフレームの person BBox と重なる画素は除外する
//    2. 床から座面の高さの範囲にあり、法線が上向き（水平面）の点だけを残す
//       → 壁・背もたれ（垂直）、床（低い）、立っている人の脚（垂直）が落ちる
//    3. 品質ゲート：点が少なすぎる・広がりすぎ（他の物が混ざった）なら推定しない
//  推定できないときは「位置なし」とする（正確さ優先。誤った位置へ案内するよりは案内しない）。
//
//  遠い椅子（約2.5m以上）への対応：
//    遠いほど座面は浅い角度で見えて画素数が減り（距離の3乗にほぼ反比例）、LiDAR の信頼度も
//    「高」になりにくい。近距離と同じ基準のままだと、空いているのに座面を確認できなかった。
//    そこで (a) 必要な点の数を距離に応じて減らし、(b) 信頼度「高」の点だけで足りないときは
//    「中」の点も使う。高さ・法線・広がりの条件は変えない（座面らしさの判定は緩めない）。
//    足りなかったときは、どの条件で画素が落ちたかをデバッグ表示に出す。
//

import ARKit
import UIKit
import simd

enum SeatLocalizationConfig {
    /// BBox の横方向（画面の左右）のうち、中央のこの割合だけを使う（隣の椅子・人が入りにくくする）
    static let centralWidthFraction: CGFloat = 0.6
    /// 座面とみなす床からの高さ[m]。一般的なデスク椅子の座面 0.42〜0.52m ＋クッションを想定（仮値・要実測）
    static let seatHeightMin: Float = 0.30
    static let seatHeightMax: Float = 0.60
    /// 品質ゲート：座面の点がこれ未満なら推定しない（仮値・要実測）。
    /// nearDistanceMeters より近い椅子に使う値
    static let minSurfacePoints = 20
    /// この距離[m]までは minSurfacePoints をそのまま要求する
    static let nearDistanceMeters: Float = 2.0
    /// 遠い椅子でも最低限これだけの点は要求する（仮値・要実測）
    static let minSurfacePointsFar = 8
    /// 信頼度「高」の点だけで足りないとき、「中」の点も使うか。
    /// false にすると以前と同じ（「高」だけ）になる
    static let allowsMediumConfidenceFallback = true

    /// 椅子までの水平距離に応じた、必要な座面の点の数。
    /// 座面が占める画素数は距離の3乗にほぼ反比例するので、同じ割合で減らす
    /// （例：2.0mまで20点、2.5mで約11点、3.0m以上は8点）
    static func requiredSurfacePoints(atDistance distance: Float?) -> Int {
        guard let distance, distance > nearDistanceMeters else { return minSurfacePoints }
        let ratio = nearDistanceMeters / distance
        let scaled = Int((Float(minSurfacePoints) * ratio * ratio * ratio).rounded(.up))
        return min(minSurfacePoints, max(minSurfacePointsFar, scaled))
    }
    /// 品質ゲート：座面の点の広がり（10〜90パーセンタイル範囲）がこれを超えたら、
    /// 隣の椅子などが混ざったとみなして推定しない。座面そのものの幅（約0.5m）より少し大きくしてある
    static let maxSurfaceExtentMeters: Float = 0.7
    /// 走査する画素数がこれを超えたら間引く（近距離で BBox が大きいときの負荷対策）
    static let maxScannedPixels = 4000
    /// デバッグ表示する座面点の最大数
    static let maxDebugPoints = 60
}

/// 検出1件について求めた座面の3D位置
struct SeatPlacement {
    /// 座面の中心（座面の点の中央値）
    let worldPosition: simd_float3
    /// 推定に使ったフレームのカメラ位置
    let cameraPosition: simd_float3
    /// 推定に使った座面の点の数
    let surfacePointCount: Int
    /// 信頼度「中」の点も使ったか（「高」だけでは足りなかった）
    let usedMediumConfidence: Bool
    /// 座面の点の広がり[m]（カメラから見て左右方向・奥行き方向）
    let lateralExtent: Float
    let depthExtent: Float
    /// デバッグ表示用：座面中心と座面の点（間引き済み）の画面座標
    let centerScreenPoint: CGPoint
    let surfaceScreenPoints: [CGPoint]

    /// カメラからの水平距離[m]（高さの差は無視）
    var horizontalDistance: Float {
        simd_length(simd_float2(worldPosition.x - cameraPosition.x,
                                worldPosition.z - cameraPosition.z))
    }
}

/// 座面の点が足りなかったとき、BBox 内の画素がどの条件で落ちたかの内訳（デバッグ表示用）
struct SeatSurfaceRejects {
    /// 高さが座面の範囲外（床・背もたれ・奥の壁など）
    var wrongHeight = 0
    /// 高さは合うが、面が水平でない（背もたれの下の方、斜めに見えた面など）
    var wrongNormal = 0
    /// 高さも向きも座面らしいが、LiDAR の信頼度が「低」
    var lowConfidence = 0
    /// 高さも向きも座面らしく、信頼度が「中」（中の点を使わない設定のときだけ数える）
    var mediumConfidence = 0

    var debugText: String {
        var parts = ["高さ✕\(wrongHeight)", "向き✕\(wrongNormal)", "信頼度低✕\(lowConfidence)"]
        if mediumConfidence > 0 { parts.append("信頼度中✕\(mediumConfidence)") }
        return parts.joined(separator: " ")
    }
}

/// 座面の推定に失敗した理由（デバッグ表示用）
enum SeatLocalizationFailure {
    /// 床の高さがまだ推定されていない（OGM が床を見ていない）
    case noFloorEstimate
    /// 深度が取れない（深度マップが無い・BBox が画像外）
    case noDepth
    /// 座面らしい点が少なすぎる（count: 集まった点、needed: 必要な点、rejects: 落ちた画素の内訳）
    case tooFewPoints(count: Int, needed: Int, rejects: SeatSurfaceRejects)
    /// 座面らしい点が広がりすぎている（他の物が混ざった）
    case tooSpread(lateral: Float, depth: Float)
    /// ARKit の位置推定が不安定（正常でない）なので推定しない
    case trackingLimited

    var debugText: String {
        switch self {
        case .noFloorEstimate: return "床未推定"
        case .trackingLimited: return "位置推定が不安定"
        case .noDepth: return "深度なし"
        case .tooFewPoints(let count, let needed, let rejects):
            return "点不足(\(count)/\(needed)) \(rejects.debugText)"
        case .tooSpread(let lateral, let depth):
            return String(format: "広がり過大(幅%.2f 奥%.2f)", lateral, depth)
        }
    }
}

enum SeatLocalization {
    case located(SeatPlacement)
    case failed(SeatLocalizationFailure)
}

enum WorldPositionEstimator {
    /// 空席の検出から座面の3D位置を推定する
    /// - Parameters:
    ///   - persons: 同じフレームで検出された person（重なる画素を除外する）
    ///   - floorY: OGM が推定した床の高さ（未推定なら nil）
    static func estimatePlacement(for det: Detection,
                                  persons: [Detection],
                                  floorY: Float?,
                                  frame: ARFrame,
                                  interfaceOrientation: UIInterfaceOrientation,
                                  viewportSize: CGSize) -> SeatLocalization {
        guard let floorY else { return .failed(.noFloorEstimate) }
        // OGM（DepthPointCloudExtractor）と同じく、深度エッジの浮遊画素が少ない生の深度を優先する
        guard let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth else { return .failed(.noDepth) }

        // 1) 使う領域：BBox の横方向中央（Vision座標）→ native座標。person の BBox も native座標にしておく
        let r = det.normalizedRect
        let centralWidth = r.width * SeatLocalizationConfig.centralWidthFraction
        let central = CGRect(x: r.midX - centralWidth / 2, y: r.minY, width: centralWidth, height: r.height)
        let region = ImageCoordinates.nativeRect(fromVision: central, orientation: det.imageOrientation)
        let personRegions = persons.map {
            ImageCoordinates.nativeRect(fromVision: $0.normalizedRect, orientation: $0.imageOrientation)
        }

        let depthMap = depthData.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let x0 = max(0, Int((region.minX * CGFloat(width)).rounded(.down)))
        let x1 = min(width - 1, Int((region.maxX * CGFloat(width)).rounded(.up)))
        let y0 = max(0, Int((region.minY * CGFloat(height)).rounded(.down)))
        let y1 = min(height - 1, Int((region.maxY * CGFloat(height)).rounded(.up)))
        guard x0 <= x1, y0 <= y1 else { return .failed(.noDepth) }

        let area = (x1 - x0 + 1) * (y1 - y0 + 1)
        let pixelStride = max(1, Int((Float(area) / Float(SeatLocalizationConfig.maxScannedPixels)).squareRoot().rounded(.up)))

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return .failed(.noDepth) }
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

        // カメラ内部パラメータは capturedImage 基準のため、深度マップ解像度へスケーリングする
        let intr = frame.camera.intrinsics
        let imageW = Float(CVPixelBufferGetWidth(frame.capturedImage))
        let imageH = Float(CVPixelBufferGetHeight(frame.capturedImage))
        guard imageW > 0, imageH > 0 else { return .failed(.noDepth) }
        let sx = Float(width) / imageW
        let sy = Float(height) / imageH
        let fx = intr.columns.0.x * sx
        let fy = intr.columns.1.y * sy
        let cx = intr.columns.2.x * sx
        let cy = intr.columns.2.y * sy

        let cameraToWorld = frame.camera.transform
        let rotation = simd_float3x3(
            simd_float3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
            simd_float3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
            simd_float3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        )

        // DepthPointCloudExtractor と同じ逆投影（Y と Z を反転）
        func cameraSpacePoint(_ px: Int, _ py: Int) -> simd_float3? {
            guard px >= 0, px < width, py >= 0, py < height else { return nil }
            let d = depthBuf[py * depthRowStride + px]
            guard d.isFinite, d > 0 else { return nil }
            let u = Float(px), v = Float(py)
            return simd_float3((u - cx) / fx * d, -(v - cy) / fy * d, -d)
        }

        let normalSampleOffset = 2
        let discontinuity = OGMConfig.maxDepthDiscontinuityMeters

        // 2) 座面らしい点だけを集める。信頼度「高」と「中」は分けて集めておく
        let highConfidence = UInt8(ARConfidenceLevel.high.rawValue)
        let mediumConfidence = UInt8(ARConfidenceLevel.medium.rawValue)
        var highPoints: [simd_float3] = []
        var mediumPoints: [simd_float3] = []
        var rejects = SeatSurfaceRejects()
        var py = y0
        while py <= y1 {
            var px = x0
            while px <= x1 {
                defer { px += pixelStride }

                // person の BBox と重なる画素は除外（隣に座った人の膝・荷物、前に立つ人など）
                let nativePoint = CGPoint(x: (CGFloat(px) + 0.5) / CGFloat(width),
                                          y: (CGFloat(py) + 0.5) / CGFloat(height))
                if personRegions.contains(where: { $0.contains(nativePoint) }) { continue }

                // 信頼度はここでは落とさず、形（高さ・向き）を見たあとで振り分ける
                // （形は座面なのに信頼度だけで落ちた画素を数えるため）
                let confidence = confidenceBuf.map { $0[py * confidenceRowStride + px] } ?? highConfidence

                let depth = depthBuf[py * depthRowStride + px]
                guard depth.isFinite,
                      depth >= OGMConfig.minValidRangeMeters,
                      depth <= OGMConfig.maxValidRangeMeters else { continue }

                // 深度エッジの浮遊画素（手前と奥の中間の実在しない点）を除外
                if px + 1 < width {
                    let neighborDepth = depthBuf[py * depthRowStride + (px + 1)]
                    if neighborDepth.isFinite, abs(neighborDepth - depth) > discontinuity { continue }
                }

                guard let center = cameraSpacePoint(px, py),
                      let right = cameraSpacePoint(px + normalSampleOffset, py),
                      let down = cameraSpacePoint(px, py + normalSampleOffset) else { continue }
                if abs(abs(right.z) - abs(center.z)) > discontinuity { continue }
                if abs(abs(down.z) - abs(center.z)) > discontinuity { continue }

                let world4 = cameraToWorld * simd_float4(center.x, center.y, center.z, 1)
                let world = simd_float3(world4.x, world4.y, world4.z)

                // 高さ：座面の範囲か
                let heightAboveFloor = world.y - floorY
                guard heightAboveFloor >= SeatLocalizationConfig.seatHeightMin,
                      heightAboveFloor <= SeatLocalizationConfig.seatHeightMax else {
                    rejects.wrongHeight += 1
                    continue
                }

                // 法線：上向き（水平面）か
                let normalCamera = simd_cross(right - center, down - center)
                let normalLength = simd_length(normalCamera)
                guard normalLength > 1e-6 else { continue }
                let worldNormal = rotation * (normalCamera / normalLength)
                guard abs(worldNormal.y) >= OGMConfig.walkableNormalAlignmentThreshold else {
                    rejects.wrongNormal += 1
                    continue
                }

                // 形は座面らしい。信頼度で振り分ける
                if confidence >= highConfidence {
                    highPoints.append(world)
                } else if confidence >= mediumConfidence {
                    if SeatLocalizationConfig.allowsMediumConfidenceFallback {
                        mediumPoints.append(world)
                    } else {
                        rejects.mediumConfidence += 1
                    }
                } else {
                    rejects.lowConfidence += 1
                }
            }
            py += pixelStride
        }

        // 3) 品質ゲート
        let cameraPosition = simd_float3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)

        // 必要な点の数は、椅子までの距離で決める（遠いほど座面の画素が減るため）
        let candidatePoints = highPoints + mediumPoints
        let candidateDistance: Float? = candidatePoints.isEmpty ? nil : median(candidatePoints.map {
            simd_length(simd_float2($0.x - cameraPosition.x, $0.z - cameraPosition.z))
        })
        let neededPoints = SeatLocalizationConfig.requiredSurfacePoints(atDistance: candidateDistance)

        // 信頼度「高」だけで足りればそれを使い、足りなければ「中」も合わせて使う
        let surfacePoints: [simd_float3]
        let usedMediumConfidence: Bool
        if highPoints.count >= neededPoints {
            surfacePoints = highPoints
            usedMediumConfidence = false
        } else if candidatePoints.count >= neededPoints {
            surfacePoints = candidatePoints
            usedMediumConfidence = true
        } else {
            return .failed(.tooFewPoints(count: candidatePoints.count, needed: neededPoints, rejects: rejects))
        }

        let back = simd_float3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z)
        let forwardFlat = simd_float3(-back.x, 0, -back.z)
        guard simd_length(forwardFlat) > 1e-4 else { return .failed(.noDepth) }
        let forwardH = simd_normalize(forwardFlat)
        let rightH = simd_normalize(simd_cross(forwardH, simd_float3(0, 1, 0)))

        let lateralExtent = percentileRange(surfacePoints.map { simd_dot($0 - cameraPosition, rightH) })
        let depthExtent = percentileRange(surfacePoints.map { simd_dot($0 - cameraPosition, forwardH) })
        guard lateralExtent <= SeatLocalizationConfig.maxSurfaceExtentMeters,
              depthExtent <= SeatLocalizationConfig.maxSurfaceExtentMeters else {
            return .failed(.tooSpread(lateral: lateralExtent, depth: depthExtent))
        }

        let seatCenter = simd_float3(median(surfacePoints.map { $0.x }),
                                     median(surfacePoints.map { $0.y }),
                                     median(surfacePoints.map { $0.z }))

        // デバッグ表示用の画面座標
        let debugStep = max(1, surfacePoints.count / SeatLocalizationConfig.maxDebugPoints)
        let surfaceScreenPoints = Swift.stride(from: 0, to: surfacePoints.count, by: debugStep).map {
            frame.camera.projectPoint(surfacePoints[$0], orientation: interfaceOrientation, viewportSize: viewportSize)
        }
        let centerScreenPoint = frame.camera.projectPoint(seatCenter,
                                                          orientation: interfaceOrientation,
                                                          viewportSize: viewportSize)

        return .located(SeatPlacement(worldPosition: seatCenter,
                                      cameraPosition: cameraPosition,
                                      surfacePointCount: surfacePoints.count,
                                      usedMediumConfidence: usedMediumConfidence,
                                      lateralExtent: lateralExtent,
                                      depthExtent: depthExtent,
                                      centerScreenPoint: centerScreenPoint,
                                      surfaceScreenPoints: surfaceScreenPoints))
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// 10〜90パーセンタイルの範囲（外れ値に引っ張られない広がりの指標）
    private static func percentileRange(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let low = sorted[Int(Float(sorted.count - 1) * 0.1)]
        let high = sorted[Int(Float(sorted.count - 1) * 0.9)]
        return high - low
    }
}
