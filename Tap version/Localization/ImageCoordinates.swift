//
//  ImageCoordinates.swift
//  SUWARERU
//
//  画像座標どうしの変換。座標系は次の3つ:
//   - Vision座標：推論に渡した向き（縦持ちなら縦長）の画像の正規化座標・左下原点
//   - native座標：カメラ本来の向き（横長）の capturedImage / 深度マップの正規化座標・左上原点
//   - 画面座標：ARSCNView 上のポイント座標・左上原点（aspect-fill で左右が切り取られている）
//
//  深度マップは capturedImage と同じ範囲を写しているので、native座標に解像度を掛ければ
//  そのまま深度マップの画素になる。画面座標を経由しないこと（以前はここで2重に誤っていた）。
//

import CoreGraphics
import ImageIO

enum ImageCoordinates {
    /// Vision座標 → native座標
    static func nativePoint(fromVision p: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        // まず左上原点にそろえる
        let x = p.x
        let yTop = 1 - p.y
        switch orientation {
        case .right:
            // 縦持ち：native画像を時計回りに90°回して表示している
            return CGPoint(x: yTop, y: 1 - x)
        case .left:
            return CGPoint(x: 1 - yTop, y: x)
        case .down:
            return CGPoint(x: 1 - x, y: 1 - yTop)
        default:
            // .up：native画像そのまま
            return CGPoint(x: x, y: yTop)
        }
    }

    /// Vision座標の矩形 → native座標の矩形（向きの変換は90°単位の回転・反転なので4隅の外接矩形で正確に求まる）
    static func nativeRect(fromVision rect: CGRect, orientation: CGImagePropertyOrientation) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ].map { nativePoint(fromVision: $0, orientation: orientation) }
        let minX = min(corners[0].x, corners[1].x), maxX = max(corners[0].x, corners[1].x)
        let minY = min(corners[0].y, corners[1].y), maxY = max(corners[0].y, corners[1].y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// native座標 → 画面座標。displayTransform は frame.displayTransform(for:viewportSize:) の値
    /// （native正規化座標 → 画面正規化座標の変換で、aspect-fill の切り取りも含む）。
    static func screenPoint(fromNative p: CGPoint,
                            displayTransform: CGAffineTransform,
                            viewportSize: CGSize) -> CGPoint {
        let n = p.applying(displayTransform)
        return CGPoint(x: n.x * viewportSize.width, y: n.y * viewportSize.height)
    }

    /// Vision座標 → 画面座標
    static func screenPoint(fromVision p: CGPoint,
                            orientation: CGImagePropertyOrientation,
                            displayTransform: CGAffineTransform,
                            viewportSize: CGSize) -> CGPoint {
        screenPoint(fromNative: nativePoint(fromVision: p, orientation: orientation),
                    displayTransform: displayTransform,
                    viewportSize: viewportSize)
    }

    /// Vision座標のBBox → 画面座標のBBox（4隅を変換して外接矩形を取る）
    static func screenRect(fromVision rect: CGRect,
                           orientation: CGImagePropertyOrientation,
                           displayTransform: CGAffineTransform,
                           viewportSize: CGSize) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ].map {
            screenPoint(fromVision: $0, orientation: orientation,
                        displayTransform: displayTransform, viewportSize: viewportSize)
        }
        let xs = corners.map { $0.x }
        let ys = corners.map { $0.y }
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
