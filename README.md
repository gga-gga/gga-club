# 空席ナビアプリ

ARKit と Core ML を使って、**空席の椅子を検出し音声・ハプティクスで誘導する iOS アプリ**です。  
`Tap version` 配下に Xcode プロジェクトの主要ソースがあります。

## 主な機能

- **AR 空間での物体検出**
  - `yolo11n` Core ML モデルを使って `chair` と `person` を検出。
  - 椅子と人物の重なり（IoU）を使って着席中/空席を判定。
- **音声ガイダンス（TTS）**
  - 椅子までの方向・到着案内を日本語音声でガイド。
  - 到着後の続行/終了フローを UI で操作可能。
- **ハプティクス誘導**
  - 方向フィードバックを振動で提示し、視覚に頼らない誘導を補助。
- **AR オーバーレイ表示**
  - 検出中オブジェクトの 2D バウンディングボックス表示。
  - 3D ラベルノードの追従表示。

## 技術スタック

- **iOS / Swift / UIKit**
- **ARKit / SceneKit**
- **Vision / Core ML**
- **AVFoundation（音声再生・音声合成）**

## ディレクトリ構成（抜粋）

```text
.
├── README.md
├── index.html
└── Tap version/
    ├── ViewController.swift      # AR・検出・誘導の中心ロジック
    ├── Detection.swift           # 検出関連ロジック
    ├── StartViewController.swift # 開始画面ロジック
    ├── ShortcutAction.swift      # ショートカット起動関連
    ├── AppDelegate.swift
    ├── Info.plist
    ├── Base.lproj/
    ├── Assets.xcassets/
    ├── yolo11n.mlpackage/
    └── LONG.mlpackage/
```

## セットアップ

1. macOS で Xcode を用意します（iOS 開発環境）。
2. このリポジトリをクローンします。
3. Xcode で `Tap version` のプロジェクトを開きます。
4. 署名設定（Signing）を自分のチームに合わせて更新します。
5. 実機（ARKit 対応 iPhone/iPad）を接続して実行します。

> 注意: ARKit / カメラ / 音声出力を利用するため、シミュレータでは機能検証に制限があります。

## 使い方（想定フロー）

1. アプリを起動し、開始画面からガイダンスを開始。
2. カメラを周囲に向けると、椅子・人物を検出。
3. 空席候補が見つかると、音声と振動で方向案内。
4. 到着時は案内パネルで「続行」または「終了」を選択。

## 調整しやすいパラメータ

主に `Tap version/ViewController.swift` にしきい値があります。

- `minConfidence`（検出信頼度しきい値）
- `personChairIoUThreshold`（着席判定の重なりしきい値）
- `arrivalThresholdMeters`（到着判定距離）
- `mlInterval`（推論間隔）
- `ttsRepeatInterval`（音声リピート間隔）

環境に応じて値を調整すると、誤検出や案内頻度を最適化できます。

