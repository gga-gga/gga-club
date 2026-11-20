//
//  SpeechOutput.swift
//  SUWARERU
//
//  音声合成（TTS）と効果音の再生。何をいつ話すかは ViewController+Speech が決める（メインスレッドで使う）。
//
//  VoiceOver が有効でも、案内はすべてここ（アプリ自身の音声合成）で話す。
//  VoiceOver のアナウンスに回すと、VoiceOver 自身の読み上げ（フォーカス移動・ヒント等）と
//  同じ1本の流れに乗り、後から来た方に途中で切られてしまうため。
//

import AVFoundation
import Foundation
import QuartzCore

/// メインスレッドだけで使うこと（呼び出し元はすべてメインスレッド、delegate の通知もメインスレッドに届く）。
/// 新しい SDK では AVSpeechSynthesizerDelegate が Sendable を要求するため、このクラスも Sendable 扱いになるが、
/// 中の AVSpeechSynthesizer 等は Sendable ではない。スレッドの安全性は上の使い方で保証しているので、
/// コンパイラの検査は外す（@unchecked Sendable）。
final class SpeechOutput: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private var sfxPlayer: AVAudioPlayer?

    /// 効果音を鳴らし終えて発話を始めるのを待っている間 true
    private var isPlayingSFX = false
    /// stop() のたびに進める番号。止める前に予約された「効果音のあとの発話」を取り消すのに使う
    private var generation = 0
    /// 最後に発話が終わった（または止められた）時刻
    private(set) var lastSpeechEndedAt: TimeInterval = 0

    /// 発話中、または効果音のあとの発話を待っている間
    var isBusy: Bool { synthesizer.isSpeaking || isPlayingSFX }

    /// 最後の発話が終わってからの秒数
    var secondsSinceLastSpeech: TimeInterval { CACurrentMediaTime() - lastSpeechEndedAt }

    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }

    /// 消音スイッチ（マナーモード）が入っていても案内が鳴るよう「再生」カテゴリにする。
    /// 音楽など他のアプリの音は止めずに混ぜる。
    /// ※将来イヤホンのボタンで操作する場合は「再生中のアプリ」になる必要があり、
    ///   混ぜる設定（mixWithOthers）のままでは受け取れないので見直すこと。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // プロジェクトの Swift のバージョン設定によって API の名前が違うため、両方に対応する
            #if swift(>=4.2)
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            #else
            try session.setCategory(AVAudioSessionCategoryPlayback, mode: AVAudioSessionModeDefault, options: [.mixWithOthers])
            #endif
            try session.setActive(true)
        } catch {
            print("AVAudioSession setup error:", error)
        }
    }

    func makeUtterance(_ text: String,
                       rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.1,
                       pitch: Float = 0.9,
                       volume: Float = 1.0) -> AVSpeechUtterance {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utt.rate  = rate
        utt.pitchMultiplier = pitch
        utt.volume = volume
        // VoiceOver が有効なら、利用者が VoiceOver で設定している声・話す速さを使う
        // （VoiceOver が無効なら上の値が使われる）
        if #available(iOS 14.0, *) {
            utt.prefersAssistiveTechnologySettings = true
        }
        return utt
    }

    func speak(_ utterance: AVSpeechUtterance) {
        synthesizer.speak(utterance)
    }

    /// 話している内容・キュー・効果音のあとに予約された発話を、すべて即座に破棄する
    func stop() {
        generation += 1
        isPlayingSFX = false
        sfxPlayer?.stop()
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 効果音 → 発話 の順
    func speakWithSFX(_ utterance: AVSpeechUtterance) {
        let token = generation
        isPlayingSFX = true
        playSFX(named: "NaviSound01.mp3") { [weak self] in
            // 効果音の間に stop() されていたら、この発話は取り消されている
            guard let self = self, self.generation == token else { return }
            self.isPlayingSFX = false
            self.synthesizer.speak(utterance)
        }
    }

    func playSFX(named filename: String, completion: (() -> Void)? = nil) {
        guard let url = Bundle.main.url(forResource: filename, withExtension: nil) else {
            print("SFX file not found: \(filename)")
            completion?()
            return
        }

        do {
            sfxPlayer = try AVAudioPlayer(contentsOf: url)
            sfxPlayer?.prepareToPlay()

            // 再生後に completion を呼ぶ
            sfxPlayer?.play()

            if let comp = completion {
                DispatchQueue.main.asyncAfter(deadline: .now() + (sfxPlayer?.duration ?? 0.1)) {
                    comp()
                }
            }

        } catch {
            print("Error loading SFX: \(error)")
            completion?()
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        lastSpeechEndedAt = CACurrentMediaTime()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        lastSpeechEndedAt = CACurrentMediaTime()
    }
}
