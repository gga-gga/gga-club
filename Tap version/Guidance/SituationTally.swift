//
//  SituationTally.swift
//  SUWARERU
//
//  案内開始前の「状況確認」の集計と読み上げ文。
//   - 空席の数：見回している間に確定した空席トラックの数（SeatTracker）。3Dの位置で同じ席を
//     判断しているので、見回して何度も映った席を重複して数えない。
//     以前は「1画面に同時に映った空席数」の最頻値で、周囲全体より少なく数えていた。
//   - 混雑度：1画面に映った人数の最大値を3段階の言葉にする。人を3Dで追跡していないので
//     正確な人数ではない。そのため人数そのものは言わず、混み具合だけを伝える。
//

import Foundation

/// 混雑度の段階（境目は仮値・実車で要調整）
enum CrowdLevel {
    case quiet
    case moderate
    case crowded

    /// この人数以下なら「空いている」
    static let quietMaxPersons = 2
    /// この人数以下なら「やや混んでいる」、超えたら「混んでいる」
    static let moderateMaxPersons = 5

    init(maxPersonCount: Int) {
        if maxPersonCount <= Self.quietMaxPersons {
            self = .quiet
        } else if maxPersonCount <= Self.moderateMaxPersons {
            self = .moderate
        } else {
            self = .crowded
        }
    }

    var phrase: String {
        switch self {
        case .quiet: return "周囲は空いています。"
        case .moderate: return "周囲はやや混んでいます。"
        case .crowded: return "周囲は混んでいます。"
        }
    }
}

struct SituationTally {
    /// 見回している間に1画面に映った人数の最大値
    private(set) var maxPersonCount = 0

    init() {}

    mutating func reset() {
        maxPersonCount = 0
    }

    mutating func record(personCount: Int) {
        maxPersonCount = max(maxPersonCount, personCount)
    }

    /// 状況確認の結果の読み上げ文
    /// - Parameter seatCount: 確定済みで空席と判定されている席の数
    func summaryText(seatCount: Int) -> String {
        let seats = seatCount == 0 ? "空席はありません。" : "空席は\(seatCount)席あります。"
        return seats + CrowdLevel(maxPersonCount: maxPersonCount).phrase
    }
}
