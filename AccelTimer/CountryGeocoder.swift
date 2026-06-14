import Foundation
import CoreLocation

// MARK: - 国コード → 国旗絵文字 / 国名

extension String {
    /// ISO 3166-1 alpha-2 国コードを国旗絵文字に変換（"JP" → 🇯🇵）。無効・不明時は nil。
    var countryFlagEmoji: String? {
        let code = uppercased()
        guard code.count == 2, code != CountryGeocoder.unknownCode else { return nil }
        let base: UInt32 = 0x1F1E6  // 🇦 (Regional Indicator Symbol Letter A)
        var emoji = ""
        for scalar in code.unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90,
                  let flag = Unicode.Scalar(base + scalar.value - 65) else { return nil }
            emoji.unicodeScalars.append(flag)
        }
        return emoji
    }

    /// ISO 国コードをローカライズされた国名に変換（"JP" → "日本"）。無効・不明時は nil。
    var localizedCountryName: String? {
        let code = uppercased()
        guard code.count == 2, code != CountryGeocoder.unknownCode else { return nil }
        return Locale.current.localizedString(forRegionCode: code)
    }
}

// MARK: - CountryGeocoder

/// 計測レコードの開始座標から国コード(ISO 3166-1)を逆ジオコーディングで付与するサービス。
/// CLGeocoder はレート制限が厳しいため、未設定レコードを1件ずつ間隔を空けて処理する。
/// 計測の保存パス（TimerEngine）はネットワークに依存させず、ここで後追いバックフィルする。
@MainActor
final class CountryGeocoder {
    static let shared = CountryGeocoder()

    /// 逆ジオコーディングは成功したが国を特定できなかった場合のセンサー値（海上など）。
    /// 空文字と区別し、同じレコードを毎回再試行しないためのマーカー。
    static let unknownCode = "ZZ"

    private let geocoder = CLGeocoder()
    private var isRunning = false

    /// isoCountryCode 未設定（空）かつ座標を持つレコードを順に逆ジオコーディングして埋める。
    /// ネットワーク不通などで失敗した場合は中断し、次回呼び出し時に再試行する（部分成功は保存済み）。
    func backfill(records: [MeasurementRecord]) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let targets = records.filter { $0.isoCountryCode.isEmpty && $0.hasLocationData }
        for record in targets {
            let location = CLLocation(latitude: record.startLatitude,
                                      longitude: record.startLongitude)
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                record.isoCountryCode = placemarks.first?.isoCountryCode ?? Self.unknownCode
                // レート制限回避：次のリクエストまで間隔を空ける
                try await Task.sleep(for: .seconds(1))
            } catch {
                // ネットワーク不通・キャンセル等：中断して次回再試行
                break
            }
        }
    }
}
