//
//  ViewController+Detection.swift
//  SUWARERU
//
//  推論ループ（mlInterval ごとに SeatDetector を呼ぶ）と、結果を画面状態へ反映する処理。
//

import ARKit
import UIKit
import Vision

extension ViewController {
    // MARK: - Vision Loop
    func startCoreMLLoopIfNeeded() {
        guard !isMLLoopRunning else { return }
        isMLLoopRunning = true
        scheduleNextCoreMLUpdate()
    }

    func scheduleNextCoreMLUpdate() {
        dispatchQueueML.asyncAfter(deadline: .now() + mlInterval) { [weak self] in
            guard let self = self, self.isMLLoopRunning else { return }
            self.updateCoreML()
            self.scheduleNextCoreMLUpdate()
        }
    }

    func updateCoreML() {
        let now = CACurrentMediaTime()
        if now - lastMLTime < mlInterval {
            return
        }
        lastMLTime = now

        guard let pb = sceneView.session.currentFrame?.capturedImage else { return }
        let orientation = ViewController.cgImageOrientationForDevice()
        guard let observations = seatDetector.detect(in: pb, orientation: orientation) else { return }
        handleDetectionResults(observations)
    }

    // MARK: - Detection results
    func handleDetectionResults(_ objects: [VNRecognizedObjectObservation]) {
        if objects.isEmpty {
            stateQueue.sync {
                self.lastEmptySeatCount = 0
                self.lastPersonCount = 0
                if self.isSituationCheckInProgress {
                    self.situationTally.record(emptySeatCount: 0, personCount: 0)
                }
                self.pendingDetections.removeAll()
            }
            DispatchQueue.main.async { [weak self] in
                self?.debugTextView.text = ""
                self?.bboxOverlay.show([])
            }
            return
        }
        // viewSize が 0 の場合はメインスレッドで拾ってから続行
        if viewSize.width <= 0 || viewSize.height <= 0 {
            DispatchQueue.main.async {
                self.viewSize = self.sceneView.bounds.size
            }
            return
        }

        let now = CACurrentMediaTime()
        let result = seatDetector.classify(objects, viewSize: viewSize, timestamp: now)
        let emptyChairs = result.emptyChairs

        stateQueue.sync {
            self.lastEmptySeatCount = emptyChairs.count
            self.lastPersonCount = result.personCount
            if self.isSituationCheckInProgress {
                self.situationTally.record(emptySeatCount: emptyChairs.count,
                                           personCount: result.personCount)
            }
        }

        // person は今回はトラッキングに使わないので pendingDetections には積まない
        guard !emptyChairs.isEmpty else {
            // 検出が無いときはBBOXを全部消す
            DispatchQueue.main.async { [weak self] in
                self?.bboxOverlay.show([])
            }
            return
        }

        // 古い検出を掃除し、高信頼順で積む（emptyChairs は高信頼順に並んでいる）
        let cutoff = now - 0.5
        stateQueue.sync {
            self.pendingDetections.removeAll(where: { $0.t < cutoff })
            self.pendingDetections.append(contentsOf: emptyChairs)
        }

        // デバッグ表示
        let lines = emptyChairs.prefix(2).map { "\($0.label) - \(Int($0.confidence * 100))%" }.joined(separator: "\n")
        DispatchQueue.main.async {
            self.debugTextView.text = lines
            // このフレームで検出した BBOX を画面に反映
            self.bboxOverlay.show(emptyChairs.map { $0.screenRect })
        }
    }

    static func cgImageOrientationForDevice() -> CGImagePropertyOrientation {
        switch UIDevice.current.orientation {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .up
        case .landscapeRight: return .down
        default:
            let o = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.interfaceOrientation
            switch o {
            case .portrait: return .right
            case .portraitUpsideDown: return .left
            case .landscapeLeft: return .up
            case .landscapeRight: return .down
            default: return .right
            }
        }
    }
}
