//
//  AppDelegate.swift
//
//  UIScene ライフサイクルに移行済み。画面（window）の管理と URL（背面タップ）の受け取りは
//  SceneDelegate が行う。以前のように AppDelegate だけで画面を管理する方式は、
//  将来の iOS では起動時に停止する（assert）と予告されている。
//

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    // MARK: - UISceneSession Lifecycle

    /// 画面（シーン）を作るときの設定。Info.plist の Application Scene Manifest にある
    /// "Default Configuration"（SceneDelegate と storyboard の指定）を使う
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}
