//
//  ViewController+OGMMap.swift
//  SUWARERU
//
//  デバッグ用：誘導画面の右上の「OGM」ボタンで、カメラ映像と OGM の2D地図を切り替える。
//  開発時に画面を見ながら確かめるためのもので、利用者の操作（背面タップ）には関係しない。
//  ボタンは VoiceOver の読み上げ対象にしない（configureAccessibility で画面の要素を1つに絞っている）。
//

import UIKit
import simd

extension ViewController {
    func setupOGMMapToggle() {
        // 地図はカメラ映像の上、デバッグ用のテキスト表示の下に重ねる
        ogmMapView = OGMMapView(frame: sceneView.frame)
        ogmMapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ogmMapView.isHidden = true
        view.insertSubview(ogmMapView, aboveSubview: sceneView)

        mapToggleButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.6)
            config.baseForegroundColor = .white
            config.cornerStyle = .medium
            mapToggleButton.configuration = config
        } else {
            mapToggleButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
            mapToggleButton.setTitleColor(.white, for: .normal)
            mapToggleButton.layer.cornerRadius = 8
        }
        mapToggleButton.addTarget(self, action: #selector(toggleOGMMap), for: .touchUpInside)
        updateMapToggleTitle()
        view.addSubview(mapToggleButton)
        NSLayoutConstraint.activate([
            mapToggleButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            mapToggleButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8)
        ])
    }

    @objc func toggleOGMMap() {
        isShowingOGMMap.toggle()
        ogmMapView.isHidden = !isShowingOGMMap
        updateMapToggleTitle()
    }

    private func updateMapToggleTitle() {
        mapToggleButton.setTitle(isShowingOGMMap ? "カメラ" : "OGM", for: .normal)
    }

    /// 地図の描画データを作る（描画スレッドから呼ぶ。OGM を触るのはこのスレッドだけ）
    func makeOGMMapSnapshot(cameraTransform m: simd_float4x4,
                            plan: PathPlan,
                            confirmedTracks: [Track],
                            targetID: UUID?) -> OGMMapView.Snapshot {
        let back = simd_float2(m.columns.2.x, m.columns.2.z)
        let forward = simd_length(back) > 1e-4 ? -simd_normalize(back) : simd_float2(0, -1)

        var snapshot = OGMMapView.Snapshot()
        snapshot.cells = ogmEngine.grid.cells
        snapshot.cellSize = ogmEngine.grid.cellSize
        snapshot.cameraPose = OGMMapView.CameraPose(forwardXZ: forward,
                                                    positionXZ: simd_float2(m.columns.3.x, m.columns.3.z))
        snapshot.rawPoints = ogmEngine.lastClassifiedPoints
        snapshot.path = plan.path
        snapshot.steeringPoint = plan.steeringPoint
        snapshot.seats = confirmedTracks.map { track in
            let kind: OGMMapView.SeatMarker.Kind
            if track.id == targetID {
                kind = .target
            } else if track.isEmpty {
                kind = .empty
            } else {
                kind = .occupied
            }
            return OGMMapView.SeatMarker(positionXZ: simd_float2(track.worldPosition.x, track.worldPosition.z),
                                         kind: kind)
        }
        return snapshot
    }
}
