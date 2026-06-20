import SwiftUI

/// SNS 共有用のトロフィー結果カード。計測結果を 1 枚絵にまとめ、`ImageRenderer` で
/// 画像化して共有する。無料ユーザー（`showsWatermark == true`）には透かしを入れ、
/// 買い切り解放で透かしのないクリーンなカードを書き出せるようにして課金動機を作る。
struct ResultCardView: View {
    let record: MeasurementRecord
    /// true なら「体験版」透かしを表示する（無料ユーザー）。
    let showsWatermark: Bool
    /// 表示単位（km/h / mph）。
    var unit: SpeedUnit = .kmh

    /// 単位ごとのスプリット時刻。mph は計測時に保存した高精度 split を優先する。
    private var splitValues: [Double?] {
        (0..<4).map { record.splitTime(unit: unit, band: $0) }
    }
    /// ヘッドライン時刻（km/h=0-100、mph=0-60mph）。達成していなければ nil。
    private var headlineValue: Double? {
        record.splitTime(unit: unit, band: 3)
    }

    /// 共有に使う固定サイズ（縦長・SNS 映え）。レンダラ側で 3 倍解像度に拡大する。
    static let cardSize = CGSize(width: 340, height: 480)

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    private static let goldGradient = LinearGradient(
        colors: [Color(red: 1, green: 0.85, blue: 0.3), Color(red: 1, green: 0.6, blue: 0.0)],
        startPoint: .top, endPoint: .bottom)

    var body: some View {
        ZStack {
            // 背景：黒 → ディープレーシングレッド → 黒（アプリ世界観に合わせる）
            LinearGradient(colors: [.black, Color(red: 0.14, green: 0.02, blue: 0.05), .black],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                brandHeader
                Spacer(minLength: 0)
                heroTime
                Spacer(minLength: 0)
                splitRow
                    .padding(.top, 18)
                footer
                    .padding(.top, 14)
            }
            .padding(22)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .overlay(alignment: .center) {
            if showsWatermark { watermark }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Parts

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Self.goldGradient)
            Text("ACCELTIMER")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white)
            Spacer()
            if record.isReferenceOnly {
                Text("参考値")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.orange.opacity(0.18), in: Capsule())
            }
        }
    }

    private var heroTime: some View {
        VStack(spacing: 2) {
            Text(unit.headlineLabel)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            if let headline = headlineValue {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(Self.timeString(headline))
                        .font(.system(size: 78, weight: .heavy, design: .rounded))
                        .foregroundStyle(Self.goldGradient)
                    Text("秒")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                VStack(spacing: 4) {
                    Text("未達成")
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("最高 \(Self.speedString(record.maxSpeedKmh, unit))")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var splitRow: some View {
        let labels = unit.milestoneLabels
        let values = splitValues
        return HStack(spacing: 0) {
            splitCell(labels[0], values[0] ?? 0)
            divider
            splitCell(labels[1], values[1] ?? 0)
            divider
            splitCell(labels[2], values[2] ?? 0)
            divider
            splitCell(labels[3], values[3] ?? 0)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1))
    }

    private func splitCell(_ label: String, _ value: Double) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Text(value > 0 ? Self.timeString(value) : "--")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 28)
    }

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if record.isComplete {
                    Text("最高速度 \(Self.speedString(record.maxSpeedKmh, unit))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(Self.dateFormatter.string(from: record.date))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let flag = record.countryFlag {
                Text(flag).font(.system(size: 20))
            }
        }
    }

    private var watermark: some View {
        Text("AccelTimer 体験版")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Color.black.opacity(0.35), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
            .rotationEffect(.degrees(-18))
    }

    // MARK: Format

    /// 秒を「5.23」形式（小数2桁）に整形する。
    static func timeString(_ t: Double) -> String {
        String(format: "%.2f", t)
    }

    /// km/h 値を表示単位に変換して「123.4 mph」形式に整形する。
    static func speedString(_ kmh: Double, _ unit: SpeedUnit) -> String {
        String(format: "%.1f \(unit.label)", unit.value(fromKmh: kmh))
    }
}

/// 結果カードを共有用の PNG ファイルに書き出すヘルパー。
@MainActor
enum ResultCardRenderer {
    /// カードを 3 倍解像度の PNG に書き出し、一時ファイルの URL を返す。失敗時は nil。
    static func renderURL(record: MeasurementRecord, showsWatermark: Bool,
                          unit: SpeedUnit = .kmh) -> URL? {
        let card = ResultCardView(record: record, showsWatermark: showsWatermark, unit: unit)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        guard let image = renderer.uiImage, let data = image.pngData() else { return nil }
        let stamp = Int(record.date.timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccelTimer-\(stamp).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
