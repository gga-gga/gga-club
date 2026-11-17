//
//  HeadOrientationTracker.swift
//  SUWARERU
//
//  立体音響の体験（試作）用：対応イヤホンから頭の向き（左右の回転）を読む。
//  対応：AirPods（第3世代以降・Pro・Max）、一部の Beats など、iOS が頭の動きを取れるもの。
//  骨伝導イヤホンなど対応していないものでは何も届かないので、呼び出し側は胸の向きを使う。
//
//  使うには、Info.plist にモーションの利用目的（NSMotionUsageDescription）が必要。
//  書かれていないまま読もうとするとアプリが強制終了するので、書かれていなければ使わない。
//  最初に使うとき、「モーションとフィットネス」の利用の許可を聞かれる。
//
//  頭の向きの基準（0°）はイヤホン側で決まり、部屋の向きとは関係ない。
//  そのため、ここで返すのは「ある時点からどれだけ回ったか」を求めるための値で、差だけに意味がある。
//

import CoreMotion
import Foundation
import QuartzCore

/// メインスレッドだけで使うこと（受信もメインスレッドで受け取る）
final class HeadOrientationTracker: @unchecked Sendable {
    /// 頭の向きのデータがこれより古ければ「受信なし」とみなす[秒]
    static let staleAfterSeconds: TimeInterval = 0.5
    /// 受信がないとき、受信の開始をやり直す間隔[秒]（イヤホンを後からつないだとき用）
    static let restartIntervalSeconds: TimeInterval = 3.0
    /// CoreMotion の yaw は、上から見て反時計回り（左へ回す）が + 。右が + になるよう符号を反転する。
    /// 実機で、頭を右へ向けたのに画面の「頭の向き」が左を示したら、ここを +1 にする
    static let yawSignToRightPositive: Double = -1

    private var managerStorage: AnyObject?
    private var latestYaw: Double?
    private var latestAt: TimeInterval = 0
    private var lastStartAttemptAt: TimeInterval = -.infinity
    private(set) var isRunning = false

    /// Info.plist にモーションの利用目的が書かれているか
    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") != nil
    }

    /// この端末・iOS で頭の向きを読めるか（イヤホンがつながっているかは別）
    var isSupported: Bool {
        guard Self.hasUsageDescription else { return false }
        if #available(iOS 14.0, *) {
            return manager.isDeviceMotionAvailable
        }
        return false
    }

    @available(iOS 14.0, *)
    private var manager: CMHeadphoneMotionManager {
        if let existing = managerStorage as? CMHeadphoneMotionManager { return existing }
        let created = CMHeadphoneMotionManager()
        managerStorage = created
        return created
    }

    func start() {
        guard isSupported else { return }
        if #available(iOS 14.0, *) {
            lastStartAttemptAt = CACurrentMediaTime()
            manager.stopDeviceMotionUpdates()
            manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
                guard let self = self, let motion = motion else { return }
                self.latestYaw = motion.attitude.yaw
                self.latestAt = CACurrentMediaTime()
            }
            isRunning = true
        }
    }

    func stop() {
        if #available(iOS 14.0, *), managerStorage != nil {
            manager.stopDeviceMotionUpdates()
        }
        isRunning = false
        latestYaw = nil
    }

    /// 最新の頭の向き[ラジアン]（右へ回すと増える。基準は任意で、差だけに意味がある）。受信がなければ nil
    func currentYaw(now: TimeInterval) -> Double? {
        guard let latestYaw, now - latestAt <= Self.staleAfterSeconds else { return nil }
        return latestYaw * Self.yawSignToRightPositive
    }

    /// 画面の更新ごとに呼ぶ。受信が途切れていたら、ときどき受信の開始をやり直す
    func tick(now: TimeInterval) {
        guard isRunning, currentYaw(now: now) == nil,
              now - lastStartAttemptAt >= Self.restartIntervalSeconds else { return }
        start()
    }
}
