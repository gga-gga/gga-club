//
//  ViewController+OGM.swift
//  SUWARERU
//
//  占有格子地図（OGM）の更新。現時点では地図を作るだけで、案内には使っていない。
//

import ARKit

extension ViewController {
    /// 深度取得〜グリッド書き込み・持続性カウンタ（仕様書[1]〜[6]）を約10fpsで実行する
    func updateOGMIfNeeded(time: TimeInterval) {
        guard time - lastOGMUpdateTime >= OGMConfig.depthCaptureInterval else { return }
        lastOGMUpdateTime = time
        guard let frame = sceneView.session.currentFrame else { return }
        ogmEngine.update(frame: frame, timestamp: time)
    }
}
