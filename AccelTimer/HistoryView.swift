import SwiftUI
import SwiftData

enum HistorySortOrder: String, CaseIterable {
    case time = "タイム順"
    case date = "日付順"
}

struct HistoryView: View {
    @Query(sort: \MeasurementRecord.date, order: .reverse)
    private var records: [MeasurementRecord]

    @Environment(\.modelContext) private var modelContext
    // editMode は List に注入する自前の状態で管理する。
    // （@Environment(\.editMode) は NavigationStack 外側の値＝nil を指し、List に効かないため）
    @State private var editMode: EditMode = .inactive
    @State private var sortOrder: HistorySortOrder = .time
    @State private var bandIndex: Int = 3   // 0..3 のマイルストーン帯（3=ヘッドライン）
    @AppStorage("speedUnit") private var speedUnitRaw: String = SpeedUnit.defaultForLocale.rawValue
    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }

    private var sortedRecords: [MeasurementRecord] {
        switch sortOrder {
        case .date:
            // 「日付順から除外」したレコードは非表示（タイム順には残り得る）
            return records.filter { !$0.hiddenFromDate }
        case .time:
            // 「タイム順から除外」したレコードは全速度帯で非表示（日付順には残り得る）
            return records
                .filter { !$0.hiddenFromTime }
                .compactMap { rec -> (MeasurementRecord, Double)? in
                    guard let t = rec.splitTime(unit: unit, band: bandIndex) else { return nil }
                    return (rec, t)
                }
                .sorted { $0.1 < $1.1 }
                .map(\.0)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if records.isEmpty {
                    ContentUnavailableView(
                        "計測履歴なし",
                        systemImage: "gauge.high",
                        description: Text("計測タブでスタートしてください")
                    )
                } else {
                    VStack(spacing: 0) {
                        Picker("並び替え", selection: $sortOrder) {
                            ForEach(HistorySortOrder.allCases, id: \.self) {
                                Text(LocalizedStringKey($0.rawValue)).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, sortOrder == .time ? 4 : 8)
                        .background(Color.black)

                        if sortOrder == .time {
                            Picker("速度帯", selection: $bandIndex) {
                                ForEach(0..<4, id: \.self) { i in
                                    Text(unit.milestoneLabels[i]).tag(i)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .background(Color.black)
                        }

                        List {
                            ForEach(sortedRecords) { record in
                                NavigationLink {
                                    MeasurementDetailView(record: record, isBest: isBest(record))
                                } label: {
                                    HistoryRow(record: record, isBest: isBest(record),
                                               unit: unit, band: activeBand)
                                }
                                .listRowBackground(Color.white.opacity(0.04))
                            }
                            .onDelete(perform: deleteRecords)
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .environment(\.editMode, $editMode)
                    }
                }
            }
            .navigationTitle("履歴")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // 国コード未取得のレコードを逆ジオコーディングで後追い付与（将来の国別ランキング用）
                await CountryGeocoder.shared.backfill(records: records)
            }
            .toolbar {
                if !records.isEmpty {
                    // システム EditButton は言語追従しないことがあるため自前のローカライズボタンを使う
                    Button {
                        withAnimation {
                            editMode = editMode.isEditing ? .inactive : .active
                        }
                    } label: {
                        Text(editMode.isEditing ? LocalizedStringKey("完了") : LocalizedStringKey("編集"))
                    }
                    .tint(.red)
                }
            }
        }
    }

    private var activeBand: Int {
        sortOrder == .time ? bandIndex : 3
    }

    private func isBest(_ record: MeasurementRecord) -> Bool {
        // タイム順から除外された記録はベスト（★）対象外（リーダーボード上の最速を表すため）
        guard !record.hiddenFromTime else { return false }
        guard let value = record.splitTime(unit: unit, band: activeBand) else { return false }
        let best = records
            .filter { !$0.hiddenFromTime }
            .compactMap { $0.splitTime(unit: unit, band: activeBand) }
            .min()
        return best.map { value <= $0 } ?? false
    }

    /// スワイプ削除＝「今見ている並びから除外」。両方の並びから出なくなったら実体を完全削除する。
    private func deleteRecords(at offsets: IndexSet) {
        for record in offsets.map({ sortedRecords[$0] }) {
            switch sortOrder {
            case .date: record.hiddenFromDate = true
            case .time: record.hiddenFromTime = true
            }
            // 日付順・タイム順のどちらにも出なくなったら動画・ログごと完全削除
            let visibleInDate = !record.hiddenFromDate
            let visibleInTime = !record.hiddenFromTime && record.split40 > 0  // 0→40到達＝タイム順に出る
            if !visibleInDate && !visibleInTime {
                record.deleteVideoFile()
                record.deleteLogFile()
                modelContext.delete(record)
            }
        }
    }
}

// MARK: - Row

struct HistoryRow: View {
    let record: MeasurementRecord
    let isBest: Bool
    var unit: SpeedUnit = .kmh
    var band: Int = 3

    private var featuredLabel: String {
        "\(unit.milestoneLabels[band]) \(unit.label)"
    }

    private var featuredTime: Double? {
        record.splitTime(unit: unit, band: band)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // ヘッダー：GPS・日時
            HStack {
                Circle()
                    .fill(gpsColor(record))
                    .frame(width: 8, height: 8)
                Text(gpsLabel(record))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let flag = record.countryFlag {
                    Text(flag)
                        .font(.caption2)
                }
                if record.hasVideo {
                    Image(systemName: "video.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(Self.dateFormatter.string(from: record.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // メインタイム
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(featuredLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(featuredTime.map { String(format: "%.3f", $0) } ?? "--")
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .foregroundStyle(isBest ? Color.yellow : .white)
                        if featuredTime != nil {
                            Text("秒")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if isBest {
                            HStack(spacing: 0) {
                                Image(systemName: "star.fill")
                                Text("ベスト")
                            }
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        }
                        if featuredTime != nil && record.isReferenceOnly {
                            HStack(spacing: 2) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                Text("参考値")
                            }
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
                if band == 3 && featuredTime == nil {
                    Text("未達成")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.3))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                        .padding(.top, 18)
                }
            }

            // スプリット（フィーチャー帯以外のマイルストーンをタグ表示）
            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { i in
                    if i != band {
                        SplitTag(label: unit.milestoneShortLabels[i],
                                 value: record.splitTime(unit: unit, band: i) ?? 0)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func gpsColor(_ record: MeasurementRecord) -> Color {
        // 速度精度（Doppler）が記録されていればそちらを優先
        let spd = record.gpsSpeedAccuracy
        if spd >= 0 {
            if spd < 0.3  { return .blue }
            if spd < 1.0  { return .green }
            if spd < 2.0  { return .yellow }
            return .red
        }
        // 旧レコード（速度精度未記録）は水平精度で判定
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

struct SplitTag: View {
    let label: String
    let value: Double

    var body: some View {
        VStack(spacing: 2) {
            Text("0→\(label)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value > 0 ? String(format: "%.3f", value) : "--")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(value > 0 ? Color.white.opacity(0.8) : .gray)
        }
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: MeasurementRecord.self, inMemory: true)
        .preferredColorScheme(.dark)
}
