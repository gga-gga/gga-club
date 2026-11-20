//
//  PathSteering.swift
//  SUWARERU
//
//  A* の経路から「次に向かう点（操舵点）」を決める。
//  経路の折れ点そのものを目指すと、すぐ近くの点を通り過ぎるたびに方向が大きく振れるため、
//  現在地から経路に沿って一定距離先の点を目指す（pure pursuit と同じ考え方）。
//

import simd

enum PathSteering {
    /// 経路に沿って何メートル先の点を目指すか（仮値・要実測）
    static let lookaheadMeters: Float = 1.0
    /// 経路がこれより短ければ、経路ではなく空席そのものの方向で案内する
    /// （A*の目的地＝現在地のセル付近で、経路の方向に意味が無いため）
    static let minimumPathLengthMeters: Float = 0.3

    /// 経路（先頭＝現在地のセル）に沿って lookahead 先の点を返す。経路が短すぎれば nil
    static func steeringPoint(along path: [simd_float3],
                              lookahead: Float = lookaheadMeters) -> simd_float3? {
        guard path.count >= 2, pathLength(path) >= minimumPathLengthMeters else { return nil }

        var remaining = lookahead
        for index in 1..<path.count {
            let start = path[index - 1]
            let end = path[index]
            let segmentLength = horizontalDistance(start, end)
            if segmentLength > 0, segmentLength >= remaining {
                return start + (end - start) * (remaining / segmentLength)
            }
            remaining -= segmentLength
        }
        // 経路全体が lookahead より短ければ終点を目指す
        return path.last
    }

    /// 経路の水平方向の長さ[m]
    static func pathLength(_ path: [simd_float3]) -> Float {
        guard path.count >= 2 else { return 0 }
        return (1..<path.count).reduce(0) { $0 + horizontalDistance(path[$1 - 1], path[$1]) }
    }

    private static func horizontalDistance(_ a: simd_float3, _ b: simd_float3) -> Float {
        simd_length(simd_float2(a.x - b.x, a.z - b.z))
    }
}
