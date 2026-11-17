//
//  PathVisualizer.swift
//  SUWARERU
//
//  デバッグ用：A* の経路をカメラ映像の床の少し上（膝くらいの高さ）に表示する（描画スレッドから呼ぶ）。
//   - 赤い線と矢印：経路（矢印は 0.5m ごとに進む向きを指す）
//   - 水色の大きい点：次に向かう点（読み上げ・振動の方向の元）
//   - 緑の点：経路の終点（A* の目的地＝座席の手前）
//   - 細い縦線：矢印・水色の点・緑の点から床まで下ろした線（経路がどの床の上を通るかを示す。
//     線の下端が実際の床に付いていなければ、床の高さの推定がずれている）
//  読み上げが「1時方向」と言ったとき、水色の点が実際に右前にあれば左右の符号は正しい。
//

import SceneKit
import UIKit
import simd

final class PathVisualizer {
    /// false にすると何も表示しない（本番で隠したいとき用）
    static var isEnabled = true

    private static let pathColor = UIColor(red: 1.0, green: 0.0, blue: 0.1, alpha: 1.0)
    private static let lineRadius: CGFloat = 0.012
    /// 床まで下ろす縦線（経路の線より細く、半透明にして目立ちすぎないようにする）
    private static let dropLineRadius: CGFloat = 0.004
    private static let dropLineColor = UIColor(red: 1.0, green: 0.0, blue: 0.1, alpha: 0.5)
    private static let arrowSpacing: Float = 0.5
    /// 経路を床からどれだけ浮かせて描くか[m]。
    /// 胸の高さのカメラからは足元〜約1.5m先の床が映らないので、少し浮かせて近くの経路も見えるようにする。
    /// 以前 0.9m（腰の高さ）にしたときは床から離れすぎて分かりにくかったため、膝くらいの高さにしている。
    /// 0.03 にすると床の上に戻る
    private static let heightOffset: Float = 0.3

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

    func update(path: [simd_float3], steeringPoint: simd_float3?) {
        clear()
        guard Self.isEnabled, let goal = path.last else { return }
        let lifted = path.map { simd_float3($0.x, $0.y + Self.heightOffset, $0.z) }

        // 経路の線
        for index in 1..<max(1, lifted.count) {
            if let segment = Self.segmentNode(from: lifted[index - 1], to: lifted[index],
                                              radius: Self.lineRadius, color: Self.pathColor) {
                root.addChildNode(segment)
            }
        }
        // 進む向きの矢印と、そこから床への縦線
        for (position, direction) in Self.arrowPlacements(along: lifted) {
            let node = SCNNode(geometry: Self.arrowHead)
            node.simdPosition = position
            node.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: direction)
            root.addChildNode(node)
            addDropLine(from: position)
        }

        let goalMarker = simd_float3(goal.x, goal.y + Self.heightOffset, goal.z)
        addDot(Self.goalDot, at: goalMarker)
        addDropLine(from: goalMarker)
        if let steeringPoint {
            let steeringMarker = simd_float3(steeringPoint.x, steeringPoint.y + Self.heightOffset, steeringPoint.z)
            addDot(Self.steeringDot, at: steeringMarker)
            addDropLine(from: steeringMarker)
        }
    }

    /// 浮かせた印から真下の床（heightOffset だけ下）まで細い縦線を引く
    private func addDropLine(from marker: simd_float3) {
        let floorPoint = simd_float3(marker.x, marker.y - Self.heightOffset, marker.z)
        if let line = Self.segmentNode(from: marker, to: floorPoint,
                                       radius: Self.dropLineRadius, color: Self.dropLineColor) {
            root.addChildNode(line)
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
