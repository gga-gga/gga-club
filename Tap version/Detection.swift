//
//  Detection.swift
//  SUWARERU
//
//  Created by Sugitani on 2026/01/15.
//  Copyright © 2026 CompanyName. All rights reserved.
//


//
//  TrackingModels.swift
//  SUWARERU
//
//  Created by Sugitani on 2026/01/15.
//

import CoreGraphics
import Foundation
import SceneKit

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
