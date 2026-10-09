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
        // 空席候補だけ、同じフレームの深度から座面の3D位置を求めておく
        let floorY = stateQueue.sync { self.latestFloorY }
        let emptyChairs = result.emptyChairs.map { chair -> Detection in
            var chair = chair
            chair.localization = WorldPositionEstimator.estimatePlacement(for: chair,
                                                                          persons: result.persons,
                                                                          floorY: floorY,
                                                                          frame: frame,
                                                                          interfaceOrientation: orientationForDisplay,
                                                                          viewportSize: viewportSize)
            return chair
        }

        // 空席候補は「座面を確認できた椅子」だけ。人と重なっていなくても、座面が見えない
        // （荷物が置かれている・遠すぎる・床が未推定など）椅子は空席として数えない
        let seatCandidates = emptyChairs.filter { $0.placement != nil }

        // 座席トラックへの取り込みも同じフレームで行う（座面に人が重なったかの判定に、
        // このフレームの person の BBox が必要なため）。空席が無くても person の観測は取り込む
        let seatPositions = seatCandidates.compactMap { $0.placement?.worldPosition }
        let personRects = result.persons.map { $0.screenRect }
        stateQueue.sync {
            self.lastEmptySeatCount = seatCandidates.count
            self.lastPersonCount = result.personCount
            if self.isSituationCheckInProgress {
                self.situationTally.record(emptySeatCount: seatCandidates.count,
                                           personCount: result.personCount)
            }
            self.seatTracker.integrate(seatPositions: seatPositions,
                                       personRects: personRects,
                                       label: "chair",
                                       frame: frame,
                                       interfaceOrientation: orientationForDisplay,
                                       viewportSize: viewportSize,
                                       now: now)
        }

        guard !emptyChairs.isEmpty else {
            // 検出が無いときはBBOXを全部消す
            DispatchQueue.main.async { [weak self] in
                self?.debugTextView.text = ""
                self?.bboxOverlay.show([])
            }
            return
        }

        // デバッグ表示：信頼度、座面の点の数・広がり・水平距離、または推定できなかった理由
        let lines = emptyChairs.prefix(2).map { det -> String in
            let head = "\(det.label) - \(Int(det.confidence * 100))%"
            switch det.localization {
            case .located(let placement)?:
                let spread = String(format: "幅%.2f 奥%.2f", placement.lateralExtent, placement.depthExtent)
                let distance = String(format: "%.2f", placement.horizontalDistance)
                return "\(head) | 座面\(placement.surfacePointCount)点 \(spread) | \(distance)m"
            case .failed(let failure)?:
                return "\(head) | ✕\(failure.debugText)"
            case nil:
                return head
            }
        }.joined(separator: "\n")
        // 緑の小さい点＝座面と判定した点（間引き済み）、赤の輪＝推定した座面の中心
        // （正しければ緑は座面の上だけに乗り、赤はその中央に来る）
        let markers = emptyChairs.compactMap { $0.placement }.flatMap { placement -> [BoundingBoxOverlayView.Marker] in
            placement.surfaceScreenPoints.map {
                BoundingBoxOverlayView.Marker(point: $0, color: .systemGreen, radius: 2)
            } + [BoundingBoxOverlayView.Marker(point: placement.centerScreenPoint, color: .systemRed, radius: 8)]
        }
        // 黄色の枠＝空席候補（座面を確認できた）、灰色の枠＝人とは重なっていないが座面を確認できない
        let candidateRects = seatCandidates.map { $0.screenRect }
        let unconfirmedRects = emptyChairs.filter { $0.placement == nil }.map { $0.screenRect }
        DispatchQueue.main.async {
            self.debugTextView.text = lines
            // このフレームで検出した BBOX を画面に反映
            self.bboxOverlay.show(candidateRects, dimmedRects: unconfirmedRects, markers: markers)
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
