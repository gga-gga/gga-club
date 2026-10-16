//
//  SpeechOutput.swift
//  SUWARERU
//
//  音声合成（TTS）と効果音の再生。何をいつ話すかは ViewController+Speech が決める。
//
//  VoiceOver が有効でも、案内はすべてここ（アプリ自身の音声合成）で話す。
//  VoiceOver のアナウンスに回すと、VoiceOver 自身の読み上げ（フォーカス移動・ヒント等）と
//  同じ1本の流れに乗り、後から来た方に途中で切られてしまうため。
//

import AVFoundation
import Foundation

final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private var sfxPlayer: AVAudioPlayer?

    var isSpeaking: Bool { synthesizer.isSpeaking }

    init() {
        configureAudioSession()
    }

    /// 消音スイッチ（マナーモード）が入っていても案内が鳴るよう「再生」カテゴリにする。
    /// 音楽など他のアプリの音は止めずに混ぜる。
    /// ※将来イヤホンのボタンで操作する場合は「再生中のアプリ」になる必要があり、
    ///   混ぜる設定（mixWithOthers）のままでは受け取れないので見直すこと。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.mixWithOthers])
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

    /// 話している内容・キューを即座に破棄する
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 効果音 → 発話 の順
    func speakWithSFX(_ utterance: AVSpeechUtterance) {
        playSFX(named: "NaviSound01.mp3") { [weak self] in
            self?.synthesizer.speak(utterance)
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
}
