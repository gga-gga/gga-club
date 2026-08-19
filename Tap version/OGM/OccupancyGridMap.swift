//
//  OccupancyGridMap.swift
//  占有格子地図（OGM）— グリッド更新（[5]）+ 持続性カウンタ（[6] / 5.1）
//

import Foundation
import simd

final class OccupancyGridMap {
    private(set) var cells: [GridCoordinate: CellState] = [:]
    let cellSize: Float

    init(cellSize: Float = OGMConfig.cellSize) {
        self.cellSize = cellSize
    }

    func coordinate(forWorld position: simd_float3) -> GridCoordinate {
        GridCoordinate(x: Int(floor(position.x / cellSize)), z: Int(floor(position.z / cellSize)))
    }

    func worldCenter(of coord: GridCoordinate) -> simd_float3 {
        simd_float3((Float(coord.x) + 0.5) * cellSize, 0, (Float(coord.z) + 0.5) * cellSize)
    }

    func state(at coord: GridCoordinate) -> CellState? {
        cells[coord]
    }

    /// 視野内で観測された点群をグリッドへ反映する。視野外のセルは直近の値を保持し続ける（4.2）。
    /// 各点についてBresenhamでセンサー位置から観測点までのレイを通し、
    /// 中間セルをFree化、終点セル（占有候補）をOccupied化する。
    func integrate(sensorOrigin: simd_float3, classifiedPoints: [ClassifiedPoint], timestamp: TimeInterval) {
        let sensorCoord = coordinate(forWorld: sensorOrigin)

        for point in classifiedPoints {
            let endCoordinate = coordinate(forWorld: point.worldPosition)
            let rayCells = bresenhamCells(from: sensorCoord, to: endCoordinate)

            for cell in rayCells.dropLast() {
                applyFreeUpdate(at: cell, timestamp: timestamp)
            }

            switch point.classification {
            case .floor, .overhead:
                // 占有格子には書き込まない対象。終点セルもFree側として扱う（3.2）
                applyFreeUpdate(at: endCoordinate, timestamp: timestamp)
            case .occupiedCandidate:
                applyOccupiedUpdate(at: endCoordinate, timestamp: timestamp)
            }
        }
    }

    // 視野外に出て再度観測されたセルは「連続観測」とみなさずリセットする
    // (視野外の間隔をそのまま加算すると、再観測した瞬間に安定判定へ飛んでしまうため)
    private static let maxContinuousObservationGap: TimeInterval = OGMConfig.depthCaptureInterval * 3

    private func applyOccupiedUpdate(at coord: GridCoordinate, timestamp: TimeInterval) {
        var state = cells[coord] ?? CellState()
        let wasOccupied = state.isOccupied
        let gap = timestamp - state.lastUpdateTime
        state.occupancyLogOdds = min(OGMConfig.logOddsMax, state.occupancyLogOdds + OGMConfig.logOddsOccupiedIncrement)
        if wasOccupied, state.lastUpdateTime > 0, gap <= Self.maxContinuousObservationGap {
            state.stabilityCounter += gap
        } else {
            state.stabilityCounter = 0
        }
        state.lastUpdateTime = timestamp
        cells[coord] = state
    }

    private func applyFreeUpdate(at coord: GridCoordinate, timestamp: TimeInterval) {
        var state = cells[coord] ?? CellState()
        state.occupancyLogOdds = max(OGMConfig.logOddsMin, state.occupancyLogOdds + OGMConfig.logOddsFreeIncrement)
        state.stabilityCounter = 0
        state.lastUpdateTime = timestamp
        cells[coord] = state
    }

    /// Bresenhamアルゴリズム（XZ平面, 2D）でstartからendまでの通過セルを列挙する
    func bresenhamCells(from start: GridCoordinate, to end: GridCoordinate) -> [GridCoordinate] {
        var result: [GridCoordinate] = []
        var x0 = start.x, z0 = start.z
        let x1 = end.x, z1 = end.z
        let dx = abs(x1 - x0), dz = abs(z1 - z0)
        let sx = x0 < x1 ? 1 : -1
        let sz = z0 < z1 ? 1 : -1
        var err = dx - dz

        while true {
            result.append(GridCoordinate(x: x0, z: z0))
            if x0 == x1 && z0 == z1 { break }
            let e2 = 2 * err
            if e2 > -dz { err -= dz; x0 += sx }
            if e2 < dx { err += dx; z0 += sz }
        }
        return result
    }
}
