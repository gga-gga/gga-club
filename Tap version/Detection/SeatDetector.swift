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
    let personCount: Int
}

final class SeatDetector {
    // ======= 検出対象/しきい値 =======
    let allowedLabels: Set<String> = ["person", "chair"]     // ← モデルの identifier に合わせて
    // person が chair にどのくらい重なっていたら「occupied」とみなすか
    // ※既知の問題：IoU は座った人のBBoxが椅子より大きいと小さく出る（段階3で IoA に変更予定）
    let personChairIoUThreshold: CGFloat = 0.15   // 好みに応じて 0.2〜0.4 あたりで調整
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

    /// 推論結果を画面座標の Detection にし、空席の chair と person の数に分ける
    func classify(_ observations: [VNRecognizedObjectObservation],
                  viewSize: CGSize,
                  timestamp: TimeInterval) -> SeatDetectionResult {
        let W = viewSize.width, H = viewSize.height
        var detections: [Detection] = []

        for obs in observations {
            guard let top = obs.labels.first,
                  top.confidence >= minConfidence else { continue }
            guard allowedLabels.contains(top.identifier) else { continue }

            // Vision正規化BBox(左下原点) → UIKit座標(左上原点)
            // ※既知の問題：ARSCNView の aspect-fill による左右の切り取りを考慮していない（段階1で修正予定）
            let bb = obs.boundingBox
            let centerNorm = CGPoint(x: bb.midX, y: bb.midY)
            let uiPoint = CGPoint(x: centerNorm.x * W,
                                  y: (1.0 - centerNorm.y) * H)
            let uiRect = CGRect(x: bb.minX * W,
                                y: (1.0 - bb.maxY) * H,
                                width: bb.width * W,
                                height: bb.height * H)

            detections.append(
                Detection(id: UUID(),
                          label: top.identifier,
                          confidence: top.confidence,
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

        return SeatDetectionResult(emptyChairs: emptyChairs, personCount: personDetections.count)
    }

    /// chair のBBOXに person が重なっていたら「埋まっている」とみなす
    private func isChairOccupied(_ chair: Detection, persons: [Detection]) -> Bool {
        for p in persons where p.label == "person" {
            let overlap = BoundingBoxMath.iou(chair.screenRect, p.screenRect)
            // chair と person の BBOX の IoU がしきい値以上なら「人が座っている」と判断
            if overlap >= personChairIoUThreshold {
                return true
            }
        }
        return false
    }
}

enum BoundingBoxMath {
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
