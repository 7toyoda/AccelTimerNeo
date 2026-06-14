import Foundation
import SwiftData
import CoreLocation

// MARK: - Speed sample for chart

struct SpeedSample: Codable {
    let time: Double    // 計測開始からの経過秒
    let speed: Double   // km/h
}

// MARK: - Acceleration sample for chart (CoreMotion 100Hz, 高精度)

struct AccelSample: Codable {
    let time: Double    // 計測開始からの経過秒
    let accel: Double   // 縦加速度 (m/s²)
}

// MARK: - Route coordinate for map

struct RouteCoordinate: Codable {
    let latitude: Double
    let longitude: Double
}

@Model
final class MeasurementRecord {
    var date: Date
    var totalTime: Double
    var split40: Double
    var split60: Double
    var split80: Double
    var maxSpeedKmh: Double
    var gpsAccuracy: Double      // 計測中の最良水平精度(m)、-1 = 不明
    var gpsSpeedAccuracy: Double = -1  // 計測中の最良Doppler速度精度(m/s)、-1 = 不明（旧レコードは-1）
    // 高速域(80 km/h 超)の平均Doppler速度精度(m/s)。100 km/h 到達付近の実効精度を表す。
    // 最良値(gpsSpeedAccuracy)と異なり、到達点の信頼性そのものを示すため警告判定に使う。-1 = 不明（旧レコード）
    var finishSpeedAccuracy: Double = -1
    // 発進点検出(lookBack)が静止区間を見つけられず GPS/外挿フォールバックに降格したか。
    // true = 発進直前に端末が静止していなかった（手持ち・揺れの疑い）→ スタート点精度が低下。
    var unstableStart: Bool = false
    // 開始座標から逆ジオコーディングした ISO 3166-1 国コード。"" = 未取得（バックフィル対象）、"ZZ" = 特定不可。
    // 将来の国別ランキング用。CountryGeocoder が後追いで埋める。
    var isoCountryCode: String = ""
    // 履歴の並びごとの非表示フラグ。ユーザーがスワイプで「この並びから除外」した時に立てる。
    // 両方が true（どの並びにも出ない）になったらレコード実体を完全削除する。
    var hiddenFromDate: Bool = false   // 日付順から除外
    var hiddenFromTime: Bool = false   // タイム順（速度帯）から除外
    var isComplete: Bool      // 100 km/h に到達したか
    var startLatitude: Double
    var startLongitude: Double
    var endLatitude: Double
    var endLongitude: Double
    var videoFileName: String = ""
    var logFileName: String = ""
    var speedTimelineData: Data = Data()
    var accelTimelineData: Data = Data()   // 高精度加速度(CoreMotion 100Hz)。空 = 旧レコード
    var routeCoordinatesData: Data = Data()

    var hasLocationData: Bool {
        abs(startLatitude) > 0.001 || abs(startLongitude) > 0.001
    }
    var hasVideo: Bool { !videoFileName.isEmpty }
    var hasLog:   Bool { !logFileName.isEmpty }

    // 計測国の表示用（特定不可・未取得時は nil）
    var countryFlag: String? { isoCountryCode.countryFlagEmoji }
    var countryName: String? { isoCountryCode.localizedCountryName }

    // タイムが参考値扱いになる条件（いずれか）：
    //  ① 100 km/h 到達付近(80 km/h 超)の平均速度精度が緑未満(>=1.0 m/s)。-1 は警告しない。
    //  ② 発進点検出が静止区間を見つけられなかった（手持ち・揺れでスタート点精度が低下）。
    var isReferenceOnly: Bool { finishSpeedAccuracy >= 1.0 || unstableStart }

    var speedTimeline: [SpeedSample] {
        (try? JSONDecoder().decode([SpeedSample].self, from: speedTimelineData)) ?? []
    }

    /// 高精度加速度タイムライン（CoreMotion 100Hz）。旧レコードは空。
    var accelTimeline: [AccelSample] {
        (try? JSONDecoder().decode([AccelSample].self, from: accelTimelineData)) ?? []
    }

    var routeCoordinates: [CLLocationCoordinate2D] {
        let decoded = (try? JSONDecoder().decode([RouteCoordinate].self, from: routeCoordinatesData)) ?? []
        return decoded.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    func deleteVideoFile() {
        guard hasVideo else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
            .appendingPathComponent(videoFileName)
        try? FileManager.default.removeItem(at: url)
    }

    func deleteLogFile() {
        MeasurementLogger.deleteFile(logFileName)
    }

    init(date: Date, totalTime: Double,
         split40: Double, split60: Double, split80: Double,
         maxSpeedKmh: Double, gpsAccuracy: Double = -1,
         gpsSpeedAccuracy: Double = -1,
         finishSpeedAccuracy: Double = -1,
         unstableStart: Bool = false,
         isoCountryCode: String = "",
         isComplete: Bool = false,
         startLatitude: Double = 0, startLongitude: Double = 0,
         endLatitude: Double = 0, endLongitude: Double = 0) {
        self.date = date
        self.totalTime = totalTime
        self.split40 = split40
        self.split60 = split60
        self.split80 = split80
        self.maxSpeedKmh = maxSpeedKmh
        self.gpsAccuracy = gpsAccuracy
        self.gpsSpeedAccuracy = gpsSpeedAccuracy
        self.finishSpeedAccuracy = finishSpeedAccuracy
        self.unstableStart = unstableStart
        self.isoCountryCode = isoCountryCode
        self.isComplete = isComplete
        self.startLatitude = startLatitude
        self.startLongitude = startLongitude
        self.endLatitude = endLatitude
        self.endLongitude = endLongitude
    }
}
