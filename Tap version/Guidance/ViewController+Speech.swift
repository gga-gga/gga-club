//
//  ViewController+Speech.swift
//  SUWARERU
//
//  何をいつ読み上げるか（空席の方向・距離、空席なし警告、到着、終了）。メインスレッドから呼ぶこと。
//  VoiceOver が有効でも、すべてアプリ自身の音声合成（SpeechOutput）で話す。
//  （VoiceOver のアナウンスに回すと、VoiceOver 自身の読み上げに途中で切られるため）
//
//  背面タップの案内は「3回＝決定・はい」「2回＝もう一度・いいえ」（ShortcutAction 参照）。
//

import AVFoundation
import UIKit
import simd

extension ViewController {
    /// 案内（方向と距離）の繰り返しの間隔：前の発話が「終わってから」この秒数あける。
    /// 以前は前の発話を「始めてから」3秒だったため、案内文（3秒以上かかる）がほぼ途切れず続いていた
    static let guidanceIntervalAfterSpeech: TimeInterval = 1.5

    /// いま話している内容やキューを全部止めて、効果音のあとに新しいテキストを読み上げる
    func interruptAndSpeak(text: String,
                           rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.1,
                           pitch: Float = 0.9,
                           volume: Float = 1.0) {
        speechOutput.stop()
        let utt = speechOutput.makeUtterance(text, rate: rate, pitch: pitch, volume: volume)
        speechOutput.speakWithSFX(utt)
    }

    /// 案内先の方向と距離を読み上げる。何か話している間と、前の発話が終わってから
    /// guidanceIntervalAfterSpeech 経っていない間は何もしない
    func speak(guidance: TargetGuidance) {
        // 終了処理中／到着パネル表示中／状況確認中はナビ音声を出さない
        if isFinishingNavigation || isAwaitingArrivalDecision || isGuidancePaused {
            return
        }
        // 誘導開始の案内や「空席が埋まりました」などを話している間は割り込まない
        if speechOutput.isBusy { return }
        if speechOutput.secondsSinceLastSpeech < Self.guidanceIntervalAfterSpeech { return }

        speechOutput.speak(speechOutput.makeUtterance(guidanceSentence(for: guidance)))
    }

    /// 背面タップ（2回）で、今の方向と距離をすぐに読み上げる
    func speakGuidanceNow() {
        speechOutput.stop()
        if let guidance = latestGuidance {
            speechOutput.speak(speechOutput.makeUtterance(guidanceSentence(for: guidance)))
        } else {
            speechOutput.speak(speechOutput.makeUtterance("案内できる空席を探しています。"))
        }
    }

    /// 案内の読み上げ文。後ろ（90°以上）のときは振動を止めているので、言葉で後ろだと伝える
    ///  - 経路あり：「11時方向へ進んでください、空席まで残り2.3メートル」（振動と同じ、進む方向）
    ///  - 経路なし：「空席、1時方向、残り2.3メートル」（空席そのものの方向）
    private func guidanceSentence(for guidance: TargetGuidance) -> String {
        let direction = GuidanceMath.directionPhrase(fromYawDeg: guidance.yawDeg) ?? ""
        let distance = GuidanceMath.distancePhrase(fromMeters: guidance.distance)

        if guidance.followsPath {
            let behind = guidance.isBehind ? "後ろです、" : ""
            return "\(behind)\(direction)へ進んでください、空席まで\(distance)"
        }
        let head = guidance.isBehind ? "空席は後ろです" : "空席"
        return "\(head)、\(direction)、\(distance)"
    }

    /// 誘導開始の案内。言い終わってから方向の案内が始まる（speak(guidance:) が待つ）
    func speakGuidanceStart() {
        interruptAndSpeak(text: "空席への誘導を開始します。方向をもう一度聞くには背面を2回、中断するには3回タップしてください。")
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
        interruptAndSpeak(text: text)
    }

    private func targetLossPhrase(_ reason: TargetLossReason) -> String {
        switch reason {
        case .occupied: return "案内中の空席が埋まりました。"
        case .lostSight: return "案内中の空席を見失いました。"
        }
    }

    /// 誘導中に案内できる空席がない状態が続いたとき（1回目）
    func speakNoSeatWarning() {
        if isAwaitingArrivalDecision || isGuidancePaused { return }
        interruptAndSpeak(text: "案内できる空席が見つかりません。体の向きをゆっくり変えて、周囲を確認してください。")
    }

    /// 誘導中に案内できる空席がない状態がさらに続いたとき：開始画面へ戻らず、状況確認からやり直す
    func speakNoSeatAndRestartSituationCheck() {
        if isAwaitingArrivalDecision || isGuidancePaused { return }
        interruptAndSpeak(text: "空席が見つかりませんでした。状況確認からやり直します。体ごと、ゆっくり左右に向きを変えてください。")
        returnToSituationCheck()
    }

    func speakArrivalPanelGuide() {
        if isGuidancePaused { return }
        interruptAndSpeak(text: "空席に到着しました。ナビを終了するには背面を3回、案内を続けるには背面を2回タップしてください。")
    }

    func speakFinishGreeting() {
        interruptAndSpeak(text: "お疲れ様でした。")
    }

    func stopAllTTS() {
        // ただちに読み上げを止める（キューと、効果音のあとに予約された発話も含めて）
        speechOutput.stop()
    }
}
