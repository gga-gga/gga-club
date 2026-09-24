//
//  DirectionHapticsController.swift
//  SUWARERU
//
//  案内方向とのズレ角に応じて、振動の強さ・間隔を変えながら周期的に振動させる。
//

import UIKit

final class DirectionHapticsController {
    private var feedback = UIImpactFeedbackGenerator(style: .medium)
    private var timer: DispatchSourceTimer?
    private var currentStyle: UIImpactFeedbackGenerator.FeedbackStyle = .medium
    private var currentIntensity: CGFloat = 0.6
    private var currentInterval: TimeInterval = 0.8

    func prepare() {
        feedback.prepare()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func update(angleDiff: Float) {
        let config = self.config(for: angleDiff)
        let needsStyleUpdate = config.style != currentStyle
        let needsIntervalUpdate = config.interval != currentInterval
        let needsIntensityUpdate = config.intensity != currentIntensity

        if needsStyleUpdate {
            feedback = UIImpactFeedbackGenerator(style: config.style)
            currentStyle = config.style
        }
        if needsIntervalUpdate {
            currentInterval = config.interval
        }
        if needsIntensityUpdate {
            currentIntensity = config.intensity
        }

        if needsStyleUpdate || needsIntervalUpdate || needsIntensityUpdate || timer == nil {
            feedback.prepare()
        }

        if needsIntervalUpdate || timer == nil {
            stop()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now(), repeating: currentInterval)
            timer.setEventHandler { [weak self] in
                guard let self = self else { return }
                if #available(iOS 13.0, *) {
                    self.feedback.impactOccurred(intensity: self.currentIntensity)
                } else {
                    self.feedback.impactOccurred()
                }
                self.feedback.prepare()
            }
            self.timer = timer
            timer.activate()
        }
    }

    private func config(for angleDiff: Float) -> (style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat, interval: TimeInterval) {
        switch angleDiff {
        case 0...5:
            return (.heavy, 1.0, 0.2)
        case 5...15:
            return (.medium, 0.75, 0.4)
        case 15...30:
            return (.light, 0.5, 0.7)
        default:
            return (.light, 0.3, 1.2)
        }
    }
}
