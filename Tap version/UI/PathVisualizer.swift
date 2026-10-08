//
//  PathVisualizer.swift
//  SUWARERU
//
//  デバッグ用：A* の経路をカメラ映像の床の上に表示する（描画スレッドから呼ぶ）。
//   - 黄色の小さい点：経路（0.2m 間隔）
//   - 水色の大きい点：次に向かう点（読み上げ・振動の方向の元）
//   - 緑の点：経路の終点（A* の目的地＝座席の手前）
//  読み上げが「1時方向」と言ったとき、水色の点が実際に右前にあれば左右の符号は正しい。
//

import SceneKit
import UIKit
import simd

final class PathVisualizer {
    /// false にすると何も表示しない（本番で隠したいとき用）
    static var isEnabled = true

    private static let dotSpacing: Float = 0.2
    /// 床に埋もれて見えなくならないよう、少しだけ浮かせる
    private static let heightOffset: Float = 0.02

    private static let pathDot = makeSphere(radius: 0.025, color: .systemYellow)
    private static let steeringDot = makeSphere(radius: 0.06, color: .cyan)
    private static let goalDot = makeSphere(radius: 0.045, color: .systemGreen)

    private let root = SCNNode()

    init(parent: SCNNode) {
        parent.addChildNode(root)
    }

    func update(path: [simd_float3], steeringPoint: simd_float3?) {
        clear()
        guard Self.isEnabled, let goal = path.last else { return }

        for point in Self.dots(along: path) {
            addDot(Self.pathDot, at: point)
        }
        addDot(Self.goalDot, at: goal)
        if let steeringPoint {
            addDot(Self.steeringDot, at: steeringPoint)
        }
    }

    func clear() {
        for child in root.childNodes {
            child.removeFromParentNode()
        }
    }

    private func addDot(_ geometry: SCNGeometry, at point: simd_float3) {
        let node = SCNNode(geometry: geometry)
        node.simdPosition = simd_float3(point.x, point.y + Self.heightOffset, point.z)
        root.addChildNode(node)
    }

    /// 経路の折れ線に沿って dotSpacing ごとの点を返す
    private static func dots(along path: [simd_float3]) -> [simd_float3] {
        guard let first = path.first else { return [] }
        var dots = [first]
        var carried: Float = 0  // 直前の点から、次の区間に持ち越す距離
        for index in 1..<max(1, path.count) {
            let start = path[index - 1]
            let end = path[index]
            let length = simd_length(end - start)
            guard length > 0 else { continue }
            var position = dotSpacing - carried
            while position <= length {
                dots.append(start + (end - start) * (position / length))
                position += dotSpacing
            }
            carried = length - (position - dotSpacing)
        }
        return dots
    }

    private static func makeSphere(radius: CGFloat, color: UIColor) -> SCNSphere {
        let sphere = SCNSphere(radius: radius)
        sphere.firstMaterial?.diffuse.contents = color
        // 照明に左右されず、どこでも同じ色で見えるようにする
        sphere.firstMaterial?.lightingModel = .constant
        return sphere
    }
}
