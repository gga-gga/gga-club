//
//  SpatialBeaconPlayer.swift
//  SUWARERU
//
//  立体音響の体験（試作）用：聞き手から見た方向に、短い音（ピッ）をくり返し鳴らす。
//
//  聞き手は原点にいて、いつも -Z の方向（正面）を向いているものとして扱う。
//  体の向きが変わったら、音源の位置のほうを動かす（setRelativeBearing）。
//    右 = +X、正面 = -Z、上 = +Y（AVAudioEnvironmentNode の座標）
//
//  音は音声ファイルを使わず、ここで作る。方向の分かりやすさを比べられるよう、3種類から選べる（Tone）。
//    ビープ音     ：1つの高さだけの音。先行研究に近い、比べる基準
//    倍音ビープ   ：低めの音に高い倍音を重ねた音。聞き取りやすさと方向の分かりやすさの中間
//    雑音パルス   ：広い高さを含む雑音。前後・左右の手がかりが一番多いはず
//  種類によって音量がばらつかないよう、平均の大きさ（RMS）をそろえている。
//  ただし聞こえる大きさは高い音を含むほど大きく感じるので、当日の音量はスタッフが聞いて確かめること。
//

import AVFoundation
import Foundation

/// メインスレッドだけで使うこと（SpeechOutput と同じ理由で @unchecked Sendable にしている）
final class SpatialBeaconPlayer: @unchecked Sendable {
    /// 音の方向の付け方
    enum Rendering {
        /// 立体音響（頭部伝達関数。前後・左右の聞こえ方の違いを再現する）
        case hrtf
        /// 左右の音量の差だけ（先行研究で多い方法。前と後ろは区別できない）
        case panning
    }

    /// 音の種類
    enum Tone: CaseIterable {
        /// 1つの高さだけの音（1kHz の正弦波、0.1秒）
        case beep
        /// 低めの音（500Hz）に 8kHz までの倍音を重ねた、ブザーのような音（0.1秒）
        case harmonicBeep
        /// 広い高さを含む雑音（白色雑音、0.08秒）
        case noisePulse

        var displayName: String {
            switch self {
            case .beep: return "ビープ音"
            case .harmonicBeep: return "倍音ビープ"
            case .noisePulse: return "雑音パルス"
            }
        }
    }

    /// 音源までの距離[m]。いつもこの距離に置くので、距離による音量の変化は起きない
    static let sourceDistance: Float = 2.0
    /// 音を鳴らす間隔[秒]
    static let normalInterval: TimeInterval = 0.40
    /// 向きが合っているときの間隔[秒]（usesAlignedPing が true のとき）
    static let alignedInterval: TimeInterval = 0.18
    /// 音の平均の大きさ（RMS）。3種類ともこの大きさにそろえる
    private static let targetRMS = 0.15
    /// 音の一番大きいところの上限（音割れを防ぐ）
    private static let maxPeak = 0.9

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private var normalPing: AVAudioPCMBuffer?
    private var alignedPing: AVAudioPCMBuffer?
    private var nextPingAt: TimeInterval = 0
    private var isGraphReady = false
    private var wantsRunning = false
    private var configurationObserver: NSObjectProtocol?
    private var monoFormat: AVAudioFormat?

    var rendering: Rendering = .hrtf {
        didSet { applyRendering() }
    }

    /// 音の種類。変えたら、次に鳴らす音から切り替わる
    var tone: Tone = .beep {
        didSet {
            if tone != oldValue { rebuildPings() }
        }
    }

    /// true の間だけ音を鳴らす
    var isSounding = false {
        didSet {
            // 鳴らし始めたら、すぐに最初の音を出す
            if isSounding && !oldValue { nextPingAt = 0 }
        }
    }

    /// true の間は、高い音を短い間隔で鳴らす（向きが合っている合図）
    var usesAlignedPing = false

    init() {
        setUpGraph()
        // イヤホンをつないだ・外したときなどは、エンジンが止まるので動かし直す
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.wantsRunning else { return }
            self.start()
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - 準備

    private func setUpGraph() {
        engine.attach(environment)
        engine.attach(player)

        var sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44_100 }
        // 方向を付けられるのはモノラルの音だけなので、音源はモノラルにする
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            print("SpatialBeaconPlayer: audio format error")
            return
        }
        engine.connect(player, to: environment, format: mono)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)

        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.referenceDistance = Self.sourceDistance
        if #available(iOS 13.0, *) {
            environment.outputType = .headphones
        }
        player.position = AVAudio3DPoint(x: 0, y: 0, z: -Self.sourceDistance)

        monoFormat = mono
        rebuildPings()
        applyRendering()
        isGraphReady = true
    }

    private func applyRendering() {
        switch rendering {
        case .hrtf:
            player.renderingAlgorithm = .HRTFHQ
        case .panning:
            player.renderingAlgorithm = .equalPowerPanning
        }
        if #available(iOS 13.0, *) {
            player.sourceMode = .spatializeIfMono
        }
    }

    /// 今の音の種類で、ふつうの音と「向きが合っている」ときの音を作り直す
    private func rebuildPings() {
        guard let format = monoFormat else { return }
        normalPing = Self.makePing(tone: tone, aligned: false, format: format)
        alignedPing = Self.makePing(tone: tone, aligned: true, format: format)
    }

    /// 音を1つ作る。向きが合っているときの音は、高く短く（雑音パルスは短く）する
    private static func makePing(tone: Tone, aligned: Bool, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        switch tone {
        case .beep:
            // 1つの高さだけの音（正弦波）
            let frequency: Double = aligned ? 2000 : 1000
            return makeBuffer(format: format, duration: aligned ? 0.06 : 0.10) { time in
                sin(2 * Double.pi * frequency * time)
            }
        case .harmonicBeep:
            // 低めの音に、高い倍音を「高いほど小さく」重ねる（のこぎり波に近い音）。
            // 8kHz（またはサンプリング周波数で出せる上限）までの倍音を使う
            let fundamental: Double = aligned ? 1000 : 500
            let upperLimit = min(8000, format.sampleRate / 2 - 1000)
            let harmonicCount = max(1, Int(upperLimit / fundamental))
            return makeBuffer(format: format, duration: aligned ? 0.06 : 0.10) { time in
                var value = 0.0
                for n in 1...harmonicCount {
                    value += sin(2 * Double.pi * fundamental * Double(n) * time) / Double(n)
                }
                return value
            }
        case .noisePulse:
            // 広い高さを含む雑音（白色雑音）
            return makeBuffer(format: format, duration: aligned ? 0.04 : 0.08) { _ in
                Double.random(in: -1...1)
            }
        }
    }

    /// 波形から音を作る。出だしと終わりは短くなめらかにして（プツッという音を防ぐ）、
    /// 種類によって音量がばらつかないよう、平均の大きさ（RMS）をそろえる
    private static func makeBuffer(format: AVAudioFormat,
                                   duration: Double,
                                   waveform: (Double) -> Double) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let sampleRate = format.sampleRate
        let attack = 0.003   // 出だしは鋭く（方向の手がかりになる）
        let release = 0.010
        let count = Int(frameCount)
        var values = [Double](repeating: 0, count: count)
        var sumOfSquares = 0.0
        var peak = 0.0
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let envelope = max(0, min(1.0, time / attack, (duration - time) / release))
            let value = envelope * waveform(time)
            values[index] = value
            sumOfSquares += value * value
            peak = max(peak, abs(value))
        }

        let rms = (sumOfSquares / Double(count)).squareRoot()
        guard rms > 0, peak > 0 else { return nil }
        var scale = targetRMS / rms
        if peak * scale > maxPeak { scale = maxPeak / peak }
        for index in 0..<count {
            samples[index] = Float(values[index] * scale)
        }
        return buffer
    }

    // MARK: - 操作

    func start() {
        guard isGraphReady else { return }
        wantsRunning = true
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !player.isPlaying {
                player.play()
            }
        } catch {
            print("SpatialBeaconPlayer: engine start error:", error)
        }
    }

    func stop() {
        wantsRunning = false
        isSounding = false
        player.stop()
        engine.stop()
    }

    /// 聞き手の正面から見た音源の方向を指定する（右が +、左が −、単位はラジアン）
    func setRelativeBearing(radians: Float) {
        player.position = AVAudio3DPoint(x: sin(radians) * Self.sourceDistance,
                                         y: 0,
                                         z: -cos(radians) * Self.sourceDistance)
    }

    /// 画面の更新ごとに呼ぶ。次の音を鳴らす時刻になっていたら鳴らす
    func tick(now: TimeInterval) {
        guard wantsRunning, isSounding, now >= nextPingAt else { return }
        guard let buffer = usesAlignedPing ? alignedPing : normalPing else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        nextPingAt = now + (usesAlignedPing ? Self.alignedInterval : Self.normalInterval)
    }
}
