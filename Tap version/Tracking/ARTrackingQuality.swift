//
//  ARTrackingQuality.swift
//  SUWARERU
//
//  ARKit の自己位置推定（追跡）の状態。正常（normal）以外のときはカメラの位置・向きがずれている
//  可能性が高いので、その間の深度を OGM に書き込んだり座面の位置を推定したりしない
//  （起動直後や速く体を回したときに、ずれた占有セルや座席の位置が残るのを防ぐ）。
//  走行中の電車では加減速で不安定になる可能性があり、実車での確認用に状態を画面に表示する。
//

import ARKit

enum ARTrackingQuality {
    case normal
    /// 起動直後など、追跡を始めたところ
    case initializing
    /// 体（端末）を速く動かしすぎている
    case excessiveMotion
    /// 暗い・白い壁しか映らないなど、手がかりが少ない
    case insufficientFeatures
    /// 中断の後などで、位置を推定し直している
    case relocalizing
    /// その他の理由で不安定
    case limitedOther
    /// 追跡できていない
    case notAvailable

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .normal:
            self = .normal
        case .notAvailable:
            self = .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing: self = .initializing
            case .excessiveMotion: self = .excessiveMotion
            case .insufficientFeatures: self = .insufficientFeatures
            case .relocalizing: self = .relocalizing
            @unknown default: self = .limitedOther
            }
        }
    }

    var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }

    var debugText: String {
        switch self {
        case .normal: return "正常"
        case .initializing: return "初期化中"
        case .excessiveMotion: return "速すぎる動き"
        case .insufficientFeatures: return "手がかり不足"
        case .relocalizing: return "再推定中"
        case .limitedOther: return "不安定"
        case .notAvailable: return "利用不可"
        }
    }
}
