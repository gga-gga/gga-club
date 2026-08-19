//
//  OGMConfig.swift
//  占有格子地図（OGM）ナビゲーション — チューニングパラメータ
//
//  値は仕様書 9章「未確定・要実測パラメータ一覧」の仮値。実車両での実測により確定させること。
//

import Foundation

enum OGMConfig {
    // 深度取得
    static let depthCaptureInterval: TimeInterval = 1.0 / 10.0 // 10fps目標（歩行速度との整合は要実測）

    // グリッド
    static let cellSize: Float = 0.15 // m（Corridor-Walker準拠の仮値）

    // 高さフィルタ（3章）
    // 0にせず遊びを持たせる理由：LiDAR測定誤差・RANSAC残差・床面の微小凹凸を吸収するため
    // 実機テストでカメラ近傍の床が誤って占有判定される事例が確認されたため、
    // 当初の仮値(0.05)より広げてある（近距離・浅い入射角の床は深度ノイズが乗りやすい）
    static let floorMarginMeters: Float = 0.08
    static let overheadHeightMeters: Float = 2.0 // H_max：想定ユーザー身長+吊り革高さ

    // 深度取得の最小有効距離（3章の関連対策）
    // カメラ直近・浅い入射角の床は特にノイズが大きく、誤って占有候補になりやすいため、
    // 極端に近い点は最初から除外する
    static let minValidRangeMeters: Float = 0.25

    // 持続性カウンタ（5.1/5.2）
    static let stableDurationSeconds: TimeInterval = 2.5 // T_stable（2〜3秒の中間値、仮値）

    // 適応的マージン（5.3）
    static let stableMarginCells: Int = 1
    static let unstableMarginCells: Int = 3 // 2〜3セルの上限を採用（安全側に倒す）

    // コスト関数（5.3, Corridor-Walker Section 4.2準拠）
    static let costAlpha: Float = 3.0
    static let costBeta: Float = 50.0

    // log-odds occupancy（観測駆動、4.2）
    // 占有側の閾値を低く設定しているのは意図的：
    // 「正確な地図」より「安全な誘導」を優先する設計方針（0章）に基づき、
    // 1回の占有観測でも早めに障害物として扱い回避優先にするため。
    static let logOddsOccupiedIncrement: Float = 0.85
    static let logOddsFreeIncrement: Float = -0.4
    static let logOddsMin: Float = -6.0
    static let logOddsMax: Float = 6.0
    static let logOddsOccupiedThreshold: Float = 0.5

    // 再計画（7章）
    static let replanAtPathFractionWalked: Float = 0.5

    // 床面再推定の頻度（3.1：毎フレームは重いため低頻度再推定）
    static let floorReestimateIntervalSeconds: TimeInterval = 5.0
}
