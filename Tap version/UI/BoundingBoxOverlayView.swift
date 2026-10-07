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

    /// 既存の表示を全部消して、渡された矩形（UIKit座標・左上原点）の枠とマーカーを描く
    func show(_ rects: [CGRect], markers: [Marker] = []) {
        for drawn in drawnLayers {
            drawn.removeFromSuperlayer()
        }
        drawnLayers.removeAll()

        for rect in rects {
            let boxLayer = CAShapeLayer()
            boxLayer.frame = rect
            boxLayer.path = UIBezierPath(rect: CGRect(origin: .zero, size: rect.size)).cgPath

            boxLayer.strokeColor = UIColor.systemYellow.cgColor   // 枠線の色
            boxLayer.fillColor   = UIColor.clear.cgColor          // 塗りつぶし無し
            boxLayer.lineWidth   = 2.0
            layer.addSublayer(boxLayer)
            drawnLayers.append(boxLayer)
        }

        for marker in markers {
            let markerLayer = CAShapeLayer()
            let r = marker.radius
            let circle = CGRect(x: marker.point.x - r, y: marker.point.y - r, width: r * 2, height: r * 2)
            markerLayer.path = UIBezierPath(ovalIn: circle).cgPath
            markerLayer.strokeColor = marker.color.cgColor
            markerLayer.fillColor = UIColor.clear.cgColor
            markerLayer.lineWidth = 2.0
            layer.addSublayer(markerLayer)
            drawnLayers.append(markerLayer)
        }
    }
}
