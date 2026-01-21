//
//  ShortcutAction.swift
//  SUWARERU
//
//  Created by Sugitani on 2026/01/21.
//  Copyright © 2026 CompanyName. All rights reserved.
//

import Foundation

enum ShortcutAction: String {
    case start = "start"
    case startGuidance = "startt"

    static let scheme = "suwareru"

    var notificationName: Notification.Name {
        Notification.Name("ShortcutAction.\(rawValue)")
    }

    static func from(url: URL) -> ShortcutAction? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let actionValue = (url.host ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return ShortcutAction(rawValue: actionValue)
    }
}

final class ShortcutActionCenter {
    static let shared = ShortcutActionCenter()

    private var pendingAction: ShortcutAction?
    
    func isPending(_ action: ShortcutAction) -> Bool {
        pendingAction == action
    }

    func post(_ action: ShortcutAction) {
        pendingAction = action
        NotificationCenter.default.post(name: action.notificationName, object: nil)
    }

    func consume(_ action: ShortcutAction) -> Bool {
        guard pendingAction == action else { return false }
        pendingAction = nil
        return true
    }
}
