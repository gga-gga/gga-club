//
//  ViewController+Accessibility.swift
//  SUWARERU
//
//  VoiceOver 向けのラベル・フォーカス制御とアナウンス。
//

import UIKit

extension ViewController {
    func configureAccessibility() {
        arrivalPanelView.isAccessibilityElement = false

        startGuidanceButton.isAccessibilityElement = true
        startGuidanceButton.accessibilityLabel = "空席誘導"
        startGuidanceButton.accessibilityHint = "空席への誘導を開始します。"

        arrivalContinueButton.isAccessibilityElement = true
        arrivalContinueButton.accessibilityLabel = "継続"
        arrivalContinueButton.accessibilityHint = "空席案内を続行します。"

        arrivalFinishButton.isAccessibilityElement = true
        arrivalFinishButton.accessibilityLabel = "終了"
        arrivalFinishButton.accessibilityHint = "空席案内を終了します。"

        exitButton.isAccessibilityElement = true
        exitButton.accessibilityLabel = "ナビ中断"
        exitButton.accessibilityHint = "中断して開始画面に戻ります。"

        arrivalPanelView.accessibilityElements = [
            arrivalFinishButton as Any,
            arrivalContinueButton as Any
        ]

        debugTextView.isAccessibilityElement = false
        debugTextView.accessibilityElementsHidden = true

        TextView.isAccessibilityElement = false

        updateAccessibilityForCurrentState()
    }

    func updateAccessibilityForCurrentState() {
        let isArrivalPanelVisible = isAwaitingArrivalDecision && !arrivalPanelView.isHidden

        startGuidanceButton.accessibilityElementsHidden = !isGuidancePaused || isArrivalPanelVisible
        startGuidanceButton.isAccessibilityElement = isGuidancePaused && !isArrivalPanelVisible

        exitButton.accessibilityElementsHidden = isArrivalPanelVisible
        exitButton.isAccessibilityElement = !isArrivalPanelVisible

        arrivalContinueButton.accessibilityElementsHidden = !isArrivalPanelVisible
        arrivalContinueButton.isAccessibilityElement = isArrivalPanelVisible

        arrivalFinishButton.accessibilityElementsHidden = !isArrivalPanelVisible
        arrivalFinishButton.isAccessibilityElement = isArrivalPanelVisible

        if isVoiceOverRunning() {
            let focusTarget: AnyObject = isGuidancePaused && !isArrivalPanelVisible
                ? startGuidanceButton
                : (isArrivalPanelVisible ? arrivalPanelView : exitButton)
            UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, focusTarget)
        }
    }

    func announceForAccessibility(_ message: String) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message)
    }

    func isVoiceOverRunning() -> Bool {
        UIAccessibilityIsVoiceOverRunning()
    }
}
