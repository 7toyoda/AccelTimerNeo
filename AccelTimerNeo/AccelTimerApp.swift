import SwiftUI
import SwiftData

@main
struct AccelTimerApp: App {
    init() {
        // 起動時に1回だけ、録画中のクラッシュ等で取り残された一時ファイルを掃除する
        VideoRecorder.pruneOrphanTempFiles()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([MeasurementRecord.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        // まず通常の初期化を試みる
        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }

        // スキーマ変更によるマイグレーション失敗 → 古いDBを削除して再作成
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let base = support.appendingPathComponent("default.store")
        [base,
         URL(fileURLWithPath: base.path + "-wal"),
         URL(fileURLWithPath: base.path + "-shm")].forEach {
            try? FileManager.default.removeItem(at: $0)
        }

        if let container = try? ModelContainer(for: schema, configurations: [config]) {
            return container
        }
        // 永続ストア再作成も失敗：in-memory で起動してクラッシュを防ぐ（履歴は失われるが起動不能は回避）
        let memConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: [memConfig])
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
