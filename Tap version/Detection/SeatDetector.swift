//
//  SeatDetector.swift
//  SUWARERU
//
//  YOLO(yolo11n) による person / chair 検出と、「person と重なっていない chair = 空席」の判定。
//

import CoreGraphics
import CoreML
import Foundation
import ImageIO
import Vision

/// 1回の推論結果を画面座標の Detection に変換したもの
struct SeatDetectionResult {
    /// person と重なっていない chair（空席候補）。信頼度の高い順
    let emptyChairs: [Detection]
    /// 同じフレームの person（座面推定で重なる画素を除外するのに使う）
    let persons: [Detection]
    var personCount: Int { persons.count }
}

final class SeatDetector {
    // ======= 検出対象/しきい値 =======
    let allowedLabels: Set<String> = ["person", "chair"]     // ← モデルの identifier に合わせて
    // chair の BBox の面積のうち、person の BBox に覆われている割合がこれ以上なら「occupied」とみなす（仮値・要実測）。
    // 以前の IoU は、座った人の BBox が椅子より大きいと和集合が大きくなって値が小さく出てしまい、
    // 人が座っていても空席と判定することがあった
    let personChairCoverageThreshold: CGFloat = 0.3
    let minConfidence: VNConfidence = 0.80      // 信頼度しきい値

    private let request: VNCoreMLRequest

    init() {
        guard let model = try? VNCoreMLModel(for: yolo11n().model) else {
            fatalError("Could not load CoreML model (yolo11n). Make sure the .mlmodel is added to the target.")
        }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        self.request = request
    }

    /// 推論を同期で実行する。失敗時は nil
    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [VNRecognizedObjectObservation]? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("VNImageRequestHandler error:", error)
            return nil
        }
        return request.results as? [VNRecognizedObjectObservation]
    }

    /// 推論結果を Detection にし、空席の chair と person の数に分ける
    /// - Parameters:
    ///   - orientation: 推論時に Vision に渡した画像の向き
    ///   - displayTransform: 推論に使ったフレームの frame.displayTransform(for:viewportSize:)
    func classify(_ observations: [VNRecognizedObjectObservation],
                  orientation: CGImagePropertyOrientation,
                  displayTransform: CGAffineTransform,
                  viewSize: CGSize,
                  timestamp: TimeInterval) -> SeatDetectionResult {
        var detections: [Detection] = []

        for obs in observations {
            guard let top = obs.labels.first,
                  top.confidence >= minConfidence else { continue }
            guard allowedLabels.contains(top.identifier) else { continue }

            // Vision正規化BBox → 画面座標。aspect-fill による左右の切り取りも displayTransform で反映する
            let bb = obs.boundingBox
            let uiPoint = ImageCoordinates.screenPoint(fromVision: CGPoint(x: bb.midX, y: bb.midY),
                                                       orientation: orientation,
                                                       displayTransform: displayTransform,
                                                       viewportSize: viewSize)
            let uiRect = ImageCoordinates.screenRect(fromVision: bb,
                                                     orientation: orientation,
                                                     displayTransform: displayTransform,
                                                     viewportSize: viewSize)

            detections.append(
                Detection(id: UUID(),
                          label: top.identifier,
                          confidence: top.confidence,
                          normalizedRect: bb,
                          imageOrientation: orientation,
                          screenPoint: uiPoint,
                          screenRect: uiRect,
                          t: timestamp)
            )
        }

        let chairDetections  = detections.filter { $0.label == "chair" }
        let personDetections = detections.filter { $0.label == "person" }

        // person と重なっていない chair だけ「空席」として残す（高信頼順）
        let emptyChairs = chairDetections
            .filter { !isChairOccupied($0, persons: personDetections) }
            .sorted { $0.confidence > $1.confidence }

        return SeatDetectionResult(emptyChairs: emptyChairs, persons: personDetections)
    }

    /// chair のBBOXに person が重なっていたら「埋まっている」とみなす
    private func isChairOccupied(_ chair: Detection, persons: [Detection]) -> Bool {
        for p in persons where p.label == "person" {
            let coverage = BoundingBoxMath.coverage(of: chair.screenRect, by: p.screenRect)
            // chair の BBOX が person にしきい値以上覆われていたら「人が座っている」と判断
            if coverage >= personChairCoverageThreshold {
                return true
            }
        }
        return false
    }
}

enum BoundingBoxMath {
    /// a の面積のうち b に覆われている割合（0〜1）
    static func coverage(of a: CGRect, by b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let area = a.width * a.height
        return area > 0 ? (inter.width * inter.height) / area : 0
    }
}
