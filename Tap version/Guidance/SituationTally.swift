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

    var crowdLevel: CrowdLevel { CrowdLevel(maxPersonCount: maxPersonCount) }
}

/// 空席1つ分の、今向いている方向から見た水平角度（右が +）と水平距離
struct SeatBearing {
    let yawDeg: Float
    let distance: Float
}

/// 状況確認の結果の読み上げ文
///  例：「近くの空席は3席あります。右側に2席、左側に1席。一番近いのは2時方向、約1.8メートルです。周囲はやや混んでいます。」
///  - 数えられるのは LiDAR の届く範囲（約3.5m）だけなので、車両全体と誤解されないよう「近くの」と言う
///  - 左右・方向は、結果を読み上げる時点で向いている方向が基準
enum SituationSummary {
    /// 正面とみなす角度の幅（±）[deg]
    static let frontHalfAngleDegrees: Float = 15

    /// - Parameters:
    ///   - seatCount: 空席の数
    ///   - bearings: 空席ごとの方向と距離（カメラの姿勢が取れないときは空。その場合は方向を言わない）
    static func text(seatCount: Int, bearings: [SeatBearing], crowd: CrowdLevel) -> String {
        guard seatCount > 0 else { return "近くに空席はありません。" + crowd.phrase }

        var text = "近くの空席は\(seatCount)席あります。"
        if seatCount >= 2, !bearings.isEmpty {
            text += sidesPhrase(bearings)
        }
        if let nearest = bearings.min(by: { $0.distance < $1.distance }) {
            let direction = GuidanceMath.directionPhrase(fromYawDeg: nearest.yawDeg) ?? ""
            let distance = GuidanceMath.approxDistancePhrase(fromMeters: nearest.distance)
            text += seatCount == 1 ? "\(direction)、\(distance)です。" : "一番近いのは\(direction)、\(distance)です。"
        }
        return text + crowd.phrase
    }

    /// 「右側に2席、左側に1席。」（0席の側は言わない）
    private static func sidesPhrase(_ bearings: [SeatBearing]) -> String {
        let right = bearings.filter { $0.yawDeg > frontHalfAngleDegrees }.count
        let left = bearings.filter { $0.yawDeg < -frontHalfAngleDegrees }.count
        let front = bearings.count - right - left
        var items: [String] = []
        if right > 0 { items.append("右側に\(right)席") }
        if left > 0 { items.append("左側に\(left)席") }
        if front > 0 { items.append("正面に\(front)席") }
        return items.joined(separator: "、") + "。"
    }
}
