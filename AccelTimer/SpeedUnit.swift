import Foundation

/// 速度の表示単位。計測の中核は常に km/h で行い、表示・スプリットのマイルストーンのみ
/// この単位に従って切り替える。mph は米国市場向け（0-60mph が標準指標）。
enum SpeedUnit: String, CaseIterable, Identifiable {
    case kmh
    case mph

    var id: String { rawValue }

    /// 単位ラベル。
    var label: String { self == .kmh ? "km/h" : "mph" }

    /// km/h からこの単位の表示値へ変換する。
    func value(fromKmh kmh: Double) -> Double {
        self == .kmh ? kmh : kmh / 1.609344
    }

    /// スプリット枠のマイルストーン速度（km/h で表現・4点でグリッド2×2に対応）。
    /// mph は [15,30,45,60] mph をすべて 100 km/h 手前に収める。
    var milestonesKmh: [Double] {
        switch self {
        case .kmh: return [40, 60, 80, 100]
        case .mph: return [15, 30, 45, 60].map { Double($0) * 1.609344 }
        }
    }

    /// マイルストーンの表示ラベル。
    var milestoneLabels: [String] {
        switch self {
        case .kmh: return ["0→40", "0→60", "0→80", "0→100"]
        case .mph: return ["0→15", "0→30", "0→45", "0→60"]
        }
    }

    /// ヘッドライン（主役）マイルストーンの km/h 相当（km/h=100、mph=60mph）。
    var headlineKmh: Double { milestonesKmh.last ?? 100 }

    /// ヘッドラインの表示ラベル（"0-100 km/h" / "0-60 mph"）。
    var headlineLabel: String {
        self == .kmh ? "0 → 100 km/h" : "0 → 60 mph"
    }

    /// 端末の地域からの既定単位（米国のみ mph）。
    static var defaultForLocale: SpeedUnit {
        Locale.current.measurementSystem == .us ? .mph : .kmh
    }

    /// 速度時系列(km/h)から、目標速度(km/h)に到達した時刻(秒)を線形補間で求める。
    /// 旧レコードを含め、保存済みタイムラインから任意のマイルストーン時刻を再計算できる。
    static func time(toReachKmh target: Double, in samples: [SpeedSample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        var prev = samples[0]
        for s in samples.dropFirst() {
            if prev.speed < target, s.speed >= target {
                let denom = s.speed - prev.speed
                let frac = denom > 0 ? (target - prev.speed) / denom : 0
                return prev.time + frac * (s.time - prev.time)
            }
            prev = s
        }
        return nil
    }
}
