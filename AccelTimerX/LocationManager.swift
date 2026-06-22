import CoreLocation
import Foundation

@Observable
@MainActor
final class LocationManager: NSObject {
    private(set) var speedMs: Double = 0
    private(set) var horizontalAccuracy: Double = -1
    private(set) var speedAccuracy: Double = -1
    private(set) var authStatus: CLAuthorizationStatus = .notDetermined
    private(set) var coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)

    var onSpeedUpdate: ((Double, Date, Double, Double, CLLocationCoordinate2D) -> Void)?

    private let clManager = CLLocationManager()

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        clManager.activityType = .automotiveNavigation
        clManager.distanceFilter = kCLDistanceFilterNone
        // 信号待ち等の停車中に iOS が GPS を自動停止するのを防ぐ（計測精度のため必須）
        clManager.pausesLocationUpdatesAutomatically = false
        authStatus = clManager.authorizationStatus
    }

    func requestPermission() {
        clManager.requestWhenInUseAuthorization()
    }

    func startUpdating() {
        clManager.startUpdatingLocation()
    }

    func stopUpdating() {
        clManager.stopUpdatingLocation()
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        // バッチ配信対応：全サンプルを処理（復帰時などに複数サンプルが同時に来ても split を取りこぼさない）
        let valid = locations.filter { $0.speedAccuracy >= 0 && $0.speed >= 0 }
        guard !valid.isEmpty else { return }
        let snapshots = valid.map { (speed: $0.speed, ts: $0.timestamp,
                                     hAcc: $0.horizontalAccuracy, sAcc: $0.speedAccuracy,
                                     coord: $0.coordinate) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for snap in snapshots {
                self.speedMs = snap.speed
                self.horizontalAccuracy = snap.hAcc
                self.speedAccuracy = snap.sAcc
                self.coordinate = snap.coord
                self.onSpeedUpdate?(snap.speed, snap.ts, snap.sAcc, snap.hAcc, snap.coord)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            self?.authStatus = status
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        // locationUnknown は一時的な取得失敗で自動回復するため無視する
        guard (error as? CLError)?.code != .locationUnknown else { return }
        Task { @MainActor [weak self] in
            self?.horizontalAccuracy = -1
            self?.speedAccuracy      = -1
        }
    }
}
