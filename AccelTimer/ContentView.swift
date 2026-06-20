import SwiftUI
import SwiftData
import UIKit
import AVFoundation

// MARK: - Root

struct ContentView: View {
    @State private var store = StoreManager()
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false
    @AppStorage("hasSeenLocationPrimer") private var hasSeenLocationPrimer = false

    // 起動時オンボーディング：ウェルカム → 安全・同意（免責）→ 位置情報の事前アナウンス
    // →（GPS許可ダイアログは計測画面の arm で発火）。最初をブランド画面にして警戒感を和らげる。
    private enum OnboardingStep { case welcome, disclaimer, primer }
    private var onboardingStep: OnboardingStep? {
        if !hasSeenWelcome { return .welcome }
        if !hasAcceptedDisclaimer { return .disclaimer }
        if !hasSeenLocationPrimer { return .primer }
        return nil
    }

    private enum Tab: Hashable { case measure, history, settings }
    @State private var selectedTab: Tab = .measure

    var body: some View {
        // システム標準のタブバー（iOS 26）は中央寄せのカプセルで横幅が狭い。横幅は
        // フル幅にしつつ、システム同様に縦方向を軽く（薄い背景・コンパクト高）保つため、
        // システムバーを隠してカスタムバーを safeAreaInset で重ねる。TabView は維持して
        // タブ切替でも各タブの @State（MeasureView の engine 等）を保持する。
        TabView(selection: $selectedTab) {
            MeasureView()
                .tag(Tab.measure)
                .toolbar(.hidden, for: .tabBar)
            HistoryView()
                .tag(Tab.history)
                .toolbar(.hidden, for: .tabBar)
            SettingsView()
                .tag(Tab.settings)
                .toolbar(.hidden, for: .tabBar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { customTabBar }
        .preferredColorScheme(.dark)
        .environment(store)
        // 免責 → 事前アナウンスの順に全画面表示（完了するまで閉じられない）。
        // 事前アナウンスを閉じた後、計測画面の arm() が初めて GPS 許可ダイアログを出す。
        .fullScreenCover(isPresented: .init(get: { onboardingStep != nil }, set: { _ in })) {
            switch onboardingStep {
            case .welcome:
                WelcomeView { hasSeenWelcome = true }
            case .disclaimer:
                DisclaimerView(isFirstLaunch: true) { hasAcceptedDisclaimer = true }
            case .primer:
                LocationPrimerView { hasSeenLocationPrimer = true }
            case .none:
                EmptyView()
            }
        }
    }

    // MARK: - カスタムタブバー（フル幅・3等分・システム同等のコンパクト高）

    private var customTabBar: some View {
        HStack(spacing: 0) {
            tabButton(.measure,  title: "計測", icon: "gauge.high")
            tabButton(.history,  title: "履歴", icon: "clock.arrow.circlepath")
            tabButton(.settings, title: "設定", icon: "gearshape")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .background(.bar)   // システムバーと同じ薄い（半透明）背景で縦を軽く保つ
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func tabButton(_ tab: Tab, title: String, icon: String) -> some View {
        let selected = (selectedTab == tab)
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            // 各ボタンを画面幅の 1/3 に広げ、タップ領域を全面に
            .frame(maxWidth: .infinity)
            .foregroundStyle(selected ? Color.white : Color.gray)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Measure

struct MeasureView: View {
    @State private var engine = TimerEngine()
    @Environment(StoreManager.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isVisible = false   // 計測タブが表示中か（scenePhase処理をこのタブに限定）
    @State private var showPaywall = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MeasurementRecord.date, order: .reverse) private var records: [MeasurementRecord]
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @AppStorage("autoResetAfterFinish") private var autoReset: Bool = true
    @AppStorage("videoRecordingEnabled") private var videoEnabled: Bool = false
    @AppStorage("videoAudioEnabled") private var videoAudioEnabled: Bool = true
    // オンボーディング（免責＋事前アナウンス）完了まで arm()＝GPS許可要求を保留する
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false
    @AppStorage("hasSeenLocationPrimer") private var hasSeenLocationPrimer = false
    private var onboardingDone: Bool { hasAcceptedDisclaimer && hasSeenLocationPrimer }
    @State private var gpsPulse: Bool = false
    @State private var readyPulse: Bool = false
    @State private var runningPulse: Bool = false
    @State private var runningGlow: Bool = false
    @State private var edgeAngle: Double = 0
    @State private var recorder = VideoRecorder()
    @State private var isVideoRecording = false
    @State private var overlayTimer: Timer? = nil   // 録画中のみ動くオーバーレイ更新タイマー(30Hz)
    @State private var recordingStopTask: Task<Void, Never>? = nil
    @State private var recordingStartDate: Date? = nil
    @State private var runLaunchTime: Date? = nil   // 発進点（動画トリミング基準）
    @State private var videoSessionReady = false    // カメラセッション構築完了（プリロール可否）
    @State private var videoSavedToast = false
    @State private var videoErrorMessage: String? = nil
    @State private var pendingVideoFileName: String? = nil
    @State private var backgroundAbortToast = false
    // 無料の保存上限に達したペイウォールを一度提示したら、空きができるまで連発しない
    @State private var freeLimitNoticeShown = false

    private static let splitLabels = ["0→40", "0→60", "0→80", "0→100"]

    /// 完了/中断後の保存を試みる。無料の保存上限なら保存せず待機へ戻し、解放を促す。
    /// 計測自体は無料なので、保存できなくても arm() で次の計測へ進める。
    private func attemptSaveAndArm() {
        if store.canSaveAnother(currentCount: records.count) {
            engine.saveAndArm(context: modelContext)
        } else {
            // 保存上限：レコードを保存しない。arm() の finished→armed 遷移で動画だけ
            // 保存され、対応レコードが無く孤立／別計測へ誤ひも付けされるのを防ぐため、
            // 先に録画を破棄して isVideoRecording を落とす。
            discardCurrentVideo()
            engine.arm()
            presentFreeLimitPaywall()
        }
    }

    /// autoReset=OFF 完了時の保存を試みる。上限なら保存せず結果表示を維持し、解放を促す。
    private func attemptSaveResult() {
        if store.canSaveAnother(currentCount: records.count) {
            stopVideoRecordingIfNeeded()              // レコードと対で動画を保存
            engine.saveResult(context: modelContext)
        } else {
            discardCurrentVideo()                      // 上限：動画も保存しない
            presentFreeLimitPaywall()
        }
    }

    /// 録画中の動画を保存せず破棄する。保存上限でレコードを残さない時に、動画だけ
    /// 保存されて孤立・別計測への誤ひも付けが起きるのを防ぐ。
    private func discardCurrentVideo() {
        recordingStopTask?.cancel()
        recordingStopTask = nil
        recorder.cancelAndDiscard()
        isVideoRecording = false
    }

    /// 無料の保存上限ペイウォールを提示（同一上限セッション中は1回だけ）。
    private func presentFreeLimitPaywall() {
        guard !freeLimitNoticeShown else { return }
        freeLimitNoticeShown = true
        showPaywall = true
    }

    // 各速度帯のベストタイム
    private var best40:  Double? { records.compactMap { $0.split40  > 0 ? $0.split40  : nil }.min() }
    private var best60:  Double? { records.compactMap { $0.split60  > 0 ? $0.split60  : nil }.min() }
    private var best80:  Double? { records.compactMap { $0.split80  > 0 ? $0.split80  : nil }.min() }
    private var best100: Double? { records.filter { $0.isComplete }.map { $0.totalTime }.min() }
    private var bests: [Double?] { [best40, best60, best80, best100] }

    private var measureContent: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showRunningVisuals {
                runningEdgeGlow
                SpeedLinesView()
            }
            if verticalSizeClass == .compact {
                landscapeLayout
            } else {
                portraitLayout
            }
            // バックグラウンド移行による計測中止トースト
            if backgroundAbortToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("バックグラウンド移行により計測を中止しました")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(Capsule())
                    .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: backgroundAbortToast)
            }
            // 動画保存完了トースト
            if videoSavedToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("動画を履歴に保存しました")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Capsule())
                    .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: videoSavedToast)
            }
            // 動画エラートースト
            if let msg = videoErrorMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(msg)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 100)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.3), value: msg)
                .onTapGesture { videoErrorMessage = nil }
                .task(id: msg) {
                    try? await Task.sleep(for: .seconds(5))
                    videoErrorMessage = nil
                }
            }
            // 位置情報が拒否/制限されている：計測不可のためガイドを最前面に表示
            if engine.locationDenied {
                locationDeniedOverlay
            }
        }
    }

    private var measureStage1: some View {
        measureContent
        .onChange(of: engine.autoResetRequested) { _, requested in
            guard requested else { return }
            if autoReset || engine.state != .finished {
                attemptSaveAndArm()
                // saveAndArm → arm() → state=.armed の onChange で録画停止される
            } else {
                // autoReset=OFF かつ finished: state が .armed にならないため、保存/破棄は
                // attemptSaveResult が動画とレコードを対で扱う（上限時は両方とも保存しない）。
                attemptSaveResult()
            }
        }
        .onChange(of: engine.state) { oldState, state in handleStateChange(oldState, state) }
        .onChange(of: autoReset) { _, newValue in
            guard newValue, engine.state == .finished else { return }
            Task { @MainActor in
                if engine.isResultSaved {
                    engine.arm()
                } else if engine.autoResetRequested {
                    attemptSaveAndArm()
                }
            }
        }
        .onAppear {
            isVisible = true
            UIApplication.shared.isIdleTimerDisabled = true
            engine.bestTimes = bests
            // 計測は常に無料・無制限。idle なら待機開始（オンボーディング完了後のみ）。
            if engine.state == .idle {
                if onboardingDone { engine.arm() }
            } else {
                engine.resumeSensors()               // .armed: GPS+Motion再開
                engine.restartLocationIfFinished()   // .finished: GPS再開（停車検知のため）
            }
            setupVideoRecorder()
            // レコードに紐付かない孤立ログファイルを削除（persistResult後にrecord保存が失敗した場合の対策）
            let knownLogs = Set(records.map(\.logFileName).filter { !$0.isEmpty })
            MeasurementLogger.pruneOrphans(knownFilenames: knownLogs)
            // バックグラウンド移行による計測中止を通知
            if engine.backgroundAbortedRun {
                engine.clearBackgroundAbortFlag()
                backgroundAbortToast = true
                Task { try? await Task.sleep(for: .seconds(3)); backgroundAbortToast = false }
            }
        }
        .onChange(of: records) { _, _ in
            engine.bestTimes = bests
            // 履歴削除などで空きができたら、上限ペイウォールの再提示を許可する
            if store.canSaveAnother(currentCount: records.count) { freeLimitNoticeShown = false }
            applyPendingVideoFileName()
            // 新規保存レコードの国コードを後追い付与（将来の国別ランキング用）
            Task { await CountryGeocoder.shared.backfill(records: records) }
        }
        .onChange(of: pendingVideoFileName) { _, filename in
            guard filename != nil else { return }
            applyPendingVideoFileName()
        }
        // 省電力：オーバーレイ更新は「録画中のみ」動く30Hzタイマーで行う。
        // （旧実装は elapsedTime/fusedSpeedKmh の100Hz onChangeで、非録画時も画面再描画を100Hz誘発していた）
        .onChange(of: isVideoRecording) { _, recording in
            if recording { startOverlayTimer() } else { stopOverlayTimer() }
        }
        // 停車を確認してからプリロール録画を開始（待機中ずっとカメラを回さず省電力。発進は停車後なので取りこぼさない）
        .onChange(of: engine.confirmedStoppedWhileArmed) { _, stopped in
            if stopped { startPrerollIfNeeded() }
        }
        // GPS精度に追従：待機中(ARMED)にGPS確認中(赤)へ落ちたら録画を止め、良好に戻れば再開。
        // 録画をREADY表示と同じ条件に揃える。計測中(RUNNING)は止めない。
        .onChange(of: gpsIsRed) { _, red in
            if red {
                if isVideoRecording && engine.state != .running {
                    recorder.cancelAndDiscard()
                    isVideoRecording = false
                }
            } else {
                startPrerollIfNeeded()
            }
        }
    }

    var body: some View {
        measureStage1
        // 購入完了（または起動時の権利確認）でペイウォールを閉じる。
        .onChange(of: store.isPurchased) { _, purchased in
            if purchased { showPaywall = false; freeLimitNoticeShown = false }
        }
        // 事前アナウンス完了（許可ダイアログ後）→ idle なら待機開始。免責→アナウンス後にarmが初めて走る
        .onChange(of: hasSeenLocationPrimer) { _, seen in
            if seen, engine.state == .idle { engine.arm() }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(store: store) { showPaywall = false }
        }
        .onChange(of: videoEnabled) { _, enabled in
            if enabled {
                setupVideoRecorder()
            } else {
                recorder.cancelAndDiscard()
                isVideoRecording = false
                videoSessionReady = false
                recorder.teardown()
            }
        }
        .onChange(of: videoAudioEnabled) { _, _ in
            guard videoEnabled else { return }
            recorder.cancelAndDiscard()
            isVideoRecording = false
            videoSessionReady = false
            recorder.teardown()
            setupVideoRecorder()
        }
        .onChange(of: scenePhase) { _, phase in handleScenePhase(phase) }
        .onDisappear {
            isVisible = false
            stopOverlayTimer()
            UIApplication.shared.isIdleTimerDisabled = false
            engine.pauseSensors()  // ARMED のときのみ停止
            if engine.state == .running {
                // 計測中のバックグラウンド移行: CoreMotion が停止して精度不足になるため中止
                // onChange(.armed) が stopVideoRecordingIfNeeded を呼ぶ前に isVideoRecording を落とす
                recorder.cancelAndDiscard()
                isVideoRecording = false
                engine.abortRunDueToBackground()  // state → .armed
            } else if engine.state == .finished {
                // 上限でレコードが残らない時は動画も保存しない（孤立・誤ひも付け防止）。
                // 既に保存済みなら isVideoRecording=false で no-op。
                if store.canSaveAnother(currentCount: records.count) {
                    stopVideoRecordingIfNeeded()
                } else {
                    discardCurrentVideo()
                }
                engine.pauseLocationIfFinished()  // GPS停止でバッテリー節約
            } else {
                recorder.cancelAndDiscard()
                isVideoRecording = false
            }
            recorder.teardown()
            videoSessionReady = false
        }
    }

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            statusBar
                .padding(.top, 8)
                .padding(.horizontal, 20)

            Spacer()

            speedDisplay

            Spacer().frame(height: 12)

            timeDisplay

            Spacer()

            splitGrid
                .padding(.horizontal, 16)

            Spacer()

            actionArea
                .padding(.bottom, 32)
                .padding(.horizontal, 32)
        }
    }

    private var landscapeLayout: some View {
        VStack(spacing: 0) {
            statusBar
                .padding(.top, 4)
                .padding(.horizontal, 20)
            HStack(spacing: 0) {
                // 左ペイン：速度・タイム・ボタン
                VStack(spacing: 0) {
                    Spacer()
                    speedDisplayLandscape
                    Spacer().frame(height: 4)
                    timeDisplay
                    Spacer()
                    actionArea
                        .padding(.bottom, 12)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity)

                // 右ペイン：スプリット
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        SplitCell(label: Self.splitLabels[0], time: engine.splits[0], best: bests[0], compact: true)
                        SplitCell(label: Self.splitLabels[1], time: engine.splits[1], best: bests[1], compact: true)
                    }
                    GridRow {
                        SplitCell(label: Self.splitLabels[2], time: engine.splits[2], best: bests[2], compact: true)
                        SplitCell(label: Self.splitLabels[3], time: engine.splits[3], best: bests[3], compact: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Sub-views

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(gpsColor)
                .frame(width: 10, height: 10)
            Text(gpsAccuracyLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isVideoRecording {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC")
                        .font(.caption2.bold())
                        .foregroundStyle(.red)
                }
            }
            Text(stateLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }

    private var isRunning: Bool { engine.state == .running }
    // 画面が縦に短い端末（iPhone SE等, 4.7インチ=667pt）か。要素を小さくして上下の余白を確保する。
    private var isShortScreen: Bool { UIScreen.main.bounds.height < 700 }
    // 計測中の演出を出すか
    private var showRunningVisuals: Bool { isRunning }

    // 速度表示文字列。GPS確認中(赤)で待機中は「速度不明」を表す "-.-"（0.0=停車中と区別）。
    // 画面表示は ~10Hz に間引いた displaySpeedKmh を使う（fusedSpeedKmh=100Hzは動画オーバーレイ用）。
    private var speedText: String {
        if gpsIsRed && (engine.state == .idle || engine.state == .armed) {
            return "-.-"
        }
        return String(format: "%.1f", engine.displaySpeedKmh)
    }

    // 計測中だけ表示する、画面の淵を流れるエッジグロー。
    // 外周＝原色（フル彩度の虹）のみ。中央は見やすく保つ。
    private var runningEdgeGlow: some View {
        // フル彩度＝原色の虹（端で 0 と 1.0 が一致しループが繋がる）
        let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0)
            .map { Color(hue: $0, saturation: 1.0, brightness: 1.0) }
        // 描画負荷軽減のため単層（全画面ブラーは高負荷なので層数・半径を抑える）。
        // 画面の角が丸いため、角ばったRectangleだと四隅でグローがはみ出して細く見える。
        // 画面の丸みに合わせたRoundedRectangleにして四辺・四隅で同じ幅にする。
        return ZStack {
            // 外周：原色（くっきり）のみ。内側の白みは廃止。
            RoundedRectangle(cornerRadius: 55, style: .continuous)
                .stroke(AngularGradient(gradient: Gradient(colors: hues),
                                        center: .center, angle: .degrees(edgeAngle)),
                        lineWidth: 34)
                .blur(radius: 12)
                .blendMode(.plusLighter)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(runningGlow ? 1.0 : 0.78)
        .transition(.opacity)
        .onAppear {
            edgeAngle = 0
            runningGlow = false
            // 色を淵に沿って流す（高速回転：2秒で一周）
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                edgeAngle = 360
            }
            // 全体の明滅
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                runningGlow = true
            }
        }
        .onDisappear { runningGlow = false }
    }

    private var speedDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("km/h")
                .font(.title2)
                .hidden()
            Text(speedText)
                .font(.system(size: isShortScreen ? (showRunningVisuals ? 84 : 78) : (showRunningVisuals ? 108 : 100),
                              weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .shadow(color: showRunningVisuals ? .white.opacity(0.6) : .clear,
                        radius: showRunningVisuals ? 12 : 0)
                // 全状態で即時更新（トゥイーンなし）。RUNNING/FINISHEDは100Hzモーション補間で滑らか、
                // 待機(armed/idle)はGPS(1Hz)を即時反映（1秒トゥイーンは見難いとの指摘で廃止）
                .animation(nil, value: engine.displaySpeedKmh)
                .animation(.easeOut(duration: 0.3), value: isRunning)
            Text("km/h")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var speedDisplayLandscape: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("km/h")
                .font(.title3)
                .hidden()
            Text(speedText)
                .font(.system(size: showRunningVisuals ? 78 : 72, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .shadow(color: showRunningVisuals ? .white.opacity(0.6) : .clear,
                        radius: showRunningVisuals ? 10 : 0)
                // 全状態で即時更新（トゥイーンなし）。RUNNING/FINISHEDは100Hzモーション補間で滑らか、
                // 待機(armed/idle)はGPS(1Hz)を即時反映（1秒トゥイーンは見難いとの指摘で廃止）
                .animation(nil, value: engine.displaySpeedKmh)
                .animation(.easeOut(duration: 0.3), value: isRunning)
            Text("km/h")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var timeDisplay: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(formatTime(engine.displayElapsedTime))   // 画面用は~15Hz間引き（オーバーレイはelapsedTime=100Hz）
                .font(.system(size: isShortScreen ? (showRunningVisuals ? 46 : 42) : (showRunningVisuals ? 58 : 52),
                              weight: showRunningVisuals ? .bold : .medium, design: .monospaced))
                .foregroundStyle(showRunningVisuals ? Color.yellow : .white)
                .monospacedDigit()
                .shadow(color: showRunningVisuals ? Color.yellow.opacity(0.8) : .clear,
                        radius: showRunningVisuals ? 14 : 0)
                // 時間も即時更新（numericTextモーフィングは高頻度更新で逆効果）
                .animation(.easeOut(duration: 0.3), value: isRunning)
            Text("秒")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var splitGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                SplitCell(label: Self.splitLabels[0], time: engine.splits[0], best: bests[0], compact: isShortScreen)
                SplitCell(label: Self.splitLabels[1], time: engine.splits[1], best: bests[1], compact: isShortScreen)
            }
            GridRow {
                SplitCell(label: Self.splitLabels[2], time: engine.splits[2], best: bests[2], compact: isShortScreen)
                SplitCell(label: Self.splitLabels[3], time: engine.splits[3], best: bests[3], compact: isShortScreen)
            }
        }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch engine.state {
        case .idle, .armed:
            VStack(spacing: 8) {
                if gpsIsRed {
                    Text("GPS確認中")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.orange)
                        .opacity(gpsPulse ? 1.0 : 0.25)
                } else if engine.state == .armed && !engine.confirmedStoppedWhileArmed {
                    Text("停車してください")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundStyle(.orange)
                        .opacity(gpsPulse ? 1.0 : 0.4)
                } else {
                    // 停車確認＋GPS良好で READY。端末固定はトリガー/録画の必須条件ではない
                    // （手持ちでも計測可・参考値扱い）ため、固定の案内はサブ文言で促す。
                    Text("READY")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.green)
                        .opacity(readyPulse ? 1.0 : 0.55)
                        .scaleEffect(readyPulse ? 1.04 : 1.0)
                }
                Text(armedSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // 点滅は親VStackで一括駆動（メッセージ切替で再起動されず連続して点滅する）
            .onAppear {
                gpsPulse = false; readyPulse = false
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { gpsPulse = true }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { readyPulse = true }
            }
            .onDisappear { gpsPulse = false; readyPulse = false }

        case .running:
            VStack(spacing: 8) {
                Text("計測中")
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundStyle(runningPulse ? Color.yellow : Color.yellow.opacity(0.3))
                    .shadow(color: Color.yellow.opacity(runningPulse ? 0.9 : 0.2),
                            radius: runningPulse ? 20 : 6)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) {
                            runningPulse = true
                        }
                    }
                    .onDisappear { runningPulse = false }
                Text(" ")
                    .font(.caption)
            }

        case .finished:
            if autoReset {
                VStack(spacing: 8) {
                    Text("計測完了")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.yellow)
                    Text("停車で自動保存します")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 12) {
                    Text("計測完了")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundStyle(.yellow)
                    Text(engine.isResultSaved ? String(localized: "記録を保存しました") : String(localized: "停車で記録を保存します"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    BigButton(label: "再計測", color: .blue) {
                        engine.arm()
                    }
                }
            }
        }
    }

    private var locationDeniedOverlay: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "location.slash.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.red)
                Text("位置情報が必要です")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("速度計測にはGPS（位置情報）が必須です。設定アプリの「位置情報」を「使用中のみ許可」に変更してください。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                BigButton(label: "設定を開く", color: .blue) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }
        }
    }

    // MARK: Helpers

    private func setupVideoRecorder() {
        guard videoEnabled else { return }
        Task {
            let videoGranted = await VideoRecorder.requestAccess(for: .video)
            guard videoGranted else {
                videoErrorMessage = String(localized: "カメラへのアクセスが拒否されています。設定アプリから許可してください。")
                return
            }
            var audioGranted = false
            if videoAudioEnabled {
                audioGranted = await VideoRecorder.requestAccess(for: .audio)
                if !audioGranted {
                    videoErrorMessage = String(localized: "マイクへのアクセスが拒否されています。音声なしで録画します。")
                }
            }
            recorder.onSaved = { filename in
                // records は値キャプチャのため古くなる。常に pendingVideoFileName 経由で解決する
                pendingVideoFileName = filename
                videoSavedToast = true
                Task { try? await Task.sleep(for: .seconds(3)); videoSavedToast = false }
            }
            recorder.onError = { msg in videoErrorMessage = msg }
            recorder.onReady = {
                // カメラ構築完了 → ARMED待機中ならプリロール録画を開始
                videoSessionReady = true
                startPrerollIfNeeded()
            }
            recorder.prepareSession(withAudio: audioGranted)
        }
    }

    private func stopVideoRecordingIfNeeded() {
        recordingStopTask?.cancel()
        recordingStopTask = nil
        guard isVideoRecording else { return }
        if recorder.recordedPeakKmh >= 40 {
            // 発進点(runLaunchTime)の0.5秒前へトリミングして保存。マッチ用アンカーも発進点に。
            recordingStartDate = runLaunchTime
            recorder.stopAndSaveTrimmed(launchWall: runLaunchTime, leadIn: 0.5)
        } else {
            recorder.cancelAndDiscard()
        }
        isVideoRecording = false
    }

    /// 状態遷移に伴う動画録画ライフサイクル（プリロール/ロック/トリミング保存/破棄）。
    private func handleStateChange(_ oldState: MeasurementState, _ state: MeasurementState) {
        if state == .idle { engine.arm() }
        guard videoEnabled else { return }
        switch state {
        case .running:
            // プリロール録画は ARMED から継続中。発進点を記録し、巻き取りを止めて現セグメント保持。
            recordingStopTask?.cancel()
            recordingStopTask = nil
            runLaunchTime = engine.runStartTime
            recorder.lockForRun()
            recorder.recordedPeakKmh = 0
        case .finished:
            // 100km/h 到達後も録画継続。停車しない場合に備えて10秒で保存する保険タイマー。
            // ただし保存上限（無料）でレコードが残らない時は動画も破棄（孤立防止）。
            // この時点ではまだレコード未保存のため records.count で上限判定して問題ない。
            recordingStopTask = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                if store.canSaveAnother(currentCount: records.count) {
                    stopVideoRecordingIfNeeded()
                } else {
                    discardCurrentVideo()
                }
            }
        case .armed:
            recordingStopTask?.cancel()
            recordingStopTask = nil
            if oldState == .running {
                // RUNNING→ARMED は計測中断（減速/偽発進等）。レコードが残らないので破棄。
                recorder.cancelAndDiscard()
                isVideoRecording = false
            } else if oldState == .finished {
                // FINISH→停車→再準備：計測成功なので発進点へトリミングして保存
                stopVideoRecordingIfNeeded()
            }
            // 新しい待機のプリロール録画を開始（次の発進を頭から収録するため）
            startPrerollIfNeeded()
            // オーバーレイを 0 にリセット（前回計測の値が新しい待機の録画に残らないように）
            recorder.updateOverlay(speed: 0, time: 0, splits: [nil, nil, nil, nil])
        case .idle:
            // キャンセル/ペイウォール等で待機解除 → プリロール録画を停止（電池節約）
            recordingStopTask?.cancel()
            recordingStopTask = nil
            recorder.cancelAndDiscard()
            isVideoRecording = false
        }
    }

    /// アプリのバックグラウンド/ロック/復帰を処理（onDisappearでは検知できないため scenePhase で）。
    /// 計測タブ表示中(isVisible)のみ作用させる。
    private func handleScenePhase(_ phase: ScenePhase) {
        guard isVisible else { return }
        switch phase {
        case .background, .inactive:
            UIApplication.shared.isIdleTimerDisabled = false
            if engine.state == .running {
                // 計測中にロック/背面化 → CoreMotionが止まり精度不足になるため中止（復帰時トースト）
                recorder.cancelAndDiscard()
                isVideoRecording = false
                engine.abortRunDueToBackground()
            } else {
                recorder.cancelAndDiscard()
                isVideoRecording = false
                engine.pauseSensors()
                engine.pauseLocationIfFinished()
            }
            recorder.teardown()
            videoSessionReady = false
        case .active:
            UIApplication.shared.isIdleTimerDisabled = true
            if engine.state == .idle {
                if onboardingDone { engine.arm() }
            } else {
                engine.resumeSensors()
                engine.restartLocationIfFinished()
            }
            setupVideoRecorder()
            if engine.backgroundAbortedRun {
                engine.clearBackgroundAbortFlag()
                backgroundAbortToast = true
                Task { try? await Task.sleep(for: .seconds(3)); backgroundAbortToast = false }
            }
        @unknown default:
            break
        }
    }

    /// READY/待機中のプリロール録画を開始（発進を頭から収録するため）。
    /// セッション未構築・録画中・計測中/完了中は開始しない（ARMEDの待機時のみ）。
    private func startPrerollIfNeeded() {
        // 停車確認＋GPS良好（READYと同条件）で録画開始。GPS確認中(赤)はそもそも発進判定が
        // 起きず、カメラを回すのはムダなので開始しない。待機中ずっと回さない＝省電力。
        guard videoEnabled, videoSessionReady, !isVideoRecording, !gpsIsRed,
              engine.state == .armed, engine.confirmedStoppedWhileArmed else { return }
        let audioOK = videoAudioEnabled &&
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        recorder.startRecording(audio: audioOK, rotationAngle: currentVideoRotationAngle)
        recorder.recordedPeakKmh = 0
        isVideoRecording = true
    }

    /// 録画中のみ、30Hzでオーバーレイ（速度/タイム/スプリット）とピーク速度を更新する。
    /// SwiftUIの100Hz onChangeを使わないことで、非録画時の無駄な再描画を無くす（省電力）。
    private func startOverlayTimer() {
        overlayTimer?.invalidate()
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [recorder, engine] _ in
            Task { @MainActor in
                recorder.recordedPeakKmh = max(recorder.recordedPeakKmh, engine.peakSpeedKmh)
                recorder.updateOverlay(speed: engine.fusedSpeedKmh,
                                       time: engine.elapsedTime,
                                       splits: engine.splits)
            }
        }
    }

    private func stopOverlayTimer() {
        overlayTimer?.invalidate()
        overlayTimer = nil
    }

    private func applyPendingVideoFileName() {
        guard let filename = pendingVideoFileName,
              let startDate = recordingStartDate else { return }
        // レコードの date（計測完了時刻）は録画開始時刻より必ず後になるため、
        // 録画開始以降に作られた動画未設定レコードの中で最も早いものがこの計測のレコード
        let target = records
            .filter { $0.videoFileName.isEmpty && $0.date >= startDate }
            .min { $0.date < $1.date }
        guard let record = target else { return }
        record.videoFileName = filename
        pendingVideoFileName = nil
        recordingStartDate = nil
    }

    private var currentVideoRotationAngle: CGFloat {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
        switch orientation {
        case .portrait:            return 90
        case .portraitUpsideDown:  return 270
        case .landscapeRight:      return 0
        case .landscapeLeft:       return 180
        default:                   return verticalSizeClass == .compact ? 0 : 90
        }
    }

    private var gpsIsRed: Bool {
        let spd = engine.gpsSpeedAccuracy
        return spd < 0 || spd >= 2.0
    }

    // ARMED 状態のサブテキスト（停車待ち → 端末固定待ち → READY の順に案内）
    private var armedSubtitle: String {
        if engine.state == .armed && !engine.confirmedStoppedWhileArmed {
            return String(localized: "完全停止でREADY状態になります")
        }
        if engine.state == .armed && !engine.deviceSteadyWhileArmed {
            return String(localized: "端末を車体に固定すると高精度で計測できます")
        }
        return String(localized: "発進を検知して自動スタート（5〜10 km/h）")
    }

    // 速度精度（Doppler speedAccuracy, m/s）でインジケーターを判定
    // 水平精度（hAcc）はよくても速度精度が悪い場合があるため（例: hAcc=2m, speedAcc=10km/h）
    private var gpsColor: Color {
        let spd = engine.gpsSpeedAccuracy   // m/s
        if spd < 0    { return .red }
        if spd < 0.3  { return .blue }      // < 1.1 km/h: 最良
        if spd < 1.0  { return .green }     // < 3.6 km/h: 良好
        if spd < 2.0  { return .yellow }    // < 7.2 km/h: 普通
        return .red                          // ≥ 7.2 km/h: 不良
    }

    private var gpsAccuracyLabel: String {
        let spd = engine.gpsSpeedAccuracy   // m/s
        guard spd >= 0 else { return String(localized: "GPS なし") }
        let v = String(format: "%.1f", spd * 3.6)
        if spd < 0.3  { return String(localized: "速度±\(v)km/h BEST") }
        if spd < 1.0  { return String(localized: "速度±\(v)km/h GOOD") }
        if spd < 2.0  { return String(localized: "速度±\(v)km/h FAIR") }
        return String(localized: "速度±\(v)km/h POOR")
    }

    private var stateLabel: String {
        switch engine.state {
        case .idle:     return String(localized: "待機")
        case .armed:    return String(localized: "スタート待機中")
        case .running:  return String(localized: "計測中")
        case .finished: return String(localized: "完了")
        }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s  = Int(t)
        let ms = Int((t - Double(s)) * 1000)
        if s < 60 { return String(format: "%d.%03d", s, ms) }
        return String(format: "%d:%02d.%03d", s / 60, s % 60, ms)
    }
}

// MARK: - Split Cell

struct SplitCell: View {
    let label: String
    let time: Double?
    var best: Double? = nil
    var compact: Bool = false

    @State private var celebrate = false   // 新記録時の発光パルス

    private var isNewBest: Bool {
        guard let t = time else { return false }
        guard let b = best else { return true }  // 初めての記録はすべてベスト
        return t < b
    }

    // 新記録の派手なグラデ（ゴールド→オレンジ→ピンク）
    private static let recordGradient = LinearGradient(
        colors: [Color(red: 1, green: 0.92, blue: 0.3), .orange, Color(red: 1, green: 0.35, blue: 0.7)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private var timeStyle: AnyShapeStyle {
        if isNewBest { return AnyShapeStyle(Self.recordGradient) }
        return AnyShapeStyle(time != nil ? Color.green : Color.gray)
    }

    var body: some View {
        VStack(spacing: compact ? 4 : 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: compact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(.secondary)
                if isNewBest {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: compact ? 9 : 11, weight: .black))
                        Text("NEW")
                            .font(.system(size: compact ? 11 : 13, weight: .black))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Self.recordGradient, in: Capsule())
                    .shadow(color: .orange.opacity(celebrate ? 0.9 : 0.4), radius: celebrate ? 10 : 4)
                    .scaleEffect(celebrate ? 1.12 : 1.0)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(time.map { formatSplit($0) } ?? "--")
                    .font(.system(size: compact ? 54 : 60, weight: .bold, design: .monospaced))
                    .foregroundStyle(timeStyle)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .shadow(color: isNewBest ? Color.orange.opacity(celebrate ? 0.9 : 0.35) : .clear,
                            radius: isNewBest ? (celebrate ? 18 : 8) : 0)
                if time != nil {
                    Text("秒")
                        .font(.system(size: compact ? 18 : 22))
                        .foregroundStyle(.secondary)
                }
            }
            Divider().opacity(0.3)
            HStack(spacing: 4) {
                Text("BEST:")
                    .font(.system(size: compact ? 13 : 16, weight: .bold))
                    .foregroundStyle(Color.yellow)
                Text(best.map { formatSplit($0) } ?? "--")
                    .font(.system(size: compact ? 26 : 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(best != nil ? Color.yellow : .gray)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 12 : 18)
        .background(
            isNewBest
            ? AnyShapeStyle(LinearGradient(colors: [Color.orange.opacity(0.22), Color(red: 1, green: 0.35, blue: 0.7).opacity(0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(Color.white.opacity(0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isNewBest ? AnyShapeStyle(Self.recordGradient) : AnyShapeStyle(Color.clear),
                        lineWidth: isNewBest ? 2.5 : 0)
                .shadow(color: isNewBest ? Color.orange.opacity(celebrate ? 0.85 : 0.3) : .clear,
                        radius: celebrate ? 14 : 6)
        )
        .scaleEffect(isNewBest && celebrate ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.3), value: isNewBest)
        .onChange(of: isNewBest) { _, nb in
            if nb { startCelebrate() } else { celebrate = false }
        }
        .onAppear { if isNewBest { startCelebrate() } }
    }

    private func startCelebrate() {
        celebrate = false
        withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
            celebrate = true
        }
    }

    private func formatSplit(_ t: Double) -> String {
        String(format: "%.3f", t)
    }
}

// MARK: - Speed Lines (集中線)

/// 中心へ収束する集中線。外周付近から内側へ流れる（速度感の演出）。中央は空けて視認性を確保。
struct SpeedLinesView: View {
    var body: some View {
        // 描画負荷軽減のため毎フレームではなく30fpsに制限（速度表示のコマ落ちを防ぐ）
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let maxR = hypot(size.width, size.height) / 2 + 24
                let count = 36
                for i in 0..<count {
                    // 線ごとに固定の擬似乱数（角度ジッタ・速度・位相）
                    let r1 = (sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let r2 = (sin(Double(i) * 78.233) * 12543.123).truncatingRemainder(dividingBy: 1)
                    let rnd1 = abs(r1), rnd2 = abs(r2)
                    let angle = (Double(i) / Double(count)) * 2 * .pi + (rnd1 - 0.5) * 0.07
                    // 位相：外→内へ流れて 0→1 でループ（線ごとにずらす）
                    let speed = 0.7 + 1.1 * rnd2
                    let phase = (t * speed + rnd1).truncatingRemainder(dividingBy: 1)
                    // 内端は中央を空けて 0.55〜0.92*maxR の範囲を流れる
                    let innerR = maxR * (0.55 + 0.37 * (1 - phase))
                    let fade = sin(phase * .pi)               // 0→1→0 でフェードイン/アウト
                    let p1 = CGPoint(x: center.x + cos(angle) * innerR,
                                     y: center.y + sin(angle) * innerR)
                    let p2 = CGPoint(x: center.x + cos(angle) * maxR,
                                     y: center.y + sin(angle) * maxR)
                    var path = Path()
                    path.move(to: p1)
                    path.addLine(to: p2)
                    ctx.stroke(path,
                               with: .color(.white.opacity(0.10 + 0.40 * fade)),
                               lineWidth: 1.0 + 2.0 * rnd2)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        // plusLighter（加算合成）はGPU負荷が高いので通常合成に（白線なので見た目はほぼ同等）
    }
}

// MARK: - Big Button

struct BigButton: View {
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // label は呼び出し側で日本語リテラルを渡すため LocalizedStringKey 化してカタログ翻訳を効かせる
            Text(LocalizedStringKey(label))
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(color)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: MeasurementRecord.self, inMemory: true)
}
