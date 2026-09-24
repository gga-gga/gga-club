//
//  BoundingBoxOverlayView.swift
//  SUWARERU
//
//  検出結果のBBOXをカメラ映像の上に枠で表示する（2Dオーバーレイ）。
//

import UIKit

final class BoundingBoxOverlayView: UIView {
    private var boxLayers: [CAShapeLayer] = []

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

    /// 既存の枠を全部消して、渡された矩形（UIKit座標・左上原点）の枠を描く
    func show(_ rects: [CGRect]) {
        for layer in boxLayers {
            layer.removeFromSuperlayer()
        }
        boxLayers.removeAll()

        for rect in rects {
            let boxLayer = CAShapeLayer()
            boxLayer.frame = rect
            boxLayer.path = UIBezierPath(rect: CGRect(origin: .zero, size: rect.size)).cgPath

            boxLayer.strokeColor = UIColor.systemYellow.cgColor   // 枠線の色
            boxLayer.fillColor   = UIColor.clear.cgColor          // 塗りつぶし無し
            boxLayer.lineWidth   = 2.0
            layer.addSublayer(boxLayer)
            boxLayers.append(boxLayer)
        }
    }
}
