//
//  SceneDelegate.swift
//  SUWARERU
//
//  UIScene ライフサイクルの窓口。画面（window）は Info.plist の Application Scene Manifest で
//  指定した storyboard（Main）から自動で作られる。
//
//  背面タップ（ショートカット → suwareru:// の URL）は、UIScene ライフサイクルでは
//  AppDelegate ではなくここに届く：
//   - アプリが起動していないとき：scene(_:willConnectTo:options:) の connectionOptions.urlContexts
//   - 起動中のとき：scene(_:openURLContexts:)
//

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        // window は storyboard から自動で作られるので、ここでは作らない。
        // 背面タップでアプリが起動された場合は、その操作を受け取る
        handleShortcutURLs(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        handleShortcutURLs(URLContexts)
    }

    /// 受け取った URL を背面タップの操作として、今表示している画面に渡す
    /// （表示中の画面がまだ無ければ ShortcutActionCenter が少しの間保持する）
    private func handleShortcutURLs(_ contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            if let action = ShortcutAction.from(url: context.url) {
                ShortcutActionCenter.shared.post(action)
            }
        }
    }
}
