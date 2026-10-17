//  ShortcutAction.swift
//  SUWARERU
//  Created by Sugitani on 2026/01/21.
//
//  背面タップの受け取り。iPhone の設定で、背面タップ → ショートカット → アプリの URL を開く、
//  という流れになっている。アプリが受け取るのは「2回」「3回」のどちらが来たかだけで、
//  その意味（はい／いいえ など）は、今表示している画面が自分の状態に応じて決める。
//
//   - 3回タップ（suwareru://startt）＝ 決定・はい（状態を進める・終わらせる操作）
//   - 2回タップ（suwareru://start） ＝ もう一度・いいえ（誤って反応しても害のない操作）
//  ポーチを胸に下げていると体や物に当たって誤反応しやすく、誤反応しやすいのは2回タップの方なので、
//  影響の大きい操作を3回タップに置いている。URL は既存のショートカット設定のまま変えない。

import Foundation

enum ShortcutAction: String {
    /// 背面タップ2回：もう一度・いいえ
    case secondary = "start"
    /// 背面タップ3回：決定・はい
    case primary = "startt"

    static let scheme = "suwareru"

    static func from(url: URL) -> ShortcutAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let actionValue = (url.host ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return ShortcutAction(rawValue: actionValue)
    }
}

/// 背面タップを受け取る画面
protocol ShortcutActionHandling: AnyObject {
    func handleShortcutAction(_ action: ShortcutAction)
}

/// 背面タップを、今表示している画面だけに届ける（メインスレッドで使う）。
/// 以前は各画面が通知を常に受け取っていたため、隠れている開始画面まで反応して
/// 画面遷移が二重に起きる恐れがあった。
final class ShortcutActionCenter {
    static let shared = ShortcutActionCenter()

    /// 受け取る画面が無い間（アプリの起動直後・画面の切り替え中）に届いたものは、
    /// この秒数以内に画面が表示されれば渡す。古いものは捨てる（思わぬ時に反応しないように）
    private let pendingLifetime: TimeInterval = 3.0

    private weak var handler: ShortcutActionHandling?
    private var pendingAction: (action: ShortcutAction, receivedAt: Date)?

    func post(_ action: ShortcutAction) {
        if let handler = handler {
            handler.handleShortcutAction(action)
        } else {
            pendingAction = (action, Date())
        }
    }

    /// 画面が表示されたら呼ぶ。待っていた操作があれば、すぐに渡す
    func setHandler(_ newHandler: ShortcutActionHandling) {
        handler = newHandler
        if let pending = pendingAction {
            pendingAction = nil
            if Date().timeIntervalSince(pending.receivedAt) <= pendingLifetime {
                newHandler.handleShortcutAction(pending.action)
            }
        }
    }

    /// 画面が隠れるときに呼ぶ
    func clearHandler(_ oldHandler: ShortcutActionHandling) {
        if handler === oldHandler {
            handler = nil
        }
    }
}
