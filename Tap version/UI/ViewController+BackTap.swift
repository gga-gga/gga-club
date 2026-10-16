//
//  ViewController+BackTap.swift
//  SUWARERU
//
//  誘導画面での背面タップ。3回＝決定・はい、2回＝もう一度・いいえ（ShortcutAction 参照）を、
//  今の状態に応じた操作に読み替える。メインスレッドで呼ばれる。
//
//  | 状態                   | 2回（もう一度・いいえ）       | 3回（決定・はい）                        |
//  |------------------------|------------------------------|------------------------------------------|
//  | 状況確認の計測中        | 「計測中です」と伝える          | 何もしない                                |
//  | 状況確認の結果を聞いた後 | もう一度確認する               | 誘導を開始（空席が無ければ開始しない）       |
//  | 誘導中                 | 今の方向と距離をすぐ読み上げる   | 中断の確認 → 10秒以内にもう一度3回で中断    |
//  | 到着時                 | 案内を続ける                  | 終了する                                  |
//

import UIKit

extension ViewController: ShortcutActionHandling {
    /// 中断の確認を受け付ける秒数
    static let abortConfirmationWindow: TimeInterval = 10.0

    func handleShortcutAction(_ action: ShortcutAction) {
        guard isViewLoaded, !isFinishingNavigation else { return }

        // 到着時
        if isAwaitingArrivalDecision {
            switch action {
            case .primary:
                onTapArrivalFinish(arrivalFinishButton)
            case .secondary:
                onTapArrivalContinue(arrivalContinueButton)
                interruptAndSpeak(text: "案内を続けます。")
            }
            return
        }

        // 誘導中
        if !isGuidancePaused {
            switch action {
            case .primary:
                handleAbortRequest()
            case .secondary:
                abortConfirmationDeadline = nil
                speakGuidanceNow()
            }
            return
        }

        // 状況確認中
        let isMeasuring = stateQueue.sync { isSituationCheckInProgress }
        if isMeasuring {
            if action == .secondary {
                interruptAndSpeak(text: "周囲を計測中です。終わるまでお待ちください。")
            }
            return
        }

        // 状況確認の結果を聞いた後
        switch action {
        case .primary:
            let seatCount = stateQueue.sync { seatTracker.availableSeatCount }
            if seatCount > 0 {
                onTapStartGuidance(startGuidanceButton)
            } else {
                interruptAndSpeak(text: "空席がないため、誘導を開始できません。もう一度確認するには、背面を2回タップしてください。")
            }
        case .secondary:
            startSituationCheckIfNeeded()
        }
    }

    /// 誘導中の3回タップ：誤って中断しないよう、確認してから中断する
    private func handleAbortRequest() {
        let now = CACurrentMediaTime()
        if let deadline = abortConfirmationDeadline, now <= deadline {
            abortConfirmationDeadline = nil
            abortNavigation()
            return
        }
        abortConfirmationDeadline = now + Self.abortConfirmationWindow
        interruptAndSpeak(text: "中断しますか？中断するには、10秒以内にもう一度、背面を3回タップしてください。")
    }

    private func abortNavigation() {
        // 以降の案内・振動を止める
        isFinishingNavigation = true
        directionHaptics.stop()
        interruptAndSpeak(text: "空席ナビを中断します。")

        // 言い終わるのを待ってから開始画面へ戻る
        let delay: TimeInterval = 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.prepareForExit()
            self.transitionToStartViewController()
        }
    }
}
