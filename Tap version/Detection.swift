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
import SceneKit
import simd

struct Detection {
    let id: UUID
    let label: String
    let confidence: Float
    let screenPoint: CGPoint   // 画面中心（UIKit座標）
    let screenRect: CGRect     // 画面上BBox（UIKit座標）
    let t: TimeInterval
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
    var depthMeters: Float
    var centerAngleDeg: Float?
    var arrivalAnnounced: Bool = false
}
