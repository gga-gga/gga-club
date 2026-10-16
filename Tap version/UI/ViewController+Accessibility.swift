//
//  ViewController+Accessibility.swift
//  SUWARERU
//
//  誘導画面での VoiceOver の扱い。
//
//  利用者は VoiceOver を使ってスマホを操作している想定だが、誘導画面ではスマホを首から下げた
//  ポーチに入れていて画面には触れない。案内はアプリ自身の音声合成で話すので、VoiceOver には
//  なるべく話させない（VoiceOver が話すと、アプリの案内と声が重なる）。
//   - 画面全体を1つの要素にまとめ、ボタンなどは VoiceOver の読み上げ対象から外す
//   - アプリからはアナウンス・フォーカスの移動・画面切り替えの通知を一切出さない
//   - ヒント（遅れて読まれる補足説明）も付けない
//  操作は背面タップで行う。VoiceOver を使わない場合（開発時など）は、ボタンを今までどおり指で押せる。
//

import UIKit

extension ViewController {
    func configureAccessibility() {
        // 画面全体＝カメラ映像の1要素だけを VoiceOver に見せる。
        // 画面に入ったときや、画面に触れたときに読まれるのはこの短い説明だけになる
        sceneView.isAccessibilityElement = true
        sceneView.accessibilityTraits = []
        view.accessibilityElements = [sceneView as Any]
        updateAccessibilityForCurrentState()
    }

    /// 状態に合わせて画面の説明を変える。読み上げのきっかけ（通知）は出さないので、
    /// 利用者が画面に触れたときにだけ読まれる
    func updateAccessibilityForCurrentState() {
        let isArrivalPanelVisible = isAwaitingArrivalDecision && !arrivalPanelView.isHidden
        if isArrivalPanelVisible {
            sceneView.accessibilityLabel = "空席ナビ、到着しました。操作は背面タップで行います。"
        } else if isGuidancePaused {
            sceneView.accessibilityLabel = "空席ナビ、状況確認中。操作は背面タップで行います。"
        } else {
            sceneView.accessibilityLabel = "空席ナビ、誘導中。操作は背面タップで行います。"
        }
    }
}
