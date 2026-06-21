import SwiftUI
import SwiftData
import AVFoundation
import UIKit

struct SettingsView: View {
    @Query private var records: [MeasurementRecord]
    @AppStorage("autoResetAfterFinish") private var autoReset: Bool = true
    @AppStorage("speakEnabled") private var speakEnabled: Bool = true
    @AppStorage("videoRecordingEnabled") private var videoEnabled: Bool = false
    @AppStorage("videoAudioEnabled") private var audioEnabled: Bool = true
    @AppStorage("speedUnit") private var speedUnitRaw: String = SpeedUnit.defaultForLocale.rawValue
    @Environment(StoreManager.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var restoring = false
    @State private var showPaywall = false
    @State private var showDisclaimer = false
    @State private var showCameraDeniedAlert = false
    @State private var showMicDeniedAlert = false
    private var selectedUnit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }

#if DEBUG
    /// 検証用：共有対象の診断ログ（debug.csv / debug_prev.csv / logs/*.csv のうち存在するもの）。
    private var diagnosticLogURLs: [URL] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var urls: [URL] = []
        let debugDir = docs.appendingPathComponent("debug", isDirectory: true)
        for name in ["debug.csv", "debug_prev.csv"] {
            let u = debugDir.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { urls.append(u) }
        }
        let logsDir = docs.appendingPathComponent("logs", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: logsDir, includingPropertiesForKeys: nil) {
            urls.append(contentsOf: files.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent < $1.lastPathComponent })
        }
        return urls
    }

    /// 検証用：診断ログを 1 つのフォルダにまとめ、ZIP 化した一時ファイルの URL を返す。
    /// AirDrop 先（Mac のダウンロード直下）は送信側から指定できないため、フォルダ＝ZIP にして
    /// 散らからないようにする（解凍するとフォルダになる）。
    private func makeLogsZipURL() -> URL? {
        let fm = FileManager.default
        let urls = diagnosticLogURLs
        guard !urls.isEmpty else { return nil }
        let stampFmt = DateFormatter()
        stampFmt.locale = Locale(identifier: "en_US_POSIX")
        stampFmt.dateFormat = "yyyyMMdd_HHmmss"
        let folderName = "AccelTimer-logs-\(stampFmt.string(from: Date()))"
        let folder = fm.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true)
        try? fm.removeItem(at: folder)
        guard (try? fm.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        for u in urls {
            try? fm.copyItem(at: u, to: folder.appendingPathComponent(u.lastPathComponent))
        }
        // NSFileCoordinator(.forUploading) はフォルダを ZIP 化した一時ファイルを渡す
        var zipURL: URL?
        var coordErr: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordErr) { tmpZip in
            let dest = fm.temporaryDirectory.appendingPathComponent("\(folderName).zip")
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: tmpZip, to: dest)) != nil { zipURL = dest }
        }
        return zipURL
    }

    /// 共有シートを表示してログ ZIP を AirDrop 等で送る。
    private func shareLogsZip() {
        guard let zip = makeLogsZipURL() else { return }
        let av = UIActivityViewController(activityItems: [zip], applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        av.popoverPresentationController?.sourceView = root.view   // iPad 用アンカー
        av.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
        root.present(av, animated: true)
    }
#endif

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section("ライセンス") {
                        if store.isPurchased {
                            Label("購入済み（無制限）", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else {
                            if store.trialExhausted {
                                Text("無料体験（\(StoreManager.freeTrialLimit)回）を使い切りました。現在は1日1回まで無料で計測できます。買い切りで無制限になります。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack {
                                    Text("無料体験の残り")
                                    Spacer()
                                    Text("\(store.freeTrialRemaining) / \(StoreManager.freeTrialLimit) 回")
                                        .foregroundStyle(.secondary)
                                }
                                Text("使い切ると1日1回まで無料。買い切りで無制限になります。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button {
                                showPaywall = true
                            } label: {
                                Label("無制限に解放（購入）", systemImage: "lock.open.fill")
                                    .foregroundStyle(.orange)
                            }
                            Button {
                                Task { restoring = true; await store.restore(); restoring = false }
                            } label: {
                                Text(restoring ? "復元中…" : "購入を復元")
                            }
                            .disabled(restoring)
                        }
                    }
                    Section("表示単位") {
                        Picker("速度の単位", selection: $speedUnitRaw) {
                            Text("km/h").tag(SpeedUnit.kmh.rawValue)
                            Text("mph").tag(SpeedUnit.mph.rawValue)
                        }
                        .pickerStyle(.segmented)
                        Text(selectedUnit == .mph
                             ? "画面・履歴・共有カードを 0-60 mph 中心で表示します。計測完了判定は引き続き 100 km/h 到達です。"
                             : "画面・履歴・共有カードを 0-100 km/h 中心で表示します。計測完了判定も 100 km/h 到達です。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("計測完了後の動作") {
                        Toggle("停車で自動再計測", isOn: $autoReset)
                        Text(autoReset
                             ? "計測完了後、停車すると自動で次の計測を開始します"
                             : "計測完了後、「再計測」ボタンを押すまで結果を表示し続けます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("音声") {
                        Toggle("速度読み上げ", isOn: $speakEnabled)
                        Text("\(selectedUnit.milestoneShortLabels.joined(separator: " / ")) \(selectedUnit.label) 通過時に速度を読み上げます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("動画録画") {
                        Toggle("計測中に動画を録画", isOn: $videoEnabled)
                        Text("計測開始から完了まで後方カメラで録画し、速度・タイムをオーバーレイしてアプリ内に保存します。履歴詳細から再生できます")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if cameraPermissionDenied {
                            Label("カメラ権限がないため、動画録画は使えません", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if videoEnabled {
                            Toggle("走行音を録音", isOn: $audioEnabled)
                            Text("走行音を動画に収録します")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if microphonePermissionDenied {
                                Label("マイク権限がないため、音声録音は使えません", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    Section("アプリ情報") {
                        HStack {
                            Text("バージョン")
                            Spacer()
                            Text(AppInfo.version)
                                .foregroundStyle(.secondary)
                        }
                        Button("安全運転と免責事項") { showDisclaimer = true }
                            .foregroundStyle(.white)
                    }
#if DEBUG
                    Section("検証用（DEBUGビルドのみ）") {
                        HStack {
                            Text("無料枠 累計")
                            Spacer()
                            Text("\(store.trialCount) 回・本日\(store.freeUsedToday ? "使用済み" : "未使用")")
                                .foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) {
                            store.resetTrial()
                        } label: {
                            Label("トライアルをリセット", systemImage: "arrow.counterclockwise")
                        }
                        Button {
                            showPaywall = true
                        } label: {
                            Label("購入画面を表示", systemImage: "creditcard")
                        }
                        // 診断ログ（debug.csv＋走行ログ）を1個のZIPにまとめて共有。
                        // AirDrop先（Macのダウンロード直下）は指定不可なので、解凍でフォルダになるZIPにする。
                        if diagnosticLogURLs.isEmpty {
                            Text("診断ログはまだありません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button {
                                shareLogsZip()
                            } label: {
                                Label("診断ログをZIPで共有（\(diagnosticLogURLs.count)件・AirDrop等）",
                                      systemImage: "square.and.arrow.up.on.square")
                            }
                        }
                    }
#endif
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: store) { showPaywall = false }
        }
        .sheet(isPresented: $showDisclaimer) {
            DisclaimerView(isFirstLaunch: false) { showDisclaimer = false }
        }
        .onAppear {
            reconcileVideoPermissionToggles()
        }
        // 動画録画ON時：カメラ許可をその場で確認。拒否ならトグルを戻し案内する
        .onChange(of: videoEnabled) { _, on in
            guard on else { return }
            Task {
                let cam = await VideoRecorder.requestAccess(for: .video)
                if !cam {
                    videoEnabled = false
                    showCameraDeniedAlert = true
                    return
                }
                // 走行音もON（既定）なら続けてマイク許可を確認
                if audioEnabled {
                    let mic = await VideoRecorder.requestAccess(for: .audio)
                    if !mic { audioEnabled = false; showMicDeniedAlert = true }
                }
            }
        }
        // 走行音を個別にON時：マイク許可を確認。拒否ならトグルを戻す（動画は音声なしで録画可）
        .onChange(of: audioEnabled) { _, on in
            guard on, videoEnabled else { return }
            Task {
                let mic = await VideoRecorder.requestAccess(for: .audio)
                if !mic { audioEnabled = false; showMicDeniedAlert = true }
            }
        }
        .alert("カメラへのアクセスが必要です", isPresented: $showCameraDeniedAlert) {
            Button("設定を開く") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
            Button("OK", role: .cancel) {}
        } message: {
            Text("動画録画にはカメラの許可が必要です。設定アプリの AccelTimer でカメラをオンにしてください。")
        }
        .alert("マイクへのアクセスが必要です", isPresented: $showMicDeniedAlert) {
            Button("設定を開く") { if let u = URL(string: UIApplication.openSettingsURLString) { openURL(u) } }
            Button("OK", role: .cancel) {}
        } message: {
            Text("走行音の録音にはマイクの許可が必要です。設定アプリの AccelTimer でマイクをオンにしてください。音声なしでの動画録画は可能です。")
        }
    }

    private var cameraPermissionDenied: Bool {
        permissionDenied(AVCaptureDevice.authorizationStatus(for: .video))
    }

    private var microphonePermissionDenied: Bool {
        permissionDenied(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func permissionDenied(_ status: AVAuthorizationStatus) -> Bool {
        switch status {
        case .denied, .restricted: return true
        case .authorized, .notDetermined: return false
        @unknown default: return true
        }
    }

    private func reconcileVideoPermissionToggles() {
        if videoEnabled && cameraPermissionDenied {
            videoEnabled = false
        }
        if audioEnabled && microphonePermissionDenied {
            audioEnabled = false
        }
    }
}

#Preview {
    SettingsView()
        .environment(StoreManager())
        .preferredColorScheme(.dark)
}
