//
//  BoundingBoxOverlayView.swift
//  SUWARERU
//
//  検出結果のBBOXをカメラ映像の上に枠で表示する（2Dオーバーレイ）。
//  検証用に、任意の点を小さな丸（マーカー）で重ねて表示できる。
//

import UIKit

final class BoundingBoxOverlayView: UIView {
    struct Marker {
        let point: CGPoint
        let color: UIColor
        /// 同じ位置に重なっても両方見えるよう、マーカーごとに大きさを変えられる
        var radius: CGFloat = 5
    }

    private var drawnLayers: [CAShapeLayer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .clear
        isUserInteractionEnabled = false
    }

    private func addBox(_ rect: CGRect, color: UIColor) {
        let boxLayer = CAShapeLayer()
        boxLayer.frame = rect
        boxLayer.path = UIBezierPath(rect: CGRect(origin: .zero, size: rect.size)).cgPath
        boxLayer.strokeColor = color.cgColor          // 枠線の色
        boxLayer.fillColor   = UIColor.clear.cgColor  // 塗りつぶし無し
        boxLayer.lineWidth   = 2.0
        layer.addSublayer(boxLayer)
        drawnLayers.append(boxLayer)
    }

    /// 既存の表示を全部消して、渡された矩形（UIKit座標・左上原点）の枠とマーカーを描く
    /// - Parameters:
    ///   - rects: 黄色の枠で描く矩形
    ///   - dimmedRects: 灰色の枠で描く矩形（検出はしたが対象外のもの）
    func show(_ rects: [CGRect], dimmedRects: [CGRect] = [], markers: [Marker] = []) {
        for drawn in drawnLayers {
            drawn.removeFromSuperlayer()
        }
        drawnLayers.removeAll()

        for rect in dimmedRects {
            addBox(rect, color: .systemGray)
        }
        for rect in rects {
            addBox(rect, color: .systemYellow)
        }

        // 色と大きさが同じマーカーは1枚のレイヤーにまとめて描く（座面の点は数十個あるため）
        var groups: [(color: UIColor, radius: CGFloat, path: UIBezierPath)] = []
        for marker in markers {
            let r = marker.radius
            let circle = UIBezierPath(ovalIn: CGRect(x: marker.point.x - r, y: marker.point.y - r,
                                                     width: r * 2, height: r * 2))
            if let index = groups.firstIndex(where: { $0.color == marker.color && $0.radius == r }) {
                groups[index].path.append(circle)
            } else {
                groups.append((color: marker.color, radius: r, path: circle))
            }
        }
        for group in groups {
            let markerLayer = CAShapeLayer()
            markerLayer.path = group.path.cgPath
            markerLayer.strokeColor = group.color.cgColor
            markerLayer.fillColor = UIColor.clear.cgColor
            markerLayer.lineWidth = 2.0
            layer.addSublayer(markerLayer)
            drawnLayers.append(markerLayer)
        }
    }
}
