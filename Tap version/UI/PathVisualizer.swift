//
//  PathVisualizer.swift
//  SUWARERU
//
//  デバッグ用：A* の経路をカメラ映像に重ねて表示する（描画スレッドから呼ぶ）。
//   - 赤い線と矢印：経路（矢印は 0.5m ごとに進む向きを指す）
//   - 水色の大きい点：次に向かう点（読み上げ・振動の方向の元）
//   - 緑の点：経路の終点（A* の目的地＝座席の手前）
//   - 細い縦線：上の印から床まで下ろした線（どの床の上を通るかを示す）
//
//  経路は床から 0.9m（腰の高さ）に浮かせて描く。胸の高さのカメラからは足元〜約1.5m先の床が
//  映らないため、床の上に描くと自分の近くの経路（曲がり始めなど）が画面の外になってしまう。
//  浮かせると約0.4m先から見える。縦線の下端で、床の高さの推定がずれていないかも確認できる。
//
//  読み上げが「1時方向」と言ったとき、水色の点が実際に右前にあれば左右の符号は正しい。
//

import SceneKit
import UIKit
import simd

final class PathVisualizer {
    /// false にすると何も表示しない（本番で隠したいとき用）
    static var isEnabled = true

    /// 経路を描く高さ（床からの高さ[m]）
    private static let heightAboveFloor: Float = 0.9
    private static let arrowSpacing: Float = 0.5

    private static let pathColor = UIColor(red: 1.0, green: 0.0, blue: 0.1, alpha: 1.0)
    private static let lineRadius: CGFloat = 0.012
    private static let dropLineRadius: CGFloat = 0.004
    private static let dropLineColor = UIColor(red: 1.0, green: 0.0, blue: 0.1, alpha: 0.5)

    /// 矢印の頭（円すい。頂点が +Y を向いているので、進む向きへ回して使う）
    private static let arrowHead: SCNCone = {
        let cone = SCNCone(topRadius: 0, bottomRadius: 0.05, height: 0.12)
        applyMaterial(to: cone, color: pathColor)
        return cone
    }()
    private static let steeringDot = makeSphere(radius: 0.06, color: .cyan)
    private static let goalDot = makeSphere(radius: 0.045, color: .systemGreen)

    private let root = SCNNode()

    init(parent: SCNNode) {
        parent.addChildNode(root)
    }

    /// - Parameter path: A* の経路（各点の y は床の高さ）
    func update(path: [simd_float3], steeringPoint: simd_float3?) {
        clear()
        guard Self.isEnabled, let goal = path.last else { return }
        let lifted = path.map(Self.lift)

        // 経路の線
        for index in 1..<max(1, lifted.count) {
            if let segment = Self.segmentNode(from: lifted[index - 1], to: lifted[index],
                                              radius: Self.lineRadius, color: Self.pathColor) {
                root.addChildNode(segment)
            }
        }
        // 進む向きの矢印と、その位置から床への縦線
        for (position, direction) in Self.arrowPlacements(along: lifted) {
            let node = SCNNode(geometry: Self.arrowHead)
            node.simdPosition = position
            node.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: direction)
            root.addChildNode(node)
            addDropLine(from: position)
        }

        let liftedGoal = Self.lift(goal)
        addDot(Self.goalDot, at: liftedGoal)
        addDropLine(from: liftedGoal)
        if let steeringPoint {
            // 操舵点は経路上の点なので、y は床の高さ
            let liftedSteering = Self.lift(steeringPoint)
            addDot(Self.steeringDot, at: liftedSteering)
            addDropLine(from: liftedSteering)
        }
    }

    func clear() {
        for child in root.childNodes {
            child.removeFromParentNode()
        }
    }

    private func addDot(_ geometry: SCNGeometry, at point: simd_float3) {
        let node = SCNNode(geometry: geometry)
        node.simdPosition = point
        root.addChildNode(node)
    }

    /// 浮かせた点から床までの細い縦線
    private func addDropLine(from liftedPoint: simd_float3) {
        let floorPoint = simd_float3(liftedPoint.x, liftedPoint.y - Self.heightAboveFloor, liftedPoint.z)
        if let line = Self.segmentNode(from: floorPoint, to: liftedPoint,
                                       radius: Self.dropLineRadius, color: Self.dropLineColor) {
            root.addChildNode(line)
        }
    }

    /// 床の高さの点を、表示する高さへ持ち上げる
    private static func lift(_ point: simd_float3) -> simd_float3 {
        simd_float3(point.x, point.y + heightAboveFloor, point.z)
    }

    /// 2点を結ぶ細い円柱（SCNCylinder の軸は +Y なので、2点を結ぶ向きへ回す）
    private static func segmentNode(from start: simd_float3, to end: simd_float3,
                                    radius: CGFloat, color: UIColor) -> SCNNode? {
        let vector = end - start
        let length = simd_length(vector)
        guard length > 1e-4 else { return nil }

        let cylinder = SCNCylinder(radius: radius, height: CGFloat(length))
        applyMaterial(to: cylinder, color: color)
        let node = SCNNode(geometry: cylinder)
        node.simdPosition = (start + end) / 2
        node.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: vector / length)
        return node
    }

    /// 経路に沿って arrowSpacing ごとの位置と、その位置での進む向き（正規化済み）
    private static func arrowPlacements(along path: [simd_float3]) -> [(simd_float3, simd_float3)] {
        var placements: [(simd_float3, simd_float3)] = []
        var carried: Float = 0  // 直前の矢印から、次の区間に持ち越す距離
        for index in 1..<max(1, path.count) {
            let start = path[index - 1]
            let end = path[index]
            let length = simd_length(end - start)
            guard length > 1e-4 else { continue }
            let direction = (end - start) / length
            var position = arrowSpacing - carried
            while position <= length {
                placements.append((start + direction * position, direction))
                position += arrowSpacing
            }
            carried = length - (position - arrowSpacing)
        }
        return placements
    }

    private static func makeSphere(radius: CGFloat, color: UIColor) -> SCNSphere {
        let sphere = SCNSphere(radius: radius)
        applyMaterial(to: sphere, color: color)
        return sphere
    }

    /// 照明に左右されず、どこでも同じ鮮やかな色で見えるようにする
    private static func applyMaterial(to geometry: SCNGeometry, color: UIColor) {
        geometry.firstMaterial?.diffuse.contents = color
        geometry.firstMaterial?.lightingModel = .constant
    }
}
