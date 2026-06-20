import SwiftUI
import MapKit
import CoreLocation
import AVKit
import Charts

struct MeasurementDetailView: View {
    let record: MeasurementRecord
    let isBest: Bool
    @Environment(StoreManager.self) private var store
    @AppStorage("speedUnit") private var speedUnitRaw: String = SpeedUnit.defaultForLocale.rawValue
    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }

    /// 単位ごとのスプリット時刻。mph は計測時に保存した高精度 split を優先する。
    private var detailSplitValues: [Double?] {
        (0..<4).map { record.splitTime(unit: unit, band: $0) }
    }
    @State private var videoPlayer: AVPlayer? = nil
    @State private var isFullScreen: Bool = false
    /// 共有用に書き出した結果カード画像（無料は透かし付き）。
    @State private var cardShareURL: URL? = nil

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 16) {
                    headerSection
                    shareCardSection
                    if record.hasVideo {
                        videoSection
                    }
                    splitsSection
                    if record.isReferenceOnly {
                        referenceWarningSection
                    }
                    chartSection
                    accelChartSection
                    if record.hasLocationData {
                        mapSection
                    } else {
                        noLocationSection
                    }
                    statsSection
                    logSection
                }
                .padding()
            }
            .onAppear {
                if record.hasVideo {
                    let url = videoFileURL
                    if FileManager.default.fileExists(atPath: url.path) {
                        videoPlayer = AVPlayer(url: url)
                    }
                }
                renderShareCard()
            }
            .onChange(of: store.isPurchased) { _, _ in
                // 購入で透かしが消えるため、カードを再生成する
                renderShareCard()
            }
            .onChange(of: speedUnitRaw) { _, _ in renderShareCard() }
            .onDisappear {
                // 画面を離れたら再生を停止して解放（戻った後に音声が鳴り続けるのを防ぐ）
                videoPlayer?.pause()
                videoPlayer = nil
            }
        }
        .navigationTitle("計測詳細")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    // MARK: - Share Card

    /// 結果カードを共有用の画像に書き出して `cardShareURL` に格納する。
    private func renderShareCard() {
        cardShareURL = ResultCardRenderer.renderURL(record: record,
                                                    showsWatermark: store.showsWatermark,
                                                    unit: unit)
    }

    /// SNS 共有用トロフィーカードのボタン。無料は透かし付き、買い切りで透かしが消える。
    @ViewBuilder
    private var shareCardSection: some View {
        if let url = cardShareURL {
            VStack(spacing: 8) {
                ShareLink(
                    item: url,
                    preview: SharePreview("計測結果カード",
                                          image: Image(systemName: "rosette"))
                ) {
                    Label("結果カードを共有", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            LinearGradient(colors: [.yellow, Color(red: 1, green: 0.7, blue: 0)],
                                           startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 14))
                }
                if store.showsWatermark {
                    Text("「体験版」の透かしを消すには解放が必要です")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Video

    private var videoFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings")
            .appendingPathComponent(record.videoFileName)
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "video.fill")
                    .foregroundStyle(.secondary)
                Text("録画データ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if videoPlayer != nil {
                    ShareLink(
                        item: videoFileURL,
                        preview: SharePreview("計測動画",
                                             icon: Image(systemName: "video.fill"))
                    ) {
                        Label("共有", systemImage: "square.and.arrow.up")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }
            if let player = videoPlayer {
                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isFullScreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.black.opacity(0.65))
                                .clipShape(Circle())
                        }
                        .padding(8)
                    }
                    .fullScreenCover(isPresented: $isFullScreen) {
                        FullScreenVideoView(player: player)
                    }
            } else {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("動画ファイルが見つかりません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.dateFormatter.string(from: record.date))
                    .font(.subheadline)
                    .foregroundStyle(.white)
                if let flag = record.countryFlag, let name = record.countryName {
                    Text("\(flag) \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle()
                        .fill(gpsColor(record))
                        .frame(width: 8, height: 8)
                    Text(gpsLabel(record))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if isBest && record.isComplete {
                    Label("ベスト", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                if !record.isComplete {
                    Text("未達成")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.orange.opacity(0.3))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                if record.isReferenceOnly {
                    Label("参考値", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Splits

    private var splitsSection: some View {
        let labels = unit.milestoneLabels
        let values = detailSplitValues
        return VStack(spacing: 0) {
            DetailSplitRow(label: "\(labels[0]) \(unit.label)", value: values[0])
            Divider().opacity(0.2).padding(.horizontal)
            DetailSplitRow(label: "\(labels[1]) \(unit.label)", value: values[1])
            Divider().opacity(0.2).padding(.horizontal)
            DetailSplitRow(label: "\(labels[2]) \(unit.label)", value: values[2])
            Divider().opacity(0.4).padding(.horizontal)
            DetailSplitRow(
                label: "\(labels[3]) \(unit.label)",
                value: values[3],
                isHighlight: true
            )
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Map

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
                Text("走行ルート")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(record.isComplete ? String(localized: "S = スタート  G = 計測終了地点") : String(localized: "S = スタート  G = 停車地点"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Map(initialPosition: .region(mapRegion)) {
                Annotation("スタート", coordinate: startCoord, anchor: .bottom) {
                    ZStack {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 30, height: 30)
                            .shadow(radius: 3)
                        Text("S")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
                Annotation(record.isComplete ? String(localized: "計測終了地点") : String(localized: "停車地点"), coordinate: endCoord, anchor: .bottom) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 30, height: 30)
                            .shadow(radius: 3)
                        Text("G")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.white)
                    }
                }
                MapPolyline(coordinates: routePolylineCoords)
                    .stroke(.cyan, lineWidth: 3)
            }
            .mapStyle(.standard)
            .frame(height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // タイムが参考値扱いになった理由を説明する注意バナー（複数該当時は全て列挙）
    private var referenceWarningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if record.unstableStart {
                warningRow(String(localized: "発進時に端末が安定しておらず、スタート点の検出精度が低下しています（手持ち撮影の可能性）。端末を車体に固定すると改善します。"))
            }
            if record.finishSpeedAccuracy >= 1.0 {
                let v = String(format: "%.1f", unit.value(fromKmh: record.finishSpeedAccuracy * 3.6))
                warningRow(String(localized: "計測終了付近のGPS速度精度が±\(v)\(unit.label)に低下しています。"))
            }
            Text("このタイムは参考値としてご覧ください。")
                .font(.caption.bold())
                .foregroundStyle(.orange)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func warningRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var noLocationSection: some View {
        HStack {
            Image(systemName: "map.slash")
                .foregroundStyle(.secondary)
            Text("位置データなし（この記録は地図表示に対応していません）")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Speed Chart

    @ViewBuilder
    private var chartSection: some View {
        let timeline = record.speedTimeline
        if !timeline.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "chart.xyaxis.line")
                        .foregroundStyle(.secondary)
                    Text("速度グラフ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Chart {
                    ForEach(timeline.indices, id: \.self) { i in
                        let s = timeline[i]
                        AreaMark(x: .value("時間", s.time),
                                 y: .value("速度", unit.value(fromKmh: s.speed)))
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.cyan.opacity(0.45), .cyan.opacity(0.05)],
                                    startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("時間", s.time),
                                 y: .value("速度", unit.value(fromKmh: s.speed)))
                            .foregroundStyle(.cyan)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    ForEach(splitMarkers, id: \.label) { m in
                        RuleMark(x: .value(m.label, m.time))
                            .foregroundStyle(.orange.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .annotation(position: .top, alignment: .center) {
                                Text(m.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: 1)) { v in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(String(format: "%.0fs", d))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: yAxisMarks) { v in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(String(format: "%.0f", d))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartYScale(domain: 0...chartMaxSpeed)
                .chartPlotStyle { plot in
                    plot.background(Color.white.opacity(0.03))
                }
                .frame(height: 160)
            }
            .padding()
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private var splitMarkers: [(label: String, time: Double)] {
        (0..<4).compactMap { band in
            guard let time = record.splitTime(unit: unit, band: band) else { return nil }
            return (unit.milestoneShortLabels[band], time)
        }
    }

    private var yAxisMarks: [Double] {
        [0] + unit.milestonesKmh.map { unit.value(fromKmh: $0) }
    }

    private var chartMaxSpeed: Double {
        let timelineMax = record.speedTimeline.map { unit.value(fromKmh: $0.speed) }.max() ?? 0
        let baseline = unit == .kmh ? 110.0 : 70.0
        return max(baseline, timelineMax * 1.1)
    }

    // MARK: - Acceleration (速度タイムラインから導出)

    /// 縦加速度カーブ (m/s²)。高精度(CoreMotion 100Hz)を記録している新しい計測のみ。
    /// 旧レコード（accelTimelineが空）は表示しない。
    private var accelCurve: [(time: Double, accel: Double)] {
        let motion = record.accelTimeline
        guard !motion.isEmpty else { return [] }
        // 100Hz：±7サンプル(≈150ms)の移動平均で振動ノイズを平滑化
        return smoothed(motion.map { ($0.time, $0.accel) }, half: 7)
    }

    private func smoothed(_ raw: [(Double, Double)], half: Int) -> [(time: Double, accel: Double)] {
        guard !raw.isEmpty else { return [] }
        return raw.indices.map { i in
            let lo = max(0, i - half), hi = min(raw.count - 1, i + half)
            let avg = raw[lo...hi].reduce(0.0) { $0 + $1.1 } / Double(hi - lo + 1)
            return (raw[i].0, avg)
        }
    }

    /// 最大加速度 (m/s²)：平滑化カーブのピーク
    private var peakAccelMs2: Double { accelCurve.map(\.accel).max() ?? 0 }

    @ViewBuilder
    private var accelChartSection: some View {
        let curve = accelCurve
        if !curve.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(.secondary)
                    Text("加速度グラフ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("最大").font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.2fG", peakAccelMs2 / 9.81))
                        .font(.caption2.bold()).foregroundStyle(.green)
                }

                Chart {
                    ForEach(curve.indices, id: \.self) { i in
                        let s = curve[i]
                        // 加速度カーブは緑（スプリット線のオレンジと区別する）。縦軸もG表記（1G=9.81m/s²）
                        AreaMark(x: .value("時間", s.time),
                                 y: .value("加速度", s.accel / 9.81))
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [.green.opacity(0.4), .green.opacity(0.03)],
                                    startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("時間", s.time),
                                 y: .value("加速度", s.accel / 9.81))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                    ForEach(splitMarkers, id: \.label) { m in
                        RuleMark(x: .value(m.label, m.time))
                            .foregroundStyle(.orange.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                            .annotation(position: .top, alignment: .center) {
                                Text(m.label)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: 1)) { v in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(String(format: "%.0fs", d))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { v in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.1))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(String(format: "%.1fG", d))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .chartPlotStyle { plot in
                    plot.background(Color.white.opacity(0.03))
                }
                .frame(height: 140)

                Text("単位 G（1G=9.8m/s²・加速度センサー100Hz）")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Stats

    // MARK: - Log

    @ViewBuilder
    private var logSection: some View {
        if record.hasLog, let logURL = MeasurementLogger.logFileURL(record.logFileName),
           FileManager.default.fileExists(atPath: logURL.path) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("センサーログ (CSV)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ShareLink(
                    item: logURL,
                    preview: SharePreview("センサーログ",
                                         icon: Image(systemName: "doc.text"))
                ) {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding()
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        // 速度精度はヘッダーのGPSインジケーター（速度±X BEST/…）で表示済みのため、
        // ここでは重複を避け最高速度のみを表示する
        HStack(spacing: 0) {
            StatItem(label: String(localized: "最高速度"),
                     value: record.maxSpeedKmh > 0
                         ? String(format: "%.1f \(unit.label)", unit.value(fromKmh: record.maxSpeedKmh))
                         : "--")
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private var startCoord: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: record.startLatitude, longitude: record.startLongitude)
    }

    private var endCoord: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: record.endLatitude, longitude: record.endLongitude)
    }

    // 実走ルート座標列（記録済みなら使用、なければ始点・終点の2点）
    private var routePolylineCoords: [CLLocationCoordinate2D] {
        let route = record.routeCoordinates
        return route.count >= 2 ? route : [startCoord, endCoord]
    }

    private var mapRegion: MKCoordinateRegion {
        let coords = routePolylineCoords
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        let minLat = lats.min() ?? startCoord.latitude
        let maxLat = lats.max() ?? startCoord.latitude
        let minLon = lons.min() ?? startCoord.longitude
        let maxLon = lons.max() ?? startCoord.longitude
        let dLat = max((maxLat - minLat) * 4, 0.005)
        let dLon = max((maxLon - minLon) * 4, 0.005)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                           longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: dLat, longitudeDelta: dLon)
        )
    }

    private func gpsColor(_ record: MeasurementRecord) -> Color {
        let spd = record.gpsSpeedAccuracy
        if spd >= 0 {
            if spd < 0.3  { return .blue }
            if spd < 1.0  { return .green }
            if spd < 2.0  { return .yellow }
            return .red
        }
        let acc = record.gpsAccuracy
        if acc < 0  { return .red }
        if acc < 3  { return .blue }
        if acc < 10 { return .green }
        if acc < 30 { return .yellow }
        return .red
    }

    private func gpsLabel(_ record: MeasurementRecord) -> String {
        let spd = record.gpsSpeedAccuracy
        if spd >= 0 {
            let v = String(format: "%.1f", unit.value(fromKmh: spd * 3.6))
            if spd < 0.3  { return String(localized: "速度±\(v)\(unit.label) BEST") }
            if spd < 1.0  { return String(localized: "速度±\(v)\(unit.label) GOOD") }
            if spd < 2.0  { return String(localized: "速度±\(v)\(unit.label) FAIR") }
            return String(localized: "速度±\(v)\(unit.label) POOR")
        }
        let acc = record.gpsAccuracy
        guard acc >= 0 else { return String(localized: "GPS不明") }
        let v0 = String(format: "%.1f", acc)
        let v1 = String(format: "%.0f", acc)
        if acc < 3  { return String(localized: "±\(v0)m BEST") }
        if acc < 10 { return String(localized: "±\(v1)m GOOD") }
        if acc < 30 { return String(localized: "±\(v1)m FAIR") }
        return String(localized: "±\(v1)m POOR")
    }
}

// MARK: - Sub-views

struct DetailSplitRow: View {
    let label: String
    let value: Double?
    var isHighlight: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: isHighlight ? 16 : 14,
                              weight: isHighlight ? .bold : .regular))
                .foregroundStyle(isHighlight ? .white : .secondary)
            Spacer()
            if let v = value {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.3f", v))
                        .font(.system(size: isHighlight ? 28 : 20,
                                      weight: .bold,
                                      design: .monospaced))
                        .foregroundStyle(isHighlight ? Color.yellow : .white)
                    Text("秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("--")
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(.gray)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, isHighlight ? 14 : 10)
        .background(isHighlight ? Color.yellow.opacity(0.08) : Color.clear)
    }
}

struct StatItem: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Full Screen Video

struct FullScreenVideoView: View {
    let player: AVPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.black.opacity(0.5))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
    }
}
