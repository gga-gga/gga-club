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

        // 推論・BBoxの画面変換・3D位置の推定は、すべてこの1枚のフレームで行う
        // （以前は3D位置だけ最大0.4秒後の別フレームの深度から求めていた）
        guard let frame = sceneView.session.currentFrame else { return }
        let orientation = ViewController.cgImageOrientationForDevice()
        guard let observations = seatDetector.detect(in: frame.capturedImage, orientation: orientation) else { return }
        handleDetectionResults(observations, orientation: orientation, frame: frame)
    }

    // MARK: - Detection results
    func handleDetectionResults(_ objects: [VNRecognizedObjectObservation],
                                orientation: CGImagePropertyOrientation,
                                frame: ARFrame) {
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
        let viewportSize = viewSize
        let orientationForDisplay = displayOrientation
        let displayTransform = frame.displayTransform(for: orientationForDisplay, viewportSize: viewportSize)
        let result = seatDetector.classify(objects,
                                           orientation: orientation,
                                           displayTransform: displayTransform,
                                           viewSize: viewportSize,
                                           timestamp: now)
        // 空席候補だけ、同じフレームの深度から3D位置を求めておく
        let emptyChairs = result.emptyChairs.map { chair -> Detection in
            var chair = chair
            chair.placement = WorldPositionEstimator.estimatePlacement(for: chair,
                                                                       frame: frame,
                                                                       interfaceOrientation: orientationForDisplay,
                                                                       viewportSize: viewportSize)
            return chair
        }

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

        // デバッグ表示：信頼度、3D位置の再投影誤差[pt]、水平距離
        let lines = emptyChairs.prefix(2).map { det -> String in
            let head = "\(det.label) - \(Int(det.confidence * 100))%"
            guard let placement = det.placement else { return "\(head) | 位置なし" }
            let error = String(format: "%.0f", placement.reprojectionError)
            let distance = String(format: "%.2f", placement.horizontalDistance)
            return "\(head) | 誤差 \(error)pt | \(distance)m"
        }.joined(separator: "\n")
        // 緑＝深度を読んだ点、赤＝求めた3D位置を投影し直した点（正しければ重なる）
        let markers = emptyChairs.compactMap { $0.placement }.flatMap { placement in
            [BoundingBoxOverlayView.Marker(point: placement.expectedScreenPoint, color: .systemGreen),
             BoundingBoxOverlayView.Marker(point: placement.reprojectedScreenPoint, color: .systemRed)]
        }
        DispatchQueue.main.async {
            self.debugTextView.text = lines
            // このフレームで検出した BBOX を画面に反映
            self.bboxOverlay.show(emptyChairs.map { $0.screenRect }, markers: markers)
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
