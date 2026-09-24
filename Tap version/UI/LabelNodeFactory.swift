//
//  LabelNodeFactory.swift
//  SUWARERU
//
//  トラック位置に置く3Dラベル（常にカメラを向く文字＋位置を示す点）を作る。
//

import SceneKit
import UIKit

enum LabelNodeFactory {
    static let bubbleDepth: Float = 0.01

    static func makeBubbleNode(text: String) -> SCNNode {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return SCNNode() }

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y

        let scnText = SCNText(string: t, extrusionDepth: CGFloat(bubbleDepth))
        var font = UIFont(name: "Futura", size: 0.15)
        font = font?.withTraits(traits: .traitBold)
        scnText.font = font
        scnText.alignmentMode = kCAAlignmentCenter
        scnText.firstMaterial?.diffuse.contents = UIColor.orange
        scnText.firstMaterial?.specular.contents = UIColor.white
        scnText.firstMaterial?.isDoubleSided = true
        scnText.chamferRadius = CGFloat(bubbleDepth)

        let (minB, maxB) = scnText.boundingBox
        let textNode = SCNNode(geometry: scnText)
        textNode.pivot = SCNMatrix4MakeTranslation((maxB.x - minB.x)/2, minB.y, bubbleDepth/2)
        textNode.scale = SCNVector3(0.2, 0.2, 0.2)

        let dot = SCNSphere(radius: 0.005)
        dot.firstMaterial?.diffuse.contents = UIColor.cyan
        let dotNode = SCNNode(geometry: dot)

        let parent = SCNNode()
        parent.addChildNode(textNode)
        parent.addChildNode(dotNode)
        parent.constraints = [billboard]
        return parent
    }
}

// MARK: - UIFont helper
private extension UIFont {
    func withTraits(traits: UIFontDescriptor.SymbolicTraits...) -> UIFont {
        let d = fontDescriptor.withSymbolicTraits(UIFontDescriptor.SymbolicTraits(traits))
        return UIFont(descriptor: d!, size: 0)
    }
}
