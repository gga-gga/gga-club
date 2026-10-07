//
//  ViewController+OGM.swift
//  SUWARERU
//
//  占有格子地図（OGM）の更新。地図はまだ案内には使っておらず、床の高さだけを座面の推定に渡している。
//

import ARKit

extension ViewController {
    /// 深度取得〜グリッド書き込み・持続性カウンタ（仕様書[1]〜[6]）を約10fpsで実行する
    func updateOGMIfNeeded(time: TimeInterval) {
        guard time - lastOGMUpdateTime >= OGMConfig.depthCaptureInterval else { return }
        lastOGMUpdateTime = time
        guard let frame = sceneView.session.currentFrame else { return }
        ogmEngine.update(frame: frame, timestamp: time)

        let floorY = ogmEngine.floorY
        stateQueue.sync {
            self.latestFloorY = floorY
        }
    }
}
