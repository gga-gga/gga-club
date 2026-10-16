//  StartViewController.swift
//  SUWARERU
//  Created by Sugitani on 2026/01/15.
//
//  開始画面。VoiceOver で操作できるボタンに加えて、背面タップでも操作できる。
//   - 3回タップ：状況確認を始める（誘導画面へ）
//   - 2回タップ：使い方を読み上げる


import UIKit

final class StartViewController: UIViewController, ShortcutActionHandling {

    @IBOutlet weak var startButton: UIButton!  // Storyboard で接続

    private let speechOutput = SpeechOutput()

    override func viewDidLoad() {
        super.viewDidLoad()
        startButton.isAccessibilityElement = true
        startButton.accessibilityLabel = "案内を開始"
        startButton.accessibilityHint = "空席案内を開始します。"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, startButton)
        ShortcutActionCenter.shared.setHandler(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        ShortcutActionCenter.shared.clearHandler(self)
        speechOutput.stop()
    }

    @IBAction func onTapStart(_ sender: UIButton) {
        // Storyboard の segue で画面遷移を行う
    }

    // MARK: - 背面タップ

    func handleShortcutAction(_ action: ShortcutAction) {
        guard isViewLoaded, view.window != nil else { return }
        switch action {
        case .primary:
            startButton.sendActions(for: .touchUpInside)
        case .secondary:
            speechOutput.stop()
            let utterance = speechOutput.makeUtterance(
                "空席ナビです。背面を3回タップすると、周囲の空席と混み具合の確認を始めます。"
            )
            speechOutput.speakWithSFX(utterance)
        }
    }
}
