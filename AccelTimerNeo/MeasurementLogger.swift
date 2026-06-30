import Foundation

// MARK: - ログエントリ

/// 1サンプル分のセンサーログ。未使用フィールドは .nan で格納（Optional を避けてパフォーマンス優先）
struct LogEntry {
    enum Source: String { case gps = "GPS", motion = "MOTION", event = "EVENT" }

    let wallTime: Date
    let elapsedS: Double        // 計測開始からの秒。開始前は負値、不明は .nan
    let source: Source
    // GPS 専用
    var gpsSpeedMps: Double = .nan
    var gpsAccMps:   Double = .nan
    var hAccM:       Double = .nan
    // Motion 専用
    var accelMps2:   Double = .nan
    // 共通
    var accelSign:   Double = .nan
    var kalmanMps:   Double = .nan
    var displayKmh:  Double = .nan
    // イベント名（ARMED / START / SPLIT_40 / FINISH など）
    var event: String = ""
}

// MARK: - MeasurementLogger

/// 計測セッション中の GPS・加速度・Kalman 状態を CSV に記録するロガー。
/// すべての操作は @MainActor から呼ぶこと。
final class MeasurementLogger {

    private(set) var isActive = false
    private var entries: [LogEntry] = []

    init() { entries.reserveCapacity(3000) }

    // MARK: - ライフサイクル

    func start() {
        entries.removeAll(keepingCapacity: true)
        isActive = true
    }

    /// エントリを保持したまま収集を停止（writeCSV 後に呼ぶ）
    func stop() { isActive = false }

    /// エントリを破棄してリセット（arm 時に呼ぶ）
    func reset() {
        entries.removeAll(keepingCapacity: true)
        isActive = false
    }

    // MARK: - GPS ログ

    func logGPS(wallTime: Date, startTime: Date?,
                speedMps: Double, accMps: Double, hAccM: Double,
                accelSign: Double, kalmanMps: Double, displayKmh: Double,
                event: String = "") {
        guard isActive else { return }
        let elapsed = startTime.map { wallTime.timeIntervalSince($0) } ?? .nan
        entries.append(LogEntry(
            wallTime: wallTime, elapsedS: elapsed, source: .gps,
            gpsSpeedMps: speedMps, gpsAccMps: accMps, hAccM: hAccM,
            accelSign: accelSign, kalmanMps: kalmanMps, displayKmh: displayKmh,
            event: event
        ))
    }

    // MARK: - Motion ログ

    func logMotion(wallTime: Date, startTime: Date?,
                   accelMps2: Double, accelSign: Double, kalmanMps: Double,
                   event: String = "") {
        guard isActive else { return }
        let elapsed = startTime.map { wallTime.timeIntervalSince($0) } ?? .nan
        entries.append(LogEntry(
            wallTime: wallTime, elapsedS: elapsed, source: .motion,
            accelMps2: accelMps2, accelSign: accelSign, kalmanMps: kalmanMps,
            event: event
        ))
    }

    // MARK: - イベントログ

    func logEvent(_ name: String, wallTime: Date = Date(), startTime: Date?) {
        guard isActive else { return }
        let elapsed = startTime.map { wallTime.timeIntervalSince($0) } ?? .nan
        entries.append(LogEntry(
            wallTime: wallTime, elapsedS: elapsed, source: .event, event: name
        ))
    }

    // MARK: - CSV 書き出し

    /// Documents/logs/ に CSV を書き出してファイル名を返す。失敗時は nil。
    func writeCSV(recordDate: Date) -> String? {
        guard !entries.isEmpty else { return nil }

        let fm = FileManager.default
        guard let docURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let logsDir = docURL.appendingPathComponent("logs", isDirectory: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let fileFmt = DateFormatter()
        fileFmt.dateFormat = "yyyyMMdd_HHmmss"
        let filename = "accel_\(fileFmt.string(from: recordDate)).csv"
        let url = logsDir.appendingPathComponent(filename)

        // wall_time は端末ローカル時刻で出力（ファイル名のローカル時刻と一致させ、解析時の時差換算を不要に）
        let isoFmt = ISO8601DateFormatter()
        isoFmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoFmt.timeZone = .current

        var lines = [
            "# AccelTimer v\(AppInfo.version)",
            "wall_time,elapsed_s,source,gps_speed_mps,gps_acc_mps,h_acc_m," +
            "accel_mps2,accel_sign,kalman_mps,display_kmh,event"
        ]

        for e in entries {
            let wall    = isoFmt.string(from: e.wallTime)
            let elapsed = e.elapsedS.isNaN ? "" : String(format: "%.4f", e.elapsedS)
            let gspd    = e.gpsSpeedMps.isNaN ? "" : String(format: "%.4f", e.gpsSpeedMps)
            let gacc    = e.gpsAccMps.isNaN   ? "" : String(format: "%.4f", e.gpsAccMps)
            let hacc    = e.hAccM.isNaN       ? "" : String(format: "%.2f",  e.hAccM)
            let accel   = e.accelMps2.isNaN   ? "" : String(format: "%.5f", e.accelMps2)
            let sign    = e.accelSign.isNaN   ? "" : String(format: "%.1f",  e.accelSign)
            let kalman  = e.kalmanMps.isNaN   ? "" : String(format: "%.4f", e.kalmanMps)
            let disp    = e.displayKmh.isNaN  ? "" : String(format: "%.2f",  e.displayKmh)
            lines.append(
                "\(wall),\(elapsed),\(e.source.rawValue)," +
                "\(gspd),\(gacc),\(hacc),\(accel),\(sign),\(kalman),\(disp),\(e.event)"
            )
        }

        let csv = lines.joined(separator: "\n")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            return filename
        } catch {
            return nil
        }
    }

    // MARK: - ファイル削除

    static func deleteFile(_ filename: String) {
        guard !filename.isEmpty,
              let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }
        let url = docURL.appendingPathComponent("logs").appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }

    static func logFileURL(_ filename: String) -> URL? {
        guard !filename.isEmpty,
              let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return docURL.appendingPathComponent("logs").appendingPathComponent(filename)
    }

    /// logs/ ディレクトリ内のファイルのうち、knownFilenames に含まれないものを削除する。
    /// アプリ起動時に呼び出してレコードと紐付かない孤立ファイルを除去する。
    static func pruneOrphans(knownFilenames: Set<String>) {
        guard let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let logsDir = docURL.appendingPathComponent("logs")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: logsDir.path) else { return }
        for file in files where file.hasSuffix(".csv") && !knownFilenames.contains(file) {
            try? FileManager.default.removeItem(at: logsDir.appendingPathComponent(file))
        }
    }
}
