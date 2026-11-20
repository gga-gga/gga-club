//
//  DirectionHapticsController.swift
//  SUWARERU
//
//  案内先の方向を振動で伝える（メインスレッドから呼ぶこと）。
//   - 強さと間隔：正面からのズレ（|yaw|）が小さいほど強く速い
//   - 左右：右は「トン」、左は「トントン」。正面付近（±10°以内）は左右を区別しない
//   - 後ろ（|yaw| が90°以上）：振動を止める（向きは読み上げで伝える）
//  ズレが段階の境目付近で揺れても振動が細かく切り替わらないよう、境目に余裕（ヒステリシス）を持たせる。
//

import UIKit

final class DirectionHapticsController {
    private enum Side { case center, right, left }

    private struct Pattern: Equatable {
        let level: Int
        let side: Side
    }

    /// 各段階の |yaw| の上限[deg]。段階0が正面
    private static let levelUpperBounds: [Float] = [10, 30, 60, 90]
    private static let styles: [UIImpactFeedbackGenerator.FeedbackStyle] = [.heavy, .medium, .light, .light]
    private static let intensities: [CGFloat] = [1.0, 0.75, 0.5, 0.3]
    /// 振動（左なら2回の組）の間隔[s]。左の2回目が次の組と混ざらないよう段階1以降は0.5秒以上にしている
    private static let intervals: [TimeInterval] = [0.2, 0.5, 0.8, 1.2]
    /// 左の「トントン」の2回の間隔[s]
    private static let doublePulseGap: TimeInterval = 0.12
    /// 段階の境目の余裕[deg]
    private static let hysteresis: Float = 3
    private static let behindAngle: Float = 90

    private var feedback = UIImpactFeedbackGenerator(style: .heavy)
    private var currentStyle: UIImpactFeedbackGenerator.FeedbackStyle = .heavy
    private var timer: DispatchSourceTimer?
    private var currentPattern: Pattern?
    private var isSilencedBehind = false

    func prepare() {
        feedback.prepare()
    }

    func stop() {
        stopTimer()
        isSilencedBehind = false
    }

    /// - Parameter yawDeg: 案内先の水平角度[deg]（右が +）
    func update(yawDeg: Float) {
        let absYaw = abs(yawDeg)

        // 後ろ：振動を止める。90°付近で出たり止まったりしないよう、戻るときは少し手前まで待つ
        if absYaw >= Self.behindAngle || (isSilencedBehind && absYaw > Self.behindAngle - Self.hysteresis) {
            isSilencedBehind = true
            stopTimer()
            return
        }
        isSilencedBehind = false

        let level = Self.level(for: absYaw, previous: currentPattern?.level)
        let side: Side = level == 0 ? .center : (yawDeg > 0 ? .right : .left)
        let pattern = Pattern(level: level, side: side)
        guard pattern != currentPattern || timer == nil else { return }
        start(pattern)
    }

    private func start(_ pattern: Pattern) {
        stopTimer()
        currentPattern = pattern

        let style = Self.styles[pattern.level]
        if style != currentStyle {
            feedback = UIImpactFeedbackGenerator(style: style)
            currentStyle = style
        }
        feedback.prepare()

        let intensity = Self.intensities[pattern.level]
        let isDoublePulse = pattern.side == .left
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: Self.intervals[pattern.level])
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.pulse(intensity: intensity)
            if isDoublePulse {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.doublePulseGap) { [weak self] in
                    // 2回目までの間に止められていたら鳴らさない
                    guard let self = self, self.timer != nil else { return }
                    self.pulse(intensity: intensity)
                }
            }
        }
        self.timer = timer
        timer.activate()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        currentPattern = nil
    }

    private func pulse(intensity: CGFloat) {
        if #available(iOS 13.0, *) {
            feedback.impactOccurred(intensity: intensity)
        } else {
            feedback.impactOccurred()
        }
        feedback.prepare()
    }

    /// |yaw| から段階を決める。前の段階の範囲から余裕以内しかはみ出していなければ前の段階を保つ
    private static func level(for absYaw: Float, previous: Int?) -> Int {
        let raw = levelUpperBounds.firstIndex(where: { absYaw <= $0 }) ?? levelUpperBounds.count - 1
        guard let previous, previous != raw else { return raw }
        let lower = previous == 0 ? 0 : levelUpperBounds[previous - 1]
        let upper = levelUpperBounds[previous]
        if absYaw >= lower - hysteresis && absYaw <= upper + hysteresis {
            return previous
        }
        return raw
    }
}
