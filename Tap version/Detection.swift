//
//  Detection.swift
//  SUWARERU
//
//  Created by Sugitani on 2026/01/15.
//
//  検出（Detection）とトラック（Track）のデータ構造。
//  以前は ViewController 内にも同名のネスト型があり二重定義になっていたため、ここに一本化した。
//

import CoreGraphics
import Foundation
import ImageIO
import SceneKit
import simd

struct Detection {
    let id: UUID
    let label: String
    let confidence: Float
    /// Vision の正規化BBox（推論に渡した向きの画像基準・左下原点）
    let normalizedRect: CGRect
    /// 推論時に Vision に渡した画像の向き
    let imageOrientation: CGImagePropertyOrientation
    let screenPoint: CGPoint   // 画面中心（UIKit座標）
    let screenRect: CGRect     // 画面上BBox（UIKit座標）
    let t: TimeInterval
    /// 推論に使ったのと同じフレームの深度から求めた座面の推定結果（空席候補のみ。未計算なら nil）
    var localization: SeatLocalization? = nil

    /// 座面の3D位置（推定できていなければ nil）
    var placement: SeatPlacement? {
        if case .located(let placement)? = localization { return placement }
        return nil
    }
}

struct Track {
    var id: UUID
    var label: String
    var node: SCNNode
    var lastScreenPoint: CGPoint
    var lastScreenRect: CGRect
    var worldTransform: simd_float4x4
    var lastSeen: TimeInterval
    var createdAt: TimeInterval
    var confidence: Float
    /// 作成時のカメラからの水平距離[m]
    var depthMeters: Float
    var centerAngleDeg: Float?
    var arrivalAnnounced: Bool = false
}
