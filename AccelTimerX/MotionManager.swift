import CoreMotion
import Foundation
import QuartzCore

final class MotionManager {
    var onMotionUpdate: ((Double, TimeInterval) -> Void)?

    private let cmManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    var isAvailable: Bool { cmManager.isDeviceMotionAvailable }

    func startUpdates() {
        guard cmManager.isDeviceMotionAvailable, !cmManager.isDeviceMotionActive else { return }
        cmManager.deviceMotionUpdateInterval = 1.0 / 100.0
        cmManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            if error != nil {
                // CoreMotion が停止した場合はゼロ加速度で通知し、Kalman を GPS 優先に切り替える
                Task { @MainActor [weak self] in
                    self?.onMotionUpdate?(0.0, CACurrentMediaTime())
                }
                return
            }
            guard let motion else { return }
            // 水平面の加速度マグニチュードを返す（符号はTimerEngineがGPS傾向から決定）
            let mag = Self.horizontalMagnitudeMs2(from: motion)
            let ts  = motion.timestamp
            Task { @MainActor [weak self] in
                self?.onMotionUpdate?(mag, ts)
            }
        }
    }

    func stopUpdates() {
        cmManager.stopDeviceMotionUpdates()
    }

    // 重力成分を除いた水平加速度の大きさ（m/s²、常に正値）
    static func horizontalMagnitudeMs2(from motion: CMDeviceMotion) -> Double {
        let ua = motion.userAcceleration
        let g  = motion.gravity

        let gMag2 = g.x*g.x + g.y*g.y + g.z*g.z
        guard gMag2 > 1e-6 else {
            return sqrt(ua.x*ua.x + ua.y*ua.y + ua.z*ua.z) * 9.81
        }

        let dot = ua.x*g.x + ua.y*g.y + ua.z*g.z
        let hx  = ua.x - dot/gMag2 * g.x
        let hy  = ua.y - dot/gMag2 * g.y
        let hz  = ua.z - dot/gMag2 * g.z

        return sqrt(hx*hx + hy*hy + hz*hz) * 9.81
    }
}
