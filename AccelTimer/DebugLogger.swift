import Foundation

/// 調査用の「常時ログ」。計測ごとのログ(MeasurementLogger)と異なり、
/// 計測が保存されなくても・トリガーされなくても、センサーが動いている間ずっと追記し続ける。
/// 「ログに残らないのに挙動がおかしい」ケース（未トリガー・各種abort等）を後から追える。
///
/// 出力先: Documents/debug/debug.csv（ファイルApp の「このiPhone内 → AccelTimer → debug」で取得可）
/// サイズが上限を超えたら debug_prev.csv へローテーションして無限肥大を防ぐ。
@MainActor
final class DebugLogger {
    static let shared = DebugLogger()

    private let dir: URL
    private let current: URL
    private let previous: URL
    private var handle: FileHandle?
    private var currentSize: UInt64 = 0
    private var sinceSync = 0

    private static let maxBytes: UInt64 = 12_000_000   // 12MB でローテーション（≈ 数時間ぶん）
    private static let header =
        "wall_time,state,gps_mps,gps_acc_mps,h_acc_m,speed_kmh,peak_kmh,conf_stopped,dev_steady,event\n"

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("debug", isDirectory: true)
        current  = dir.appendingPathComponent("debug.csv")
        previous = dir.appendingPathComponent("debug_prev.csv")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        openCurrent()
    }

    private func openCurrent() {
        if !FileManager.default.fileExists(atPath: current.path) {
            try? Self.header.data(using: .utf8)?.write(to: current)
        }
        handle = try? FileHandle(forWritingTo: current)
        // 末尾へシーク。返り値の offset がそのまま現在のファイルサイズ（全文読み込みは不要）
        currentSize = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotateIfNeeded() {
        guard currentSize >= Self.maxBytes else { return }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        currentSize = 0
        openCurrent()
    }

    private func append(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        handle?.write(data)
        currentSize += UInt64(data.count)
        sinceSync += 1
        // アプリが落ちてもデータが残るよう定期的にディスクへ同期
        if sinceSync >= 50 { try? handle?.synchronize(); sinceSync = 0 }
        rotateIfNeeded()
    }

    // wall_time は端末ローカル時刻で出力する（例: 2026-06-21T20:09:49.080+09:00）。
    // 解析時に時差換算が不要になる。
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    /// GPS サンプルごとに呼ぶ（状態・トリガー判定材料を記録）。
    func logGPS(state: String, gpsMps: Double, accMps: Double, hAccM: Double,
                speedKmh: Double, peakKmh: Double,
                confirmedStopped: Bool, deviceSteady: Bool, event: String = "") {
        let t = Self.iso.string(from: Date())
        append(String(format: "%@,%@,%.4f,%.4f,%.2f,%.2f,%.2f,%d,%d,%@\n",
                      t, state, gpsMps, accMps, hAccM, speedKmh, peakKmh,
                      confirmedStopped ? 1 : 0, deviceSteady ? 1 : 0, event))
    }

    /// 状態遷移・特殊イベント（ARM / START / FINISH / 各種abort 等）。
    func logEvent(_ name: String, state: String) {
        let t = Self.iso.string(from: Date())
        append("\(t),\(state),,,,,,,,\(name)\n")
    }
}
