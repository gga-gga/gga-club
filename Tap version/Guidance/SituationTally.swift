//
//  SituationTally.swift
//  SUWARERU
//
//  案内開始前の「状況確認」で、フレームごとの空席数・人数を集計し最頻値で要約する。
//

import Foundation

struct SituationTally {
    private var emptySeatCounts: [Int: Int] = [:]
    private var personCounts: [Int: Int] = [:]

    init() {}

    mutating func reset() {
        emptySeatCounts.removeAll()
        personCounts.removeAll()
    }

    mutating func record(emptySeatCount: Int, personCount: Int) {
        emptySeatCounts[emptySeatCount, default: 0] += 1
        personCounts[personCount, default: 0] += 1
    }

    /// 集計結果（最頻値）の読み上げ文
    func summaryText() -> String {
        let emptySeats = Self.modeCount(from: emptySeatCounts)
        let people = Self.modeCount(from: personCounts)
        return Self.summaryText(emptySeatCount: emptySeats, personCount: people)
    }

    private static func modeCount(from counts: [Int: Int]) -> Int {
        guard let (value, _) = counts.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key > rhs.key
            }
            return lhs.value < rhs.value
        }) else {
            return 0
        }
        return value
    }

    private static func summaryText(emptySeatCount: Int, personCount: Int) -> String {
        let personCountText: String
        switch personCount {
        case 1:
            personCountText = "ひとり"
        case 2:
            personCountText = "ふたり"
        default:
            personCountText = "\(personCount)人"
        }
        if emptySeatCount == 0 {
            return "空席はありません。周囲の人は\(personCountText)です。"
        }
        if personCount == 0 {
            return "空席は\(emptySeatCount)席、周囲の人は\(personCountText)です。"
        }
        return "空席は\(emptySeatCount)席、周囲の人は\(personCount)人です。"
    }
}
