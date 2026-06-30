import Foundation

// 1次元カルマンフィルタ：GPS（低頻度・高精度）と加速度（高頻度・ドリフトあり）を最適融合
struct SpeedKalmanFilter {
    private(set) var speedMs: Double = 0
    private var p: Double = 100.0  // 初期は不確実性を最大に設定

    mutating func reset() {
        speedMs = 0
        p = 100.0
    }

    // 予測ステップ：加速度センサーで100Hzごとに呼ぶ
    mutating func predict(accelMs2: Double, dt: Double) {
        speedMs = max(0, speedMs + accelMs2 * dt)
        // 加速度が大きい（発進・急加速）ほど加速度計を信頼してQを下げ、
        // 加速度が小さい（定速・停車）ほどGPSを優先してQを上げる
        let q: Double = abs(accelMs2) > 2.0 ? 0.3 : 1.5
        p += q * dt
    }

    // 更新ステップ：GPSサンプル到着時（～10Hz）に呼ぶ
    // speedAccuracyMs: CLLocation.speedAccuracy（m/s、1σ）
    mutating func update(gpsSpeedMs: Double, speedAccuracyMs: Double) {
        let r = speedAccuracyMs > 0 ? speedAccuracyMs * speedAccuracyMs : 0.25
        let k = p / (p + r)
        speedMs = max(0, speedMs + k * (gpsSpeedMs - speedMs))
        p = (1.0 - k) * p
    }
}
