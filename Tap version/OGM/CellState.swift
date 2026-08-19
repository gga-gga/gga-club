//
//  CellState.swift
//  占有格子地図（OGM）— セルごとの占有確率(log-odds)と持続性カウンタ（5.1）
//

import Foundation

struct CellState {
    var occupancyLogOdds: Float = 0
    /// 連続して占有観測された時間 [秒]（5.1）
    var stabilityCounter: TimeInterval = 0
    var lastUpdateTime: TimeInterval = 0

    var isOccupied: Bool { occupancyLogOdds >= OGMConfig.logOddsOccupiedThreshold }

    /// 安定 → 構造物（袖仕切り・座面など）の可能性が高い
    /// 不安定 → 人（脚・立ち乗客）や移動物の可能性が高い（5.2）
    /// この分類は物体種別の認識ではなく、観測の時間的安定性のみに基づく推定
    var isStable: Bool { stabilityCounter >= OGMConfig.stableDurationSeconds }
}
