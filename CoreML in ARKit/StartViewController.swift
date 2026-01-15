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

    override func viewDidLoad() {
        super.viewDidLoad()
        startButton.isAccessibilityElement = true
        startButton.accessibilityLabel = "案内を開始"
        startButton.accessibilityHint = "空席案内を開始します。"
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, startButton)
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let destination = segue.destination as? ViewController {
            destination.isGuidancePaused = false
        } else if let nav = segue.destination as? UINavigationController,
                  let destination = nav.viewControllers.first as? ViewController {
            destination.isGuidancePaused = false
        }
    }

    @IBAction func onTapStart(_ sender: UIButton) {
        // Storyboard の segue で画面遷移を行う
    }
}
