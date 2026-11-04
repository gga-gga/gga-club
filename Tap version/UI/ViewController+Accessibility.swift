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
//  操作は背面タップで行う（ボタンは廃止した）。予備として VoiceOver のマジックタップ・エスケープも
//  受け付ける（ViewController+BackTap）。
//

import UIKit

extension ViewController {
    func configureAccessibility() {
        // 画面全体＝カメラ映像の1要素だけを VoiceOver に見せる（デバッグ表示のテキストは読ませない）。
        // 画面に入ったときや、画面に触れたときに読まれるのはこの短い説明だけになる
        sceneView.isAccessibilityElement = true
        view.accessibilityElements = [sceneView as Any]
        // 説明文は固定にして、状態が変わっても書き換えない。
        // フォーカスのある要素の説明文を書き換えると、VoiceOver がそれを自動で読み直し、
        // 誘導開始や到着のときのアプリの読み上げと重なっていたため
        // 画面が開いたときに VoiceOver が読むのはこの説明だけなので、できるだけ短くしている
        sceneView.accessibilityLabel = "空席ナビ"
    }
}
