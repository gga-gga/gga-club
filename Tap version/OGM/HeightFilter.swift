//
//  HeightFilter.swift
//  占有格子地図（OGM）— 高さフィルタリング（[4] / 3章）
//

import simd

enum HeightClassification {
    case floor            // 除外。レイ通過セルのFree化には使う
    case occupiedCandidate
    case overhead          // 除外（頭上構造物）
}

struct ClassifiedPoint {
    let worldPosition: simd_float3
    let classification: HeightClassification
}

/// 2閾値による二値フィルタ（3.3：シート端/脚部/上半身の3分類は不採用）
struct HeightFilter {
    let floorY: Float

    func classify(_ points: [simd_float3]) -> [ClassifiedPoint] {
        points.map { p in
            let relativeHeight = p.y - floorY
            let classification: HeightClassification
            if relativeHeight < OGMConfig.floorMarginMeters {
                classification = .floor
            } else if relativeHeight >= OGMConfig.overheadHeightMeters {
                classification = .overhead
            } else {
                classification = .occupiedCandidate
            }
            return ClassifiedPoint(worldPosition: p, classification: classification)
        }
    }
}
