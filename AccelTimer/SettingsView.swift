import SwiftUI
import SwiftData
import AVFoundation

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

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Form {
                    Section("ライセンス") {
                        if store.isPurchased {
                            Label("購入済み（透かし解除済み）", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else {
                            Text("計測・履歴保存・カード共有は無料です。購入すると共有する結果カードから「体験版」の透かしを外せます。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            // いつでも購入して、共有カードの透かしを消せる。
                            Button {
                                showPaywall = true
                            } label: {
                                Label("結果カードの透かしを消す（購入）", systemImage: "lock.open.fill")
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
                        if videoEnabled {
                            Toggle("走行音を録音", isOn: $audioEnabled)
                            Text("走行音を動画に収録します")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
}

#Preview {
    SettingsView()
        .environment(StoreManager())
        .preferredColorScheme(.dark)
}
