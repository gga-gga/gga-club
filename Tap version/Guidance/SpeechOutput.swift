//
//  SpeechOutput.swift
//  SUWARERU
//
//  音声合成（TTS）と効果音の再生。何をいつ話すかは ViewController+Speech が決める。
//

import AVFoundation
import Foundation

final class SpeechOutput {
    private let synthesizer = AVSpeechSynthesizer()
    private var sfxPlayer: AVAudioPlayer?

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func makeUtterance(_ text: String,
                       rate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.1,
                       pitch: Float = 0.9,
                       volume: Float = 1.0) -> AVSpeechUtterance {
        let utt = AVSpeechUtterance(string: text)
        utt.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        utt.rate  = rate
        utt.pitchMultiplier = pitch
        utt.volume = volume
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
