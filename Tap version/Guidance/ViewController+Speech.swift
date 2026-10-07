//
//  ViewController+Speech.swift
//  SUWARERU
//
//  何をいつ読み上げるか（空席の方向・距離、空席なし警告、到着、終了）。
//  VoiceOver 実行中は TTS ではなく VoiceOver のアナウンスに回す。
//

import AVFoundation
import UIKit
import simd

extension ViewController {
    /// いま話している内容やキューを全部止めて、すぐ新しいテキストを読み上げる
    func interruptAndSpeak(text: String,
                           rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.0,
                           pitch: Float = 1.0,
                           volume: Float = 1.0) {
        if isVoiceOverRunning() {
            announceForAccessibility(text)
            return
        }
        // しゃべっていたら即停止（キューも含めて破棄）
        speechOutput.stop()
        // クールダウン管理をしているなら、ここでリセットしておく
        lastSpokenAt.removeAll()

        let utt = speechOutput.makeUtterance(text, rate: rate, pitch: pitch, volume: volume)

        DispatchQueue.main.async { [weak self] in
            self?.speechOutput.speakWithSFX(utt)
        }
    }

    /// 案内先の方向と距離を読み上げる（メインスレッドから呼ぶ）。
    /// 前回から ttsCooldownSeconds 経っていなければ何もしない
    func speak(guidance: TargetGuidance) {
        // 終了処理中／到着パネル表示中はナビ音声を出さない
        if isFinishingNavigation || isAwaitingArrivalDecision || isGuidancePaused {
            return
        }

        let now = CACurrentMediaTime()
        // クールダウン（あまり頻度が高すぎないように）
        if let last = lastSpokenAt[guidance.trackID],
           now - last < ttsCooldownSeconds {
            return
        }

        // ★ すでに何かしゃべっている最中ならスキップする
        if speechOutput.isSpeaking { return }

        lastSpokenAt[guidance.trackID] = now

        // 後ろ（90°以上）のときは振動を止めているので、言葉で後ろだと伝える
        var parts: [String] = [guidance.isBehind ? "空席は後ろです" : "空席"]
        if let dir = GuidanceMath.directionPhrase(fromYawDeg: guidance.yawDeg) {
            parts.append(dir)   // 例: "3時方向"
        }
        parts.append(GuidanceMath.distancePhrase(fromMeters: guidance.distance))
        let sentence = parts.joined(separator: "、")

        if isVoiceOverRunning() {
            announceForAccessibility(sentence)
            return
        }

        let utt = speechOutput.makeUtterance(sentence,
                                             rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                                             pitch: 0.9,
                                             volume: 1.0)
        speechOutput.speak(utt)
    }

    /// 案内先を失った・切り替えたことを、理由と合わせて伝える
    func announceTargetEvent(_ event: TargetEvent) {
        if isFinishingNavigation || isAwaitingArrivalDecision || isGuidancePaused { return }

        let text: String
        switch event {
        case .switched(let reason, _):
            text = "\(targetLossPhrase(reason))別の空席を案内します。"
        case .lost(let reason):
            text = targetLossPhrase(reason)
        case .selected, .unchanged:
            return
        }
        interruptAndSpeak(
            text: text,
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitch: 0.9,
            volume: 1.0
        )
    }

    private func targetLossPhrase(_ reason: TargetLossReason) -> String {
        switch reason {
        case .occupied: return "案内中の空席が埋まりました。"
        case .lostSight: return "案内中の空席を見失いました。"
        }
    }

    func speakNoSeatWarning() {
        // パネル中はしゃべらない
        if isAwaitingArrivalDecision || isGuidancePaused { return }
        if isVoiceOverRunning() {
            announceForAccessibility("空席が消失しました。カメラで左右を写して空席を探してください。")
            return
        }
        interruptAndSpeak(
            text: "空席が消失しました。カメラで左右を写して空席を探してください。",
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitch: 0.9,
            volume: 1.0
        )
    }

    func speakArrivalPanelGuide() {
        if isGuidancePaused { return }
        let utt = speechOutput.makeUtterance(
            "空席に到着しました。ナビを終了しますか？終了するには画面左側、続けるには画面右側をタップしてください。",
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitch: 0.9,
            volume: 1.0
        )
        DispatchQueue.main.async { [weak self] in
            if self?.isVoiceOverRunning() == true {
                self?.announceForAccessibility(utt.speechString)
                return
            }
            self?.speechOutput.speakWithSFX(utt)
        }
    }

    func speakNoSeatFinalAndExit() {
        if isAwaitingArrivalDecision || isGuidancePaused { return }
        let text = "空席が見つかりませんでした。空席ナビを終了します。"
        let utt = speechOutput.makeUtterance(text,
                                             rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
                                             pitch: 0.9,
                                             volume: 1.0)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // いま話しているもの＆キューを即座に止める（割り込み）
            self.speechOutput.stop()
            // クールダウン管理しているなら、リセットしておくと安全
            self.lastSpokenAt.removeAll()

            // 終了アナウンスを新しく再生
            if self.isVoiceOverRunning() {
                self.announceForAccessibility(utt.speechString)
            } else {
                self.speechOutput.speak(utt)
                self.announceForAccessibility(text)
            }

            // 少し待ってから自動終了（テキストの長さに合わせて調整）
            let delay: TimeInterval = 4.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }

                self.stopAllTTS()
                self.sceneView.session.pause()
                self.transitionToStartViewController()
            }
        }
    }

    func speakFinishGreeting() {
        interruptAndSpeak(
            text: "お疲れ様でした。",
            rate: AVSpeechUtteranceDefaultSpeechRate * 1.1,
            pitch: 0.9,
            volume: 1.0
        )
    }

    func stopAllTTS() {
        // ただちに読み上げを止める（キューに入ってる分も含めて）
        speechOutput.stop()

        // クールダウン管理用の履歴もリセットしておく
        lastSpokenAt.removeAll()
    }
}
