//
//  StartViewController 2.swift
//  SUWARERU
//
//  Created by Sugitani on 2026/01/15.
//  Copyright © 2026 CompanyName. All rights reserved.
//


import UIKit

final class StartViewController: UIViewController {

    @IBOutlet weak var startButton: UIButton!  // Storyboard で接続
    private var shouldStartGuidanceOnLaunch = false
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        startButton.isAccessibilityElement = true
        startButton.accessibilityLabel = "案内を開始"
        startButton.accessibilityHint = "空席案内を開始します。"
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutStart),
            name: ShortcutAction.start.notificationName,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutStartGuidance),
            name: ShortcutAction.startGuidance.notificationName,
            object: nil
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, startButton)
        if ShortcutActionCenter.shared.consume(.start) {
            handleShortcutStart()
        }
        if ShortcutActionCenter.shared.consume(.startGuidance) {
            handleShortcutStartGuidance()
        }
    }

    @IBAction func onTapStart(_ sender: UIButton) {
        // Storyboard の segue で画面遷移を行う
    }
    
    @objc private func handleShortcutStart() {
        guard isViewLoaded else { return }
        startButton.sendActions(for: .touchUpInside)
    }
    
    @objc private func handleShortcutStartGuidance() {
        guard isViewLoaded else { return }
        shouldStartGuidanceOnLaunch = true
        startButton.sendActions(for: .touchUpInside)
    }
}
