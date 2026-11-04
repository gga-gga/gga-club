//
//  OGMMapView.swift
//  SUWARERU
//
//  デバッグ用：占有格子地図（OGM）を上から見た2D地図として描く。誘導画面の「OGM」ボタンで
//  カメラ映像と切り替える。AStarDebugger の OGMDebugMapView を移植したもの（タップでの目標指定と
//  コスト表示は省き、座席のトラックと次に向かう点を加えた）。
//
//   - セル：黒＝占有、白＝空き、灰＝未観測
//   - 点：緑＝walkable、赤＝non-walkable と判定した直近の点群（床の誤判定の調査用）
//   - 赤い線：A* の経路、水色の点：次に向かう点、緑の点：経路の終点
//   - 丸：座席（オレンジ＝案内先、白＝その他の空席、灰＝埋まっている席）
//   - 青い三角：自分の位置と向き
//
//  表示は「投影の基底ベクトル（前方・右）」を差し替えるだけで2モードを表現する：
//   - 進行方向が上（既定）：基底＝カメラの前方/右。地図が回る
//   - 北が上：基底＝北(-Z)固定。地図は回らず、自分の三角だけが回る
//  長押しで切り替える。
//

import UIKit
import simd

final class OGMMapView: UIView {
    struct CameraPose {
        let forwardXZ: simd_float2 // 正規化済み
        let positionXZ: simd_float2
    }

    struct SeatMarker {
        enum Kind { case target, empty, occupied }
        let positionXZ: simd_float2
        let kind: Kind
    }

    /// 1回の描画に使うデータ一式（描画スレッドで作り、メインスレッドで渡す）
    struct Snapshot {
        var cells: [GridCoordinate: CellState] = [:]
        var cellSize: Float = OGMConfig.cellSize
        var cameraPose: CameraPose?
        var rawPoints: [ClassifiedPoint] = []
        var path: [simd_float3] = []
        var steeringPoint: simd_float3?
        var seats: [SeatMarker] = []
    }

    /// 1メートルが何ポイントに相当するか（大きいほどズームイン）
    var pointsPerMeter: CGFloat = 40

    /// true=進行方向が上（地図が回る）／false=北が上
    var rotatesWithCamera = true {
        didSet { setNeedsDisplay() }
    }

    /// 生の点群（walkable/non-walkable）を描くか
    var showsRawPoints = true

    private static let occupiedColor = UIColor.black
    private static let freeColor = UIColor.white
    private static let unknownColor = UIColor.systemGray
    private static let pathColor = UIColor(red: 1.0, green: 0.0, blue: 0.1, alpha: 1.0)

    private var snapshot = Snapshot()

    /// 自分の位置を画面のどこに置くか。進行方向が上のときは前方を広く見せたいので下寄りにする
    private var anchorFraction: CGPoint {
        rotatesWithCamera ? CGPoint(x: 0.5, y: 0.72) : CGPoint(x: 0.5, y: 0.5)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = Self.unknownColor
        isOpaque = true
        isUserInteractionEnabled = true
        addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:))))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        rotatesWithCamera.toggle()
    }

    func update(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        setNeedsDisplay()
    }

    // MARK: - 投影の基底

    /// 画面の「上」に対応させるワールド方向。進行方向が上ならカメラ前方、北が上なら -Z。
    private func basisForward(for pose: CameraPose) -> simd_float2 {
        rotatesWithCamera ? pose.forwardXZ : simd_float2(0, -1)
    }

    /// 画面の「右」に対応させるワールド方向。forward=(fx,fz) の水平右は cross(forward, up) = (-fz, fx)
    private func basisRight(for pose: CameraPose) -> simd_float2 {
        let forward = basisForward(for: pose)
        return simd_float2(-forward.y, forward.x)
    }

    /// ワールド座標(X,Z) → 画面座標。基底へ射影してから画面へ写す
    private func worldToScreen(_ worldXZ: simd_float2, anchor: CGPoint, pose: CameraPose) -> CGPoint {
        let relative = worldXZ - pose.positionXZ
        let forwardComponent = simd_dot(relative, basisForward(for: pose))
        let rightComponent = simd_dot(relative, basisRight(for: pose))
        return CGPoint(x: anchor.x + CGFloat(rightComponent) * pointsPerMeter,
                       y: anchor.y - CGFloat(forwardComponent) * pointsPerMeter)
    }

    /// worldToScreen の逆変換（描画範囲の算出に使う）
    private func screenToWorld(_ point: CGPoint, anchor: CGPoint, pose: CameraPose) -> simd_float2 {
        let rightComponent = Float((point.x - anchor.x) / pointsPerMeter)
        let forwardComponent = Float((anchor.y - point.y) / pointsPerMeter)
        return pose.positionXZ
            + basisForward(for: pose) * forwardComponent
            + basisRight(for: pose) * rightComponent
    }

    // MARK: - 描画

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let pose = snapshot.cameraPose else { return }

        let anchor = CGPoint(x: rect.width * anchorFraction.x, y: rect.height * anchorFraction.y)
        let visibleRect = rect.insetBy(dx: -32, dy: -32)
        let cellSize = snapshot.cellSize

        if let gridRange = gridRange(for: visibleRect, anchor: anchor, pose: pose, cellSize: cellSize) {
            // セルは地図と一緒に回す。各セルは「中心 ± 2本の半辺ベクトル」の四角形として描く
            // （投影は線形なので半辺ベクトルは全セル共通）
            let halfCellMeters = cellSize / 2
            let right = basisRight(for: pose)
            let forward = basisForward(for: pose)
            // 隣接セルの境目に背景色の細い線が出ないよう、0.5ptだけ重ねて描く
            let halfCellPt = CGFloat(halfCellMeters) * pointsPerMeter
            let overlap = (halfCellPt + 0.5) / halfCellPt
            let halfEdgeX = CGPoint(x: CGFloat(halfCellMeters * right.x) * pointsPerMeter * overlap,
                                    y: -CGFloat(halfCellMeters * forward.x) * pointsPerMeter * overlap)
            let halfEdgeZ = CGPoint(x: CGFloat(halfCellMeters * right.y) * pointsPerMeter * overlap,
                                    y: -CGFloat(halfCellMeters * forward.y) * pointsPerMeter * overlap)

            for gz in gridRange.minZ...gridRange.maxZ {
                for gx in gridRange.minX...gridRange.maxX {
                    let coord = GridCoordinate(x: gx, z: gz)
                    guard let state = snapshot.cells[coord] else { continue } // 未観測は背景の灰色のまま
                    let center = simd_float2((Float(gx) + 0.5) * cellSize, (Float(gz) + 0.5) * cellSize)
                    let c = worldToScreen(center, anchor: anchor, pose: pose)
                    guard visibleRect.contains(c) else { continue }

                    ctx.setFillColor((state.isOccupied ? Self.occupiedColor : Self.freeColor).cgColor)
                    ctx.move(to: CGPoint(x: c.x + halfEdgeX.x + halfEdgeZ.x, y: c.y + halfEdgeX.y + halfEdgeZ.y))
                    ctx.addLine(to: CGPoint(x: c.x + halfEdgeX.x - halfEdgeZ.x, y: c.y + halfEdgeX.y - halfEdgeZ.y))
                    ctx.addLine(to: CGPoint(x: c.x - halfEdgeX.x - halfEdgeZ.x, y: c.y - halfEdgeX.y - halfEdgeZ.y))
                    ctx.addLine(to: CGPoint(x: c.x - halfEdgeX.x + halfEdgeZ.x, y: c.y - halfEdgeX.y + halfEdgeZ.y))
                    ctx.closePath()
                    ctx.fillPath()
                }
            }
        }

        if showsRawPoints {
            drawRawPoints(in: ctx, anchor: anchor, visibleRect: visibleRect, pose: pose)
        }
        drawPath(in: ctx, anchor: anchor, pose: pose)
        drawSeats(in: ctx, anchor: anchor, pose: pose)
        drawSelfMarker(in: ctx, at: anchor, pose: pose)
        drawScaleBar(in: ctx, rect: rect)
    }

    private func screenPoint(_ world: simd_float3, anchor: CGPoint, pose: CameraPose) -> CGPoint {
        worldToScreen(simd_float2(world.x, world.z), anchor: anchor, pose: pose)
    }

    /// 直近に分類した点群：walkable=緑 / non-walkable=赤
    private func drawRawPoints(in ctx: CGContext, anchor: CGPoint, visibleRect: CGRect, pose: CameraPose) {
        let dotRadius: CGFloat = 2.0
        for point in snapshot.rawPoints {
            let p = screenPoint(point.worldPosition, anchor: anchor, pose: pose)
            guard visibleRect.contains(p) else { continue }
            let color: UIColor = point.walkability == .walkable ? .systemGreen : .systemRed
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
        }
    }

    /// A* の経路（赤い線）、次に向かう点（水色）、終点（緑）。AR 表示と同じ色
    private func drawPath(in ctx: CGContext, anchor: CGPoint, pose: CameraPose) {
        let path = snapshot.path
        if path.count >= 2 {
            ctx.setStrokeColor(Self.pathColor.cgColor)
            ctx.setLineWidth(3)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: screenPoint(path[0], anchor: anchor, pose: pose))
            for waypoint in path.dropFirst() {
                ctx.addLine(to: screenPoint(waypoint, anchor: anchor, pose: pose))
            }
            ctx.strokePath()
        }
        if let goal = path.last {
            fillCircle(ctx, at: screenPoint(goal, anchor: anchor, pose: pose), radius: 5, color: .systemGreen)
        }
        if let steering = snapshot.steeringPoint {
            fillCircle(ctx, at: screenPoint(steering, anchor: anchor, pose: pose), radius: 6, color: .cyan)
        }
    }

    /// 座席：オレンジ＝案内先、白＝その他の空席、灰＝埋まっている席
    private func drawSeats(in ctx: CGContext, anchor: CGPoint, pose: CameraPose) {
        for seat in snapshot.seats {
            let color: UIColor
            switch seat.kind {
            case .target: color = .orange
            case .empty: color = .white
            case .occupied: color = .darkGray
            }
            let p = worldToScreen(seat.positionXZ, anchor: anchor, pose: pose)
            fillCircle(ctx, at: p, radius: 8, color: color)
        }
    }

    private func fillCircle(_ ctx: CGContext, at point: CGPoint, radius: CGFloat, color: UIColor) {
        let circle = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: circle)
    }

    /// 自分の位置と向き。進行方向が上のときは地図の方が回るので、三角は常に真上を向く
    private func drawSelfMarker(in ctx: CGContext, at point: CGPoint, pose: CameraPose) {
        let forwardScreen = CGPoint(x: CGFloat(simd_dot(pose.forwardXZ, basisRight(for: pose))),
                                    y: -CGFloat(simd_dot(pose.forwardXZ, basisForward(for: pose))))
        let rightScreen = CGPoint(x: -forwardScreen.y, y: forwardScreen.x)

        func offset(forwardAmount: CGFloat, rightAmount: CGFloat) -> CGPoint {
            CGPoint(x: point.x + forwardScreen.x * forwardAmount + rightScreen.x * rightAmount,
                    y: point.y + forwardScreen.y * forwardAmount + rightScreen.y * rightAmount)
        }

        let triangle = CGMutablePath()
        triangle.move(to: offset(forwardAmount: 11, rightAmount: 0))
        triangle.addLine(to: offset(forwardAmount: -8, rightAmount: -8))
        triangle.addLine(to: offset(forwardAmount: -8, rightAmount: 8))
        triangle.closeSubpath()
        ctx.setFillColor(UIColor.systemBlue.cgColor)
        ctx.addPath(triangle)
        ctx.fillPath()
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(triangle)
        ctx.strokePath()
    }

    private func drawScaleBar(in ctx: CGContext, rect: CGRect) {
        let barLength = 1.0 * pointsPerMeter
        // 画面下のテキスト表示に隠れないよう、少し上に描く
        let origin = CGPoint(x: 16, y: rect.height * 0.62)

        ctx.setStrokeColor(UIColor.systemBlue.cgColor)
        ctx.setLineWidth(3)
        ctx.move(to: origin)
        ctx.addLine(to: CGPoint(x: origin.x + barLength, y: origin.y))
        ctx.strokePath()

        let label = (rotatesWithCamera ? "1m  [進行方向が上] 長押しで切替" : "1m  [北が上] 長押しで切替") as NSString
        label.draw(at: CGPoint(x: origin.x, y: origin.y - 16),
                   withAttributes: [.font: UIFont.boldSystemFont(ofSize: 11), .foregroundColor: UIColor.systemBlue])
    }

    private struct GridRange {
        let minX: Int, maxX: Int
        let minZ: Int, maxZ: Int
    }

    /// 画面に映りうる範囲を、画面の四隅を逆変換して求める（回転を考慮した外接矩形）
    private func gridRange(for visibleRect: CGRect, anchor: CGPoint, pose: CameraPose, cellSize: Float) -> GridRange? {
        guard pointsPerMeter > 0, cellSize > 0 else { return nil }
        let corners = [
            CGPoint(x: visibleRect.minX, y: visibleRect.minY),
            CGPoint(x: visibleRect.maxX, y: visibleRect.minY),
            CGPoint(x: visibleRect.minX, y: visibleRect.maxY),
            CGPoint(x: visibleRect.maxX, y: visibleRect.maxY)
        ].map { screenToWorld($0, anchor: anchor, pose: pose) }

        let xs = corners.map { $0.x }, zs = corners.map { $0.y }
        guard let minWorldX = xs.min(), let maxWorldX = xs.max(),
              let minWorldZ = zs.min(), let maxWorldZ = zs.max() else { return nil }
        return GridRange(minX: Int(floor(minWorldX / cellSize)), maxX: Int(floor(maxWorldX / cellSize)),
                         minZ: Int(floor(minWorldZ / cellSize)), maxZ: Int(floor(maxWorldZ / cellSize)))
    }
}
