//
//  NoSeatMonitor.swift
//  SUWARERU
//
//  空席が見つからない状態が続いたときの2段階アナウンス（警告 → 終了）の状態管理。
//

import Foundation

struct NoSeatMonitor {
    enum Action {
        case idle
        /// 「左右を写してください」
        case firstWarning
        /// 「空席が見つかりませんでした。終了します」
        case finalWarning
    }

    /// 空席ゼロになってから1回目を出すまでの秒数
    let firstDelay: TimeInterval = 8.0
    /// 「1回目のアナウンスから」2回目（終了）まで待つ秒数
    let afterFirstDelay: TimeInterval = 10.0

    /// 空席ゼロ状態になり始めた時刻
    private var startTime: TimeInterval?
    /// 1回目の「左右を写してください」を喋ったか
    private var firstWarningSpoken = false
    /// 1回目を喋った時刻（ここから追加時間を測る）
    private var firstWarningTime: TimeInterval?
    /// 2回目の「終了します」を喋ったか
    private var finalWarningSpoken = false

    init() {}

    mutating func reset() {
        startTime = nil
        firstWarningSpoken = false
        firstWarningTime = nil
        finalWarningSpoken = false
    }

    /// 案内開始時など、今から空席ゼロの時間を測り始める
    mutating func startCounting(at now: TimeInterval) {
        reset()
        startTime = now
    }

    /// 1秒ごとに呼ぶ。今アナウンスすべきものを返す
    mutating func tick(now: TimeInterval, isGuidancePaused: Bool, hasSeat: Bool) -> Action {
        // フェーズ3（案内中）以外、または空席が見つかっている間は監視をリセット
        if isGuidancePaused || hasSeat {
            reset()
            return .idle
        }

        // 空席ゼロになり始めた時刻をセット
        guard let start = startTime else {
            startCounting(at: now)
            return .idle
        }

        // まだ1回目を喋っていない → firstDelay 経過で1回目
        if !firstWarningSpoken && now - start >= firstDelay {
            firstWarningSpoken = true
            firstWarningTime = now
            return .firstWarning
        }

        // 1回目は喋った → 「1回目から」の経過時間を見る
        if firstWarningSpoken,
           !finalWarningSpoken,
           let firstTime = firstWarningTime,
           now - firstTime >= afterFirstDelay {
            finalWarningSpoken = true
            return .finalWarning
        }
        return .idle
    }
}
