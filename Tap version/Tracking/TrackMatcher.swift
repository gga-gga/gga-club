//
//  TrackMatcher.swift
//  SUWARERU
//
//  新しい検出を既存トラックに対応付ける（2D の IoU / 中心距離 + 深さゲート）。
//

import CoreGraphics
import Foundation

struct TrackMatcher {
    // ======= トラッキング/マッチングのパラメータ =======
    let iouThreshold: CGFloat = 0.55       // IOU がこの値以上なら同一物体
    let distanceCoeff: CGFloat = 0.60      // 自適応距離しきい値の係数 (0.6 × 長辺)
    let minDistancePx: CGFloat = 24.0      // 自適応距離の下限 (px)
    let depthThresholdMeters: Float = 2.0  // 深さ一致の許容（0.4〜0.7m 目安）

    init() {}

    /// 優先: (深さゲートを満たす) IOU >= iouThreshold → ダメなら距離も
    /// - Parameter detDepth: 検出の深さ（取れない時は nil）
    func findMatchingTrack(for det: Detection,
                           detectionDepth detDepth: Float?,
                           in tracks: [UUID: Track]) -> (UUID, Track)? {
        // 1) IOU最大（深さが両方あればゲート）
        var bestIOU: (UUID, Track, CGFloat)? = nil
        for (tid, tr) in tracks where tr.label == det.label {
            if let dd = detDepth, abs(dd - tr.depthMeters) > depthThresholdMeters { continue }
            let i = BoundingBoxMath.iou(det.screenRect, tr.lastScreenRect)
            if bestIOU == nil || i > bestIOU!.2 { bestIOU = (tid, tr, i) }
        }
        if let b = bestIOU, b.2 >= iouThreshold { return (b.0, b.1) }

        // 2) 中心距離（自適応しきい値）で補完
        var bestDist: (UUID, Track, CGFloat)? = nil
        for (tid, tr) in tracks where tr.label == det.label {
            if let dd = detDepth, abs(dd - tr.depthMeters) > depthThresholdMeters { continue }
            let d = hypot(tr.lastScreenPoint.x - det.screenPoint.x,
                          tr.lastScreenPoint.y - det.screenPoint.y)
            let longEdge = max(det.screenRect.width, det.screenRect.height)
            let thresh = max(minDistancePx, distanceCoeff * longEdge)
            if d <= thresh {
                if bestDist == nil || d < bestDist!.2 { bestDist = (tid, tr, d) }
            }
        }
        if let b = bestDist { return (b.0, b.1) }

        // フォールバック（深さなし時、2Dのみ・やや厳しめ）
        if detDepth == nil {
            var fb: (UUID, Track, CGFloat)? = nil
            for (tid, tr) in tracks where tr.label == det.label {
                let i = BoundingBoxMath.iou(det.screenRect, tr.lastScreenRect)
                if fb == nil || i > fb!.2 { fb = (tid, tr, i) }
            }
            if let f = fb, f.2 >= iouThreshold * 1.2 { return (f.0, f.1) }
        }
        return nil
    }

    /// 同ラベルの既存トラックで画面距離が最小のもの
    func findNearestTrackOfSameLabel(det: Detection, in tracks: [UUID: Track]) -> (UUID, Track)? {
        var best: (UUID, Track, CGFloat)? = nil
        for (tid, tr) in tracks where tr.label == det.label {
            let d = hypot(tr.lastScreenPoint.x - det.screenPoint.x,
                          tr.lastScreenPoint.y - det.screenPoint.y)
            if best == nil || d < best!.2 { best = (tid, tr, d) }
        }
        if let b = best { return (b.0, b.1) }
        return nil
    }
}
