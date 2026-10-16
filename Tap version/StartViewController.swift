//  StartViewController.swift
//  SUWARERU
//  Created by Sugitani on 2026/01/15.
//
//  開始画面（待機画面）。ボタンは置かず、背面タップで操作する。
//   - 3回タップ：状況確認を始める（誘導画面へ）
//   - 2回タップ：使い方を読み上げる
//  背面タップを設定していない端末のための予備として、VoiceOver のジェスチャも受け付ける。
//   - マジックタップ（2本指でダブルタップ）＝3回タップと同じ
//   - エスケープ（2本指でZを描く）＝2回タップと同じ


import UIKit

final class StartViewController: UIViewController, ShortcutActionHandling {

    private let speechOutput = SpeechOutput()

    /// 誘導画面の storyboard ID（Main.storyboard の ViewController に設定済み）
    private static let navigationStoryboardID = "ViewController"

    override func viewDidLoad() {
        super.viewDidLoad()
        // 画面全体を1つの要素にして、VoiceOver では使い方の説明だけを読ませる
        view.isAccessibilityElement = true
        view.accessibilityLabel = "空席ナビ。背面を3回タップすると、周囲の空席と混み具合の確認を始めます。使い方を聞くには、背面を2回タップしてください。"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, view)
        ShortcutActionCenter.shared.setHandler(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ShortcutActionCenter.shared.clearHandler(self)
        speechOutput.stop()
    }

    // MARK: - 背面タップ・VoiceOver のジェスチャ

    func handleShortcutAction(_ action: ShortcutAction) {
        guard isViewLoaded, view.window != nil else { return }
        switch action {
        case .primary:
            showNavigationScreen()
        case .secondary:
            speechOutput.stop()
            let utterance = speechOutput.makeUtterance(
                "空席ナビです。背面を3回タップすると、周囲の空席と混み具合の確認を始めます。"
            )
            speechOutput.speakWithSFX(utterance)
        }
    }

    override func accessibilityPerformMagicTap() -> Bool {
        handleShortcutAction(.primary)
        return true
    }

    override func accessibilityPerformEscape() -> Bool {
        handleShortcutAction(.secondary)
        return true
    }

    /// 誘導画面を開く（以前は「案内を開始」ボタンの segue で開いていた）
    private func showNavigationScreen() {
        guard presentedViewController == nil,
              let navigation = storyboard?.instantiateViewController(withIdentifier: Self.navigationStoryboardID) else { return }
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }
}
