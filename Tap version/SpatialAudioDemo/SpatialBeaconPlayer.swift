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
//  音は音声ファイルを使わず、ここで作る。高さのある音だけ（純音）だと方向が分かりにくいので、
//  雑音（広い周波数を含む音）を混ぜている。
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

    /// 音源までの距離[m]。いつもこの距離に置くので、距離による音量の変化は起きない
    static let sourceDistance: Float = 2.0
    /// 音を鳴らす間隔[秒]
    static let normalInterval: TimeInterval = 0.40
    /// 向きが合っているときの間隔[秒]（usesAlignedPing が true のとき）
    static let alignedInterval: TimeInterval = 0.18

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private var normalPing: AVAudioPCMBuffer?
    private var alignedPing: AVAudioPCMBuffer?
    private var nextPingAt: TimeInterval = 0
    private var isGraphReady = false
    private var wantsRunning = false
    private var configurationObserver: NSObjectProtocol?

    var rendering: Rendering = .hrtf {
        didSet { applyRendering() }
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

        normalPing = Self.makePing(format: mono, frequency: 660, duration: 0.12)
        alignedPing = Self.makePing(format: mono, frequency: 1320, duration: 0.08)
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

    /// 短い音を1つ作る：立ち上がりの速い雑音（方向の手がかり）＋ 高さのある音（聞き取りやすさ）
    private static func makePing(format: AVAudioFormat, frequency: Double, duration: Double) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let sampleRate = format.sampleRate
        for index in 0..<Int(frameCount) {
            let time = Double(index) / sampleRate
            let attack = min(1.0, time / 0.003)
            let toneEnvelope = exp(-time / 0.045)
            let noiseEnvelope = exp(-time / 0.020)
            let tone = sin(2 * Double.pi * frequency * time) + 0.5 * sin(2 * Double.pi * frequency * 2 * time)
            let noise = Double.random(in: -1...1)
            samples[index] = Float(attack * (0.30 * toneEnvelope * tone + 0.45 * noiseEnvelope * noise))
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
