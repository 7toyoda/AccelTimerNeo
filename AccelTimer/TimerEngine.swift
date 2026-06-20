import Foundation
import SwiftData
import AVFoundation
import CoreLocation
import UIKit

enum MeasurementState: Equatable {
    case idle
    case armed
    case running
    case finished
}

@Observable
@MainActor
final class TimerEngine {
    // MARK: - Published state (observed by UI)
    var state: MeasurementState = .idle
    // 内部・動画オーバーレイ用の速度（100Hzで更新）。録画の滑らかさはこちらを使う。
    var fusedSpeedKmh: Double = 0
    // 画面表示用の速度（~10Hzに間引く）。100Hzの再描画は人間に読めず不要なため、SwiftUIのTextはこちらを読む。
    var displaySpeedKmh: Double = 0
    private var lastDisplayTick: Double = 0   // displaySpeedKmh を最後に更新した motion timestamp
    private static let displayUpdateInterval = 0.1   // 画面表示の更新間隔（秒）＝約10Hz
    // 内部・動画オーバーレイ用の経過時間（100Hz）。録画の滑らかさはこちらを使う。
    var elapsedTime: TimeInterval = 0
    // 画面表示用の経過時間（~15Hzに間引く）。SwiftUIのタイムTextはこちらを読む（速度と同様の間引き）。
    var displayElapsedTime: TimeInterval = 0
    private var lastTimeDisplayTick: Double = 0
    private static let timeDisplayInterval = 0.066   // 画面のタイム更新間隔（秒）＝約15Hz
    var splits: [Double?] = [nil, nil, nil, nil]   // [40, 60, 80, 100] km/h
    /// mph 表示用に並行追跡するスプリット [15, 30, 45, 60] mph。完了判定には影響しない。
    var mphSplits: [Double?] = [nil, nil, nil, nil]
    var gpsHorizontalAccuracy: Double { location.horizontalAccuracy }
    var gpsSpeedAccuracy: Double { location.speedAccuracy }
    /// 位置情報の許可が拒否/制限されているか（計測に必須のため画面でガイド表示する）
    var locationDenied: Bool { location.authStatus == .denied || location.authStatus == .restricted }
    var autoResetRequested: Bool = false
    private(set) var isResultSaved: Bool = false
    /// 直近に永続化したレコード（新記録の祝福カード表示に使う）。
    private(set) var lastSavedRecord: MeasurementRecord?
    var bestTimes: [Double?] = [nil, nil, nil, nil]
    /// mph マイルストーンのベスト（NEW RECORD 読み上げ判定用・ContentView から設定）。
    var mphBestTimes: [Double?] = [nil, nil, nil, nil]
    /// 読み上げ・触覚に使う現在の表示単位（UserDefaults から都度読む）。
    private var speedUnit: SpeedUnit {
        SpeedUnit(rawValue: UserDefaults.standard.string(forKey: "speedUnit") ?? "") ?? .kmh
    }
    /// バックグラウンド移行による計測中止フラグ（復帰時にトーストで通知）
    private(set) var backgroundAbortedRun: Bool = false

    // MARK: - Internal
    private let location = LocationManager()
    private let motion   = MotionManager()

    private var startTime: Date?
    /// 計測の開始時刻（lookBackで求めた真の発進点）。動画を発進点でトリミングするために公開。
    var runStartTime: Date? { startTime }
    private var displayTimer: Timer?

    // GPS fusion state
    private var lastGPSSpeedMs: Double = 0
    private var lastGPSTime: Date      = .distantPast

    // 位置ベース速度の検算用アンカー（GPS Doppler の偽高速＝停車中なのに高速度 を検知する）。
    // 約1秒ごとに座標を採り、移動距離から実速度を概算。Doppler が高いのに位置が動いていなければ誤り。
    private var posAnchorCoord: CLLocationCoordinate2D?
    private var posAnchorTime: Date = .distantPast
    private var positionSpeedKmh: Double = 0

    // センサーフュージョン（カルマンフィルタ）
    private var kalman = SpeedKalmanFilter()
    private var lastMotionTimestamp: Double = 0
    // GPS速度増減から決定する符号（加速=+1, 減速=-1）
    private var accelSign: Double = 1.0
    // GPS符号判定の安定化：直近3サンプルの平均差分で判定（1サンプルノイズによる符号反転を防止）
    private var recentGPSDeltas: [Double] = []
    // 表示用GPS-EMA速度（加速度計100Hz更新による表示ブレを排除し、GPS Dopplerを直接表示）
    private var gpsDisplayKmh: Double = 0
    // 完了後(FINISHED)の表示：GPS間を「前回表示値→今回GPS値」へ一定速度で線形補間（区間補間）。
    // GPS値の間を直線で結ぶため、フリーズ・1Hz段差・ピークのオーバーシュートが出ない。
    private var finishSegStart: Double = 0       // 区間開始時の表示値
    private var finishSegTarget: Double = 0      // 区間の目標（今回のGPS値）
    private var finishSegDur: Double = 1.0        // 区間の長さ（GPS間隔, 秒）
    private var finishSegProgress: Double = 1.0   // 0→1 の進捗
    private var finishPrevTargetTime: Date = .distantPast
    // 【表示専用】発進直後（ARMED）の加速度補間推定値(km/h)とその作動フラグ。GPSが追いつくまでの0.0表示対策。
    private var armedLaunchKmh: Double = 0
    private var armedLaunchActive = false
    // 100Hz表示補間用：GPS EMAを起点に加速度で外挿し、GPS更新ごとに再アンカー
    private var motionDisplayKmh: Double = 0
    // motion.timestamp（起動後経過秒）→ Date への変換オフセット（GPS 10Hz で更新してキャッシュ）
    private var motionToWallOffset: Double = 0
    // ARMED中に一度GPS < 1km/hを確認するまで計測トリガーを禁止
    private(set) var confirmedStoppedWhileArmed = false
    // ARMED中、端末自体が静止しているか（直近50msの水平加速度が静止しきい値未満）。
    // 車の停車(confirmedStoppedWhileArmed)とは別に、端末の手揺れを検知してREADY表示を保留する。
    // 発進トリガー自体はゲートしない（実走行を取りこぼさない）。揺れたまま発進すれば unstableStart で記録。
    private(set) var deviceSteadyWhileArmed = false

    // MARK: - Look-back スタート検出（リングバッファ + ローパスフィルタ）
    private struct MotionSample {
        let timestamp: Double       // CMDeviceMotion.timestamp（単調増加）
        let filteredAccel: Double   // LPF後の水平加速度マグニチュード (m/s²)
    }
    private var ringBuffer: [MotionSample] = []
    private var lpfWindow:  [Double] = []

    // 4 秒 × 100 Hz。GPS トリガーが遅延（発進後に初回 GPS が来る）しても発進直後の
    // 加速度がバッファに残るよう 2 秒→4 秒に拡大。加速度グラフの開始欠けを防ぐ。
    private static let ringBufferCapacity = 400
    private static let lpfWindowSize      = 5     // 50 ms 移動平均
    private static let launchThresholdMs2 = 0.30  // 発進判定しきい値・lookBack静止検出 (m/s²)
    private static let prelaunchQuietLen  = 5     // 発進前の静止確認サンプル数（≈50 ms）
    // 「端末を固定してください」表示の判定しきい値 (m/s²)。アイドリング(0.15〜0.40)・持ち直し等を
    // 大きく上回り、本当に振り翳す動作だけを検知する。lookBack(0.30)とは別に大きく設定。
    private static let deviceShakeThresholdMs2 = 4.0
    // 手揺れ判定の評価窓（サンプル数。100Hz なので 30 ≈ 300ms）。この窓の「平均」で判定するため
    // 一瞬のスパイク（端末を置く・持ち直す）では反応せず、持続的な揺れの時だけ未固定とする。
    private static let shakeWindowLen = 30
    // 手揺れ判定を有効にする「車が停止中」の上限速度(km/h)。これ以上で動いていれば
    // 高加速度は車の発進・徐行＝正当とみなし、未固定表示しない（発進時の誤表示を防ぐ）。
    private static let shakeCheckMaxSpeedKmh = 1.5
    // 【表示専用】発進直後の0.0表示対策。GPS(1Hz)が発進を捉えるまでの間、加速度で表示を補間する。
    // 明確な発進加速のみ対象（アイドル振動と区別）：直近 launchDisplayWindow(≈150ms)の平均が
    // launchDisplayAccelMs2 以上の時だけ作動。計測のトリガー/スプリット/Kalman/ピークには一切不使用。
    private static let launchDisplayAccelMs2 = 2.0   // 0.2G。発進は容易に超え、アイドル振動(<0.3)は超えない
    private static let launchDisplayWindow   = 15    // ≈150ms（100Hz）
    private static let launchDisplayCapKmh   = 30.0  // 暴走防止の上限（トリガーは10km/h前後で発火しRUNNINGへ移行）
    // RUNNING 中にピーク速度からこの値(km/h)以上減速したら加速中断とみなし計測を破棄する。
    // 信号待ち・渋滞・巡航を挟んで 100 km/h に達する「水増し」計測を防止する。
    private static let decelAbortDropKmh   = 15.0
    // 減速判定を有効化するピーク速度の下限(km/h)。発進直後の低速域での誤動作を防ぐ。
    private static let decelAbortMinPeakKmh = 20.0
    // 減速リセット機能の有効/無効。一旦廃止（false）。再有効化はここを true にするだけ。
    private static let decelAbortEnabled = false
    // 偽発進フェイルセーフ（微速クリープ対策）：発進検知から launchConfirmSec 秒たっても
    // ピーク速度が launchConfirmKmh に届かなければ、本物のフル加速ではなく信号待ちの微速前進
    // （クリープ）や誤トリガーとみなし、計測を破棄して ARMED へ戻す。
    // 本物の 0-100 発進は数秒で 25km/h を余裕で超える（ゆっくりな車でも 5 秒あれば届く）ため、
    // 実走の加速は中断しない。現在速度は条件にしない＝低速のまま進み続けるクリープも確実に弾く。
    private static let launchConfirmSec = 5.0
    private static let launchConfirmKmh = 25.0

    // 計測中の最良 GPS 精度（値が小さいほど良い）
    private var bestGPSAccuracy: Double = -1
    private var bestGPSSpeedAccuracy: Double = -1  // 最良Doppler速度精度(m/s)
    // 高速域(80 km/h 超)の Doppler 速度精度サンプル。100 km/h 到達付近の実効精度の平均を記録に残す。
    private var highSpeedAccSamples: [Double] = []
    // 発進点検出(lookBack)が静止区間を見つけられず GPS/外挿フォールバックに降格したか。
    // true = 発進直前に端末が静止していなかった（手持ち・揺れの疑い）。スタート点精度が低下するため記録に残す。
    private var startDetectionFellBack = false
    // 発進前バッファに「実際の手持ちブレ」があったか。lookBack降格(fellBack)でも、加速度が
    // 一定で滑らか（＝固定された端末での全開加速）なら false にして「手持ち」警告を出さない。
    private var startWasShaky = false
    // ブレ判定のしきい値：発進前バッファの加速度の隣接サンプル差（ジッタ）の平均(m/s²)。
    // 滑らかな加速ランプ(~0.1)は下回り、手で揺らすと上回る。
    private static let startShakeJitterMs2 = 0.5
    // 計測中の最高速度
    private(set) var peakSpeedKmh: Double = 0
    // 計測開始・終了地点
    private var startCoordinate: CLLocationCoordinate2D?
    private var endCoordinate: CLLocationCoordinate2D?

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: - Haptics
    private let hapticHeavy  = UIImpactFeedbackGenerator(style: .heavy)
    private let hapticMedium = UIImpactFeedbackGenerator(style: .medium)
    private let hapticNotify = UINotificationFeedbackGenerator()

    // MARK: - Speed timeline（グラフ用：GPS 10Hz でサンプリング）
    private var speedSamples: [(time: Double, speed: Double)] = []

    // MARK: - Acceleration timeline（高精度グラフ用：CoreMotion 100Hz、縦加速度 m/s²）
    private var accelSamples: [(time: Double, accel: Double)] = []

    // MARK: - Route points（地図用：running 中の GPS 座標列）
    private var routePoints: [(lat: Double, lon: Double)] = []

    // MARK: - センサーログ（CSV 解析用）
    private let logger = MeasurementLogger()

    // 計測中のみKalmanを使用（IDLE/ARMEDはGPS直接表示のため不要だが他ステートの安全弁として残す）
    private var displayKmh: Double {
        kalman.speedMs * 3.6
    }

    static let splitThresholdsMs: [Double] = [
        40 / 3.6, 60 / 3.6, 80 / 3.6, 100 / 3.6
    ]
    /// mph マイルストーン [15, 30, 45, 60] mph を m/s に変換（すべて 100 km/h 手前）。
    /// 完了判定には使わず、表示用に並行記録するだけ。
    static let mphSplitThresholdsMs: [Double] = [15, 30, 45, 60].map { Double($0) * 1.609344 / 3.6 }

    /// 速度しきい値クロス時刻を線形補間で算出する純粋関数（テスト対象）。
    /// `prev.speed < threshold <= curr.speed` を満たす連続2サンプル間で、
    /// しきい値に到達した時刻を線形補間し、ミリ秒精度のクロス時刻を返す。
    /// センサー由来の状態に依存しないため `nonisolated`。
    nonisolated static func interpolatedCrossTime(
        threshold: Double,
        prev: (speed: Double, time: Date),
        curr: (speed: Double, time: Date)
    ) -> Date {
        let frac = (threshold - prev.speed) / (curr.speed - prev.speed)
        return prev.time.addingTimeInterval(frac * curr.time.timeIntervalSince(prev.time))
    }

    /// GPS Doppler が高速を示す一方で、同じサンプルで更新した位置ベース速度が大きく下回る場合は
    /// 停車中の速度グリッチとみなす。位置速度がまだ未確定なら判定しない。
    nonisolated static func isFakeDopplerSpeed(speedKmh: Double, positionSpeedKmh: Double?) -> Bool {
        guard let positionSpeedKmh else { return false }
        return speedKmh > 30.0 && positionSpeedKmh < speedKmh * 0.4
    }

    init() {
        location.onSpeedUpdate = { [weak self] speedMs, timestamp, speedAccuracy, horizontalAccuracy, coordinate in
            self?.handleGPS(speedMs: speedMs,
                            timestamp: timestamp,
                            speedAccuracyMs: speedAccuracy,
                            horizontalAccuracyM: horizontalAccuracy,
                            coordinate: coordinate)
        }
        motion.onMotionUpdate = { [weak self] accelMs2, motionTs in
            self?.handleMotion(accelMs2: accelMs2, timestamp: motionTs)
        }
    }

    // MARK: - Public interface

    func arm() {
        guard state == .idle || state == .finished || state == .running else { return }
        // resetState前に現在速度を確認。停車済みなら即トリガー可、走行中なら停車待ち
        // GPS精度を考慮したしきい値（精度未取得時は 6 km/h）
        // GPS未取得（起動直後など speedAccuracy<=0）のときは fusedSpeedKmh=0 が
        // 「停車」と誤判定するため、GPS有効時のみ停車確認済みとみなす
        let speedAcc = gpsSpeedAccuracy
        // GPS速度が精度範囲内（かつ最大5 km/h以内）なら停車確認済み
        // 旧: speedAcc*1.5 は精度 0.5 m/s で 2.7 km/h → 走行中に停車と誤判定する
        let stoppedThresholdMs = speedAcc > 0 ? min(speedAcc, 1.4) : 0.0
        // fusedSpeedKmh は表示用（.idle では Kalman 未更新で常に 0）なので
        // 実際の GPS Doppler 速度で停車判定する
        // speedAcc < 2.0: GPS赤状態（精度不良）では停車確認を成立させない。
        // handleGPS の停車確認ロジック（sAcc<2.0 ガード）と一貫性を取る。
        // 赤状態で停車確認済みにすると、GPSが緑へ回復した瞬間に実際は走行中でも
        // 発進判定される穴が arm() 経路に残るため。
        let alreadyStopped = speedAcc > 0 && speedAcc < 2.0 && location.speedMs < stoppedThresholdMs
        resetState()
        confirmedStoppedWhileArmed = alreadyStopped
        state = .armed
        logger.start()
        logger.logEvent("ARMED", startTime: nil)
        DebugLogger.shared.logEvent("ARM v\(AppInfo.version)", state: stateName)
        location.requestPermission()
        location.startUpdating()
        motion.startUpdates()
    }

    func cancel() {
        stopAll()
        state = .idle
        resetState()
    }

    func saveAndArm(context: ModelContext) {
        let complete = (state == .finished)
        persistResult(context: context, isComplete: complete)
        arm()
    }

    func discard() {
        stopAll()
        state = .idle
        resetState()
    }

    /// ARMED 状態のときだけセンサーを一時停止（タブ切り替え時のバッテリー節約）
    func pauseSensors() {
        guard state == .armed else { return }
        location.stopUpdating()
        motion.stopUpdates()
    }

    /// pauseSensors で停止したセンサーを再開し、古いサンプルをクリアして即座に受信待機
    func resumeSensors() {
        guard state == .armed else { return }
        // 一時停止中に溜まった可能性のある古いタイミングデータをリセット
        lastGPSSpeedMs = 0
        lastGPSTime    = .distantPast
        lastMotionTimestamp = 0
        accelSign      = 1.0       // 再開時は「前進」を仮定。3サンプルで実態に追従
        recentGPSDeltas = []       // lastGPSSpeedMs=0 にリセットされるため古い差分を捨てる
        motionToWallOffset = 0     // 次のGPS更新で即座に再取得される
        ringBuffer.removeAll(keepingCapacity: true)
        lpfWindow.removeAll()
        confirmedStoppedWhileArmed = false
        deviceSteadyWhileArmed = false
        location.startUpdating()
        motion.startUpdates()
    }

    /// .finished 状態でバックグラウンド移行時に GPS を停止してバッテリーを節約する
    func pauseLocationIfFinished() {
        guard state == .finished else { return }
        location.stopUpdating()
        motion.stopUpdates()  // 完了後の表示補間用モーションもバックグラウンドでは停止
    }

    /// .finished 状態でフォアグラウンド復帰時に GPS を再開する（停車検知のため）
    func restartLocationIfFinished() {
        guard state == .finished else { return }
        location.startUpdating()
        motion.startUpdates()  // 完了後の表示補間を再開
    }

    /// バックグラウンド移行時に呼ぶ。CoreMotion が停止して精度不足になるため計測を中止する
    func abortRunDueToBackground() {
        guard state == .running else { return }
        stopAll()
        resetState()
        backgroundAbortedRun = true  // resetState の後に設定（resetState が false に戻すため）
        state = .armed
        // arm() を経由せず直接 .armed になるためロガーを明示的に再起動する
        logger.start()
        logger.logEvent("ARMED(background_abort)", startTime: nil)
        DebugLogger.shared.logEvent("BG_ABORT", state: stateName)
    }

    func clearBackgroundAbortFlag() {
        backgroundAbortedRun = false
    }

    /// RUNNING 中に大きく減速した場合に計測を破棄して ARMED へ戻す（加速中断とみなす）。
    /// センサー(location/motion)は走行中のため停止せず継続し、リングバッファ蓄積を再開する。
    private func abortRunDueToDeceleration() {
        resetState()  // displayTimer 停止・全状態リセット（センサーは止めない。ログも破棄される）
        state = .armed
        // arm() を経由せず .armed になるためロガーを明示的に再起動する
        logger.start()
        logger.logEvent("ARMED(decel_abort)", startTime: nil)
        DebugLogger.shared.logEvent("DECEL_ABORT", state: stateName)
    }

    /// 偽発進フェイルセーフ：発進検知後ほとんど加速しないまま時間が経過した（誤トリガー・微速クリープ）
    /// 場合に計測を破棄して ARMED へ戻す。0km/h のまま「計測中」が続くのを防ぐ。
    private func abortRunDueToFalseLaunch() {
        resetState()
        state = .armed
        logger.start()
        logger.logEvent("ARMED(false_launch_abort)", startTime: nil)
        DebugLogger.shared.logEvent("FALSE_LAUNCH_ABORT", state: stateName)
    }

    func saveResult(context: ModelContext) {
        guard !isResultSaved else { return }
        let complete = (state == .finished)
        persistResult(context: context, isComplete: complete)
        isResultSaved = true
    }

    // MARK: - GPS handler

    private func handleGPS(speedMs: Double, timestamp: Date,
                           speedAccuracyMs: Double,
                           horizontalAccuracyM: Double,
                           coordinate: CLLocationCoordinate2D) {
        // motion.timestamp → Date 変換オフセットをGPS更新ごとに更新（100Hzでの毎回計算を回避）
        motionToWallOffset = Date().timeIntervalSinceReferenceDate - ProcessInfo.processInfo.systemUptime
        let hAcc = horizontalAccuracyM
        var rememberGPSSample = true

        defer {
            if rememberGPSSample {
                let delta = speedMs - lastGPSSpeedMs
                recentGPSDeltas.append(delta)
                if recentGPSDeltas.count > 2 { recentGPSDeltas.removeFirst() }
                let avgDelta = recentGPSDeltas.reduce(0, +) / Double(recentGPSDeltas.count)
                // 加速方向: 単一の正スパイク(>0.3 m/s)で即時 +1 に戻す
                //   → 一時的な負スパイクで -1 に反転した後、次の正サンプルで素早く回復
                // 減速方向: 直近2サンプル平均が -0.3 m/s 未満の場合のみ -1 に変更
                //   → 単発ノイズスパイクで符号が反転し速度表示が一時的に下がるのを防止
                if delta > 0.3 {
                    accelSign = 1.0
                } else if recentGPSDeltas.count >= 2 && avgDelta < -0.3 {
                    accelSign = -1.0
                }
                lastGPSSpeedMs = speedMs
                lastGPSTime    = timestamp
            }
        }

        let speedKmh = speedMs * 3.6

        // 位置ベース速度の検算（約1秒間隔で更新。GPS位置ジッタを平均化するため短すぎる間隔では測らない）
        let coordNow = coordinate
        var currentPositionSpeedKmh: Double?
        var nextPosAnchorCoord: CLLocationCoordinate2D?
        var nextPosAnchorTime: Date?
        if let anchor = posAnchorCoord {
            let dt = timestamp.timeIntervalSince(posAnchorTime)
            if dt >= 1.0 {
                let dist = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                    .distance(from: CLLocation(latitude: coordNow.latitude, longitude: coordNow.longitude))
                currentPositionSpeedKmh = (dist / dt) * 3.6
                nextPosAnchorCoord = coordNow
                nextPosAnchorTime = timestamp
            }
        } else {
            posAnchorCoord = coordNow
            posAnchorTime  = timestamp
        }
        // Doppler が高速(>30km/h)を示すのに位置がほとんど動いていない＝GPS Doppler の誤り（停車中の偽高速）。
        // 巡航中は位置も同等に動くので誤抑制しない。RUNNING中は計測値にも混ぜず、偽FINISHを防ぐ。
        let dopplerLooksFake = Self.isFakeDopplerSpeed(speedKmh: speedKmh,
                                                       positionSpeedKmh: currentPositionSpeedKmh)
        if dopplerLooksFake {
            rememberGPSSample = false
        } else if let nextPosAnchorCoord, let nextPosAnchorTime, let currentPositionSpeedKmh {
            positionSpeedKmh = currentPositionSpeedKmh
            posAnchorCoord = nextPosAnchorCoord
            posAnchorTime = nextPosAnchorTime
        }

        // カルマンフィルタは armed/running 中のみ更新。
        // 偽Dopplerは速度推定へ混ぜると後続のMotion splitにも波及するため除外する。
        // finished 後は p→0 となりフィルタが固まるため GPS 直読みに切り替える。
        if state == .running {
            if !dopplerLooksFake {
                kalman.update(gpsSpeedMs: speedMs, speedAccuracyMs: speedAccuracyMs)
            }
        } else if state == .armed {
            if hAcc >= 0, hAcc < 30, !dopplerLooksFake {
                // 精度良好: GPS速度で Kalman を更新
                // 停車ノイズ範囲内（speedMs ≤ 精度）ならゼロ方向へ誘導して表示ジッタを抑制
                if speedMs > max(0.56, speedAccuracyMs) {
                    kalman.update(gpsSpeedMs: speedMs, speedAccuracyMs: speedAccuracyMs)
                } else {
                    // GPS が停車を示している → Kalman を完全リセットしてドリフトを防止
                    // 弱い補正（soft update）では GPS 精度が悪い時（>1 m/s）に加速度計ノイズに
                    // 負けて Kalman が偽速度（7〜9 km/h）を蓄積するため、ハードリセットで対処
                    kalman.reset()
                }
            } else {
                // 精度不良または偽Doppler: 更新前にリセット（不良GPS値が Kalman に混入するのを防ぐ）
                kalman.reset()
            }
        }

        var gpsLogEvent = ""   // switch 内で設定したイベント名を switch 後にまとめてログ

        switch state {
        case .armed:
            guard hAcc >= 0, hAcc < 30 else {
                // 精度不良期間に車が動いた可能性があるため停車確認をリセット
                // Kalman のリセットは TOP セクションで実施済み
                confirmedStoppedWhileArmed = false
                fusedSpeedKmh = 0
                break
            }
            // ARMED 状態の表示は GPS 速度を直接使う（Kalman は表示に使わない）
            // Kalman は加速度計ノイズでドリフトして偽速度（7〜9 km/h）を示すことがあるため
            // 速度精度が赤(sAcc>=2.0)の時は生GPSがグリッチ(突然112km/h等)を起こすので表示しない。
            // 赤の間はUIが「GPS確認中」表示なので速度0でよい（hAccが良くてもsAccは悪いことがある）。
            // さらに、緑精度でも「位置が動いていないのに高速度」なら Doppler 誤りとして0にする。
            let armedSpeedAccGood = speedAccuracyMs >= 0 && speedAccuracyMs < 2.0
            fusedSpeedKmh = (armedSpeedAccGood && speedKmh > 2.0 && !dopplerLooksFake) ? speedKmh : 0.0

            // 【表示専用】発進表示推定(armedLaunchKmh)をGPS真値へリアンカー。GPSが発進を捉えるまでは
            // 推定を維持して表示が0へ瞬間的に落ちるのを防ぎ、捉えたら真値に合わせる（暴走/ドリフト防止）。
            if armedLaunchActive {
                if armedSpeedAccGood && speedKmh > 1.5 && !dopplerLooksFake {
                    armedLaunchKmh = speedKmh
                }
                fusedSpeedKmh = max(fusedSpeedKmh, armedLaunchKmh)
            }

            // GPS速度精度が良好（sAcc < 2.0）かつ速度が精度範囲内 → 停車確認
            // sAcc >= 2.0（赤状態）での停車確認は信頼性が低いため受け付けない
            // min(..., 1.4): 精度不良時（sAcc=3.7 m/s など）の誤停車判定を防ぐ上限キャップ
            if speedAccuracyMs < 2.0 && speedMs < min(speedAccuracyMs, 1.4) {
                confirmedStoppedWhileArmed = true
                // 停車が確定＝偽発進推定（段差等）を解除して0へ戻す
                armedLaunchActive = false
                armedLaunchKmh = 0
            }
            // GPS精度が赤（sAcc >= 2.0）のまま車が動いた場合は停車確認をリセット
            // → ユーザーは再停車してGPS精度が改善するのを待つ必要がある
            if speedAccuracyMs >= 2.0 && speedMs > 1.4 {
                confirmedStoppedWhileArmed = false
            }

            // 停車確認後、GPS精度ノイズを確実に上回る速度（最大10 km/h）で計測開始
            let launchThresholdMs = min(10.0 / 3.6, max(5.0 / 3.6, speedAccuracyMs * 2.0))
            // speedAccuracyMs < 2.0: UI の「GPS確認中（赤）」表示中は発進トリガーを禁止
            // hAcc<30 でも sAcc>=2.0 の場合（GPS起動直後）に計測が開始されるのを防ぐ
            if confirmedStoppedWhileArmed && speedMs > launchThresholdMs && speedAccuracyMs < 2.0 && !dopplerLooksFake {
                let gpsFallback = interpolatedStartTime(
                    threshold: launchThresholdMs,
                    prevSpeed: lastGPSSpeedMs, prevTime: lastGPSTime,
                    currSpeed: speedMs,       currTime: timestamp
                )
                gpsLogEvent = "GPS_TRIGGER"
                startMeasurement(at: lookBackStartTime(fallback: gpsFallback, currSpeedMs: speedMs))
                // ARMED→RUNNING 遷移直後、次の GPS 到着まで最大1秒 motionDisplayKmh=0 のため
                // 表示補間が働かない問題を防ぐ：トリガー時の GPS 速度を起点として設定
                gpsDisplayKmh = speedKmh
                motionDisplayKmh = speedKmh
                fusedSpeedKmh = speedKmh
                armedLaunchActive = false   // RUNNINGへ移行＝表示推定の役目終了
                if lastGPSTime != .distantPast {
                    checkSplits(prev: (lastGPSSpeedMs, lastGPSTime),
                                curr: (speedMs, timestamp), source: "GPS")
                }
            }

        case .running:
            guard !dopplerLooksFake else {
                gpsLogEvent = "GPS_FAKE_DOPPLER"
                break
            }
            // 表示用：GPS DopplerをEMA平滑化（α=0.7）で表示
            // Kalmanはsplit検出専用として内部で継続動作
            // 初回サンプルはEMAではなく直接代入（初期値0によるアンダーシュートを防止）
            gpsDisplayKmh = gpsDisplayKmh == 0 ? speedKmh : (0.7 * speedKmh + 0.3 * gpsDisplayKmh)
            // GPS更新ごとにモーション補間の起点をGPS EMAへ再アンカー（誤差リセット）
            motionDisplayKmh = gpsDisplayKmh
            fusedSpeedKmh = gpsDisplayKmh
            peakSpeedKmh  = max(peakSpeedKmh, speedKmh)
            let acc = hAcc
            if acc >= 0 { bestGPSAccuracy = bestGPSAccuracy < 0 ? acc : min(bestGPSAccuracy, acc) }
            let sAcc = speedAccuracyMs
            if sAcc >= 0 { bestGPSSpeedAccuracy = bestGPSSpeedAccuracy < 0 ? sAcc : min(bestGPSSpeedAccuracy, sAcc) }
            // 到達付近の信頼性判定用：高速域(80 km/h 超)の速度精度を蓄積（後で平均を記録）
            if sAcc >= 0 && speedKmh > 80.0 { highSpeedAccSamples.append(sAcc) }
            checkSplits(prev: (lastGPSSpeedMs, lastGPSTime),
                        curr: (speedMs, timestamp), source: "GPS")
            // グラフ用速度サンプル収集（GPS 10 Hz）
            // checkSplits が FINISH を検出した場合は state が .finished に変わるため
            // EMA ラグを含む fusedSpeedKmh を末尾サンプルとして使わない（finishMeasurement で正確な終点を追加）
            if let start = startTime, state == .running {
                speedSamples.append((time: timestamp.timeIntervalSince(start),
                                     speed: fusedSpeedKmh))
            }
            // 地図用ルート座標収集（GPS 10 Hz）
            let coord = coordinate
            routePoints.append((lat: coord.latitude, lon: coord.longitude))
            // 停車検知：生GPS速度で判定（EMAラグなし）
            if speedKmh < 5.0 && !autoResetRequested && peakSpeedKmh >= 5.0 {
                autoResetRequested = true
            }
            // 偽発進フェイルセーフ（微速クリープ対策）：start から launchConfirmSec 秒以内に
            // ピークが launchConfirmKmh に届かない＝信号待ちの微速前進等で誤トリガーした計測。
            // クリープは止まらず低速のまま進むこともあるため、現在速度は条件にしない。
            if state == .running, let start = startTime,
               timestamp.timeIntervalSince(start) > Self.launchConfirmSec,
               peakSpeedKmh < Self.launchConfirmKmh {
                abortRunDueToFalseLaunch()
                return
            }
            // 加速中断検知：ピーク速度から大きく減速したらフル加速を中断したとみなし、
            // 計測を破棄して ARMED へ戻す（信号待ち・渋滞・巡航を挟んだ水増し計測を防止）。
            // EMA 速度(gpsDisplayKmh)で判定して単発 GPS 下方スパイクによる誤リセットを避ける。
            // checkSplits が FINISH 済み(state=.finished)の場合は対象外。
            if Self.decelAbortEnabled && state == .running && peakSpeedKmh >= Self.decelAbortMinPeakKmh
                && peakSpeedKmh - gpsDisplayKmh >= Self.decelAbortDropKmh {
                abortRunDueToDeceleration()
                return
            }

        case .finished:
            // カルマンを使わず GPS 速度を直接表示（5 km/h 以下はノイズとして0表示）。
            // FINISHED は完走後の減速中＝実際に動いているので、赤精度でも0にせず速度を表示する
            // （ここで0にすると「移動中なのに0km/h」になる）。ただし位置が動いていない偽高速は0にする。
            // 完了後：現在の表示値から今回のGPS値へ、次のGPSまでの間で線形補間する区間を設定。
            let newTarget = (speedKmh < 5.0 || dopplerLooksFake) ? 0.0 : speedKmh
            let dtg = finishPrevTargetTime == .distantPast ? 1.0 : timestamp.timeIntervalSince(finishPrevTargetTime)
            finishSegStart = motionDisplayKmh
            finishSegTarget = newTarget
            finishSegDur = max(0.4, min(1.6, dtg))   // 実GPS間隔。グリッチ対策でクランプ
            finishSegProgress = 0
            finishPrevTargetTime = timestamp
            // ピーク更新は赤精度(sAcc>=2.0)のグリッチを除外し、maxSpeedKmh の水増しを防ぐ
            let finSpeedAccGood = speedAccuracyMs >= 0 && speedAccuracyMs < 2.0
            if finSpeedAccGood && speedKmh > 5.0 { peakSpeedKmh = max(peakSpeedKmh, speedKmh) }
            // GPS グリッチ対策：現在と直前の2サンプル連続で低速を確認してからautoReset
            if speedKmh < 5.0 && lastGPSSpeedMs * 3.6 < 5.0 && !autoResetRequested {
                autoResetRequested = true
                // 停車確定後は完了表示の100Hz補間が不要になるためモーションを停止して省電力。
                // 自動再計測ONなら arm() が再開、OFFでも停車中(0km/h)は補間不要。
                motion.stopUpdates()
            }

        default:
            fusedSpeedKmh = displayKmh
        }

        // GPS サンプルをログ（armed/running/finished 全状態）
        logger.logGPS(wallTime: timestamp, startTime: startTime,
                      speedMps: speedMs, accMps: speedAccuracyMs, hAccM: hAcc,
                      accelSign: accelSign, kalmanMps: kalman.speedMs,
                      displayKmh: fusedSpeedKmh, event: gpsLogEvent)
        // 常時ログ（計測の保存有無に関わらず追記。未トリガー時の調査用）
        DebugLogger.shared.logGPS(state: stateName, gpsMps: speedMs, accMps: speedAccuracyMs,
                                  hAccM: hAcc, speedKmh: speedKmh, peakKmh: peakSpeedKmh,
                                  confirmedStopped: confirmedStoppedWhileArmed,
                                  deviceSteady: deviceSteadyWhileArmed, event: gpsLogEvent)
        // 待機中/IDLE/完了直後のGPS値(≤1Hz)は画面表示にも即反映（間引き対象外）
        displaySpeedKmh = fusedSpeedKmh
    }

    private var stateName: String {
        switch state {
        case .idle:     return "IDLE"
        case .armed:    return "ARMED"
        case .running:  return "RUNNING"
        case .finished: return "FINISHED"
        }
    }

    // MARK: - Motion handler

    private func handleMotion(accelMs2: Double, timestamp: Double) {
        guard state == .armed || state == .running || state == .finished else { return }

        // ARMED 中はリングバッファへ蓄積（GPS到着前から収集開始）
        if state == .armed {
            lpfWindow.append(accelMs2)
            if lpfWindow.count > Self.lpfWindowSize { lpfWindow.removeFirst() }
            let filtered = lpfWindow.reduce(0, +) / Double(lpfWindow.count)
            ringBuffer.append(MotionSample(timestamp: timestamp, filteredAccel: filtered))
            if ringBuffer.count > Self.ringBufferCapacity { ringBuffer.removeFirst() }
            // 端末静止判定：
            //  ・車がほぼ停止(GPS < shakeCheckMaxSpeedKmh)している時にだけ評価する。
            //    車が動いていれば高加速度は発進・徐行＝正当なので未固定にしない（発進時の誤表示防止）。
            //  ・直近 shakeWindowLen(≈300ms) の「平均」がしきい値以上＝持続的に振り翳している時だけ未固定。
            //    平均判定なので、置く・持ち直す等の一瞬の揺れでは反応しない。アイドリングも当然許容。
            let carParked = lastGPSSpeedMs * 3.6 < Self.shakeCheckMaxSpeedKmh
            let recent = ringBuffer.suffix(Self.shakeWindowLen)
            let sustainedShake = recent.count >= Self.shakeWindowLen
                && recent.reduce(0.0) { $0 + $1.filteredAccel } / Double(recent.count) >= Self.deviceShakeThresholdMs2
            deviceSteadyWhileArmed = !(carParked && sustainedShake)
        }

        guard lastGPSTime != .distantPast else { return }

        let prevTimestamp = lastMotionTimestamp
        let dt: Double = prevTimestamp == 0 ? 0.01 : min(0.1, max(0, timestamp - prevTimestamp))
        lastMotionTimestamp = timestamp

        let prevFusedMs = kalman.speedMs
        kalman.predict(accelMs2: accelMs2 * accelSign, dt: dt)

        if state == .running {
            // GPS更新時にキャッシュ済みのオフセットを使用（handleGPS 冒頭で更新済み）
            let motionToWall = motionToWallOffset
            let currDate = Date(timeIntervalSinceReferenceDate: timestamp + motionToWall)
            let prevDate = prevTimestamp > 0
                ? Date(timeIntervalSinceReferenceDate: prevTimestamp + motionToWall)
                : currDate.addingTimeInterval(-dt)

            // 100Hz表示補間：GPS EMAを起点に加速度で外挿して滑らかな表示を実現
            // GPS信号が一時的に1Hzに低下しても表示が1秒固まるのを防ぐ
            // GPS更新ごとにmotionDisplayKmhがGPS EMAへリアンカーされるため誤差は最大0.1s分に留まる
            motionDisplayKmh = max(0, motionDisplayKmh + accelMs2 * accelSign * dt * 3.6)
            fusedSpeedKmh = motionDisplayKmh

            // 高精度加速度タイムライン（100Hz、縦加速度＝magnitude×符号）を収集
            if let start = startTime {
                accelSamples.append((currDate.timeIntervalSince(start), accelMs2 * accelSign))
            }

            // Kalman は split 検出タイミング専用（peakSpeedKmh は GPS 由来のみで更新）
            checkSplits(prev: (prevFusedMs, prevDate), curr: (kalman.speedMs, currDate))
            logger.logMotion(wallTime: currDate, startTime: startTime,
                             accelMps2: accelMs2, accelSign: accelSign, kalmanMps: kalman.speedMs)
        } else if state == .finished {
            // 完了後の100Hz表示：今回GPS値へ向けて区間内を一定速度で線形補間。
            // GPS値の間を直線で結ぶので、フリーズ・段差・ピークのオーバーシュートが出ない。
            finishSegProgress = min(1.0, finishSegProgress + dt / finishSegDur)
            motionDisplayKmh = max(0, finishSegStart + (finishSegTarget - finishSegStart) * finishSegProgress)
            fusedSpeedKmh = motionDisplayKmh
        } else {
            // .armed: 表示は基本 handleGPS（GPS直接）が管理。
            // ただし発進直後はGPS(1Hz)が追いつくまで最大~3秒0.0表示になるため、明確な発進加速を
            // 検知した時のみ加速度で「表示だけ」を100Hz補間する（計測のトリガー/スプリット/Kalman/
            // ピークには一切不使用＝計測精度に影響しない。次のGPSで真値へリアンカーし暴走/ドリフト防止）。
            let recent = ringBuffer.suffix(Self.launchDisplayWindow)
            let strongAccel = recent.count >= Self.launchDisplayWindow
                && recent.reduce(0.0) { $0 + $1.filteredAccel } / Double(recent.count) >= Self.launchDisplayAccelMs2
            if confirmedStoppedWhileArmed && strongAccel {
                if !armedLaunchActive {
                    armedLaunchActive = true
                    armedLaunchKmh = max(0, lastGPSSpeedMs * 3.6)
                }
                let filtered = recent.last?.filteredAccel ?? 0
                armedLaunchKmh = min(Self.launchDisplayCapKmh, armedLaunchKmh + filtered * dt * 3.6)
                fusedSpeedKmh = armedLaunchKmh
            } else {
                armedLaunchActive = false
            }
        }

        // 画面表示用の速度は ~10Hz に間引く（fusedSpeedKmh自体＝動画オーバーレイ用は100Hzのまま）
        if timestamp - lastDisplayTick >= Self.displayUpdateInterval {
            displaySpeedKmh = fusedSpeedKmh
            lastDisplayTick = timestamp
        }
    }

    // MARK: - Helpers

    // リングバッファを後方スキャンして「発進前の静止期間→加速への転換点」を探す
    // fallback: リングバッファで特定できない場合の GPS 補間時刻
    private func lookBackStartTime(fallback: Date, currSpeedMs: Double = 0) -> Date {
        // 既定は「フォールバック扱い」。静止区間を発見できた場合のみ false に落とす。
        startDetectionFellBack = true
        startWasShaky = false
        guard ringBuffer.count >= Self.prelaunchQuietLen else { return fallback }

        // GPS更新時にキャッシュ済みのオフセットを使用（handleGPS 冒頭で更新済み）
        let motionToWall = motionToWallOffset

        let n = ringBuffer.count
        var quietCount = 0

        // 最新サンプルから過去へ遡り、加速開始前の「静止区間」を探す
        for i in stride(from: n - 1, through: 0, by: -1) {
            if ringBuffer[i].filteredAccel < Self.launchThresholdMs2 {
                quietCount += 1
                if quietCount >= Self.prelaunchQuietLen {
                    // 静止区間を確認 → その直後（加速開始点）がスタート（高精度パス）
                    startDetectionFellBack = false
                    let onsetIdx = min(i + Self.prelaunchQuietLen, n - 1)
                    let onsetDate = Date(timeIntervalSinceReferenceDate:
                                        ringBuffer[onsetIdx].timestamp + motionToWall)
                    return onsetDate < fallback ? onsetDate : fallback
                }
            } else {
                quietCount = 0
            }
        }

        // 静止区間が無い＝lookBack降格。ここで「本当の手持ちブレ」か「端末固定の全開加速
        // （GPS遅延で静止区間がバッファから押し出された）」かを、加速度の滑らかさで判別する。
        // 隣接サンプル差（ジッタ）の平均が小さい＝滑らかな加速＝端末は安定 → shaky=false。
        if n >= 2 {
            var jitterSum = 0.0
            for i in 1..<n { jitterSum += abs(ringBuffer[i].filteredAccel - ringBuffer[i - 1].filteredAccel) }
            startWasShaky = (jitterSum / Double(n - 1)) >= Self.startShakeJitterMs2
        }

        // バッファ全体が加速中（発進後にGPS精度不良でトリガーが遅延した場合など）
        // → MOTION平均加速度とGPS速度から「速度0の時刻」をバックエクストラポレーション
        let avgAccelMs2 = ringBuffer.reduce(0.0) { $0 + $1.filteredAccel } / Double(n)
        let oldestDate = Date(timeIntervalSinceReferenceDate:
                              ringBuffer[0].timestamp + motionToWall)
        if avgAccelMs2 > 0.1 && currSpeedMs > 0 {
            // oldestDate での推定速度 = GPS速度(fallback時刻) - avgAccel * (fallback - oldestDate)
            let dtToFallback = fallback.timeIntervalSince(oldestDate)
            let speedAtOldest = max(0.0, currSpeedMs - avgAccelMs2 * dtToFallback)
            // 速度0の時刻 = oldestDate - speedAtOldest / avgAccel
            let zeroDate = oldestDate.addingTimeInterval(-speedAtOldest / avgAccelMs2)
            return zeroDate < fallback ? zeroDate : fallback
        }
        return oldestDate < fallback ? oldestDate : fallback
    }

    private func startMeasurement(at time: Date) {
        startTime = time
        startCoordinate = location.coordinate
        state = .running
        hapticHeavy.impactOccurred()
        // lookBack は速度≈0 の静止点を START とするため、ARMED 末尾の速度を引き継がないようリセット
        kalman.reset()
        // t=0 の初期サンプル（startTime はルックバックで求めた静止起点なので速度は 0）
        speedSamples.append((time: 0.0, speed: 0.0))
        // リングバッファの発進前モーションデータをダンプ（スタート検出の検証用）。
        // 同時に、発進点(time)以降のサンプルを加速度タイムラインの先頭に積む（発進の立ち上がりを収録）。
        for sample in ringBuffer {
            let wallTime = Date(timeIntervalSinceReferenceDate: sample.timestamp + motionToWallOffset)
            logger.logMotion(wallTime: wallTime, startTime: time,
                             accelMps2: sample.filteredAccel, accelSign: accelSign, kalmanMps: 0)
            let t = wallTime.timeIntervalSince(time)
            if t >= 0 { accelSamples.append((t, sample.filteredAccel)) }
        }
        logger.logEvent("START", wallTime: time, startTime: time)
        DebugLogger.shared.logEvent("START", state: stateName)
        // 「スタート」の読み上げは行わない。実際の計測開始(lookBack)は発進検知より前の
        // 真の発進点に遡るため、検知時点で「スタート」と言うのは実態とズレて紛らわしいため。
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.01,
                                             repeats: true) { [weak self] _ in
            // Swift 6: @MainActor 隔離プロパティへの安全なアクセス
            Task { @MainActor [weak self] in
                guard let self, let start = self.startTime,
                      self.state == .running else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
                // 画面表示用は ~15Hz に間引く（elapsedTime=100Hzは動画オーバーレイ用）
                if self.elapsedTime - self.lastTimeDisplayTick >= Self.timeDisplayInterval {
                    self.displayElapsedTime = self.elapsedTime
                    self.lastTimeDisplayTick = self.elapsedTime
                }
            }
        }
    }

    private func checkSplits(prev: (Double, Date), curr: (Double, Date), source: String = "KALMAN") {
        guard let start = startTime else { return }
        let (prevSpeed, prevTime) = prev
        let (currSpeed, currTime) = curr

        // mph マイルストーンを先に処理（100km/h 完了と同一サンプルでも取りこぼさない）
        checkMphSplits(prev: prev, curr: curr, source: source)

        for (i, threshold) in Self.splitThresholdsMs.enumerated() {
            guard splits[i] == nil,
                  prevSpeed < threshold,
                  currSpeed >= threshold else { continue }

            let crossTime = Self.interpolatedCrossTime(
                threshold: threshold,
                prev: (prevSpeed, prevTime),
                curr: (currSpeed, currTime)
            )
            // 補間結果がstartTimeより前になった場合（センサーのタイミングずれ）はスキップ
            guard crossTime >= start else { continue }

            // Kalman（MOTION）検出時の発散ガード。
            // horizontalMagnitudeMs2 は水平面全体の加速度マグニチュードを返すため、
            // コーナリング・路面段差の横加速度が accelSign の符号で Kalman に積分され、
            // GPS 補正前に閾値を偽到達するケースがある。直近 GPS 速度との乖離で弾く。
            if source != "GPS" {
                if i == 3 {
                    // SPLIT_100 の二段階ガード（偽 FINISH 防止のため最も厳格）
                    // ① peakSpeedKmh >= 85: GPS 精度不良で Kalman が発散した偽検出を防ぐ
                    // ② lastGPSSpeedMs >= 97 km/h: 直前の GPS が 97 km/h 未満ならブロック
                    //    GPS は ~1Hz 更新のため 1 秒間 GPS 補正なしで加速度積分すると
                    //    Kalman が実速度より 5〜10 km/h 高く推定し、90〜96 km/h で
                    //    偽 FINISH を検出するケースを防止（iPhone 16 実機で観測）
                    if peakSpeedKmh < 85.0 || lastGPSSpeedMs * 3.6 < 97.0 { continue }
                } else {
                    // SPLIT_40/60/80: Kalman が GPS 間を補間して僅かに先行するのは正常だが、
                    // 直近 GPS 速度が閾値より 8 km/h 以上下回る場合は横加速度等による
                    // 偽検出とみなしてブロック（GPS が ~1Hz に低下した正常加速は許容）
                    if lastGPSSpeedMs * 3.6 < threshold * 3.6 - 8.0 { continue }
                }
            }

            let splitTime = crossTime.timeIntervalSince(start)
            splits[i] = splitTime
            let splitLabels = ["40", "60", "80", "100"]
            logger.logEvent("SPLIT_\(splitLabels[i])(\(source))", wallTime: crossTime, startTime: start)
            // 読み上げ・触覚は km/h 表示時のみ（mph 表示時は checkMphSplits 側で行う）
            if speedUnit == .kmh {
                if i < 3 { hapticMedium.impactOccurred() }
                let words = ["40", "60", "80", String(localized: "100、計測完了")]
                let isNewBest = i == 3 && (bestTimes[3].map { splitTime < $0 } ?? true)
                let text = isNewBest ? String(localized: "\(words[i])、NEW RECORD") : words[i]
                speak(text)
            }

            if i == 3 { finishMeasurement(); return }
        }
    }

    /// mph マイルストーン [15,30,45,60] mph を並行記録する。完了判定には影響しない。
    /// mph 表示時のみ読み上げ・触覚を行う（km/h 表示時は checkSplits 側）。
    private func checkMphSplits(prev: (Double, Date), curr: (Double, Date), source: String = "KALMAN") {
        guard let start = startTime else { return }
        let (prevSpeed, prevTime) = prev
        let (currSpeed, currTime) = curr
        let announce = (speedUnit == .mph)
        for (i, threshold) in Self.mphSplitThresholdsMs.enumerated() {
            guard mphSplits[i] == nil, prevSpeed < threshold, currSpeed >= threshold else { continue }
            // Kalman 偽検出ガード（km/h スプリットの 40/60/80 と同等）
            if source != "GPS", lastGPSSpeedMs < threshold - 8.0 / 3.6 { continue }
            let crossTime = Self.interpolatedCrossTime(
                threshold: threshold, prev: (prevSpeed, prevTime), curr: (currSpeed, currTime))
            guard crossTime >= start else { continue }
            let splitTime = crossTime.timeIntervalSince(start)
            mphSplits[i] = splitTime
            logger.logEvent("MPHSPLIT_\(["15","30","45","60"][i])(\(source))", wallTime: crossTime, startTime: start)
            guard announce else { continue }
            // 0-60mph がユーザーにとっての完了。60mph で完了読み上げ＋成功触覚。
            if i == 3 {
                hapticNotify.notificationOccurred(.success)
                let isNewBest = mphBestTimes[3].map { splitTime < $0 } ?? true
                speak(isNewBest ? String(localized: "60、NEW RECORD")
                                : String(localized: "60、計測完了"))
            } else {
                hapticMedium.impactOccurred()
                speak(["15", "30", "45"][i])
            }
        }
    }

    private func speak(_ text: String) {
        guard UserDefaults.standard.object(forKey: "speakEnabled") as? Bool ?? true else { return }
        let utterance = AVSpeechUtterance(string: text)
        // 端末の言語設定に追従（読み上げ文言も String(localized:) で同言語化済み）
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first ?? "ja-JP")
        utterance.rate = 0.55
        utterance.volume = 1.0
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    private func interpolatedStartTime(threshold: Double,
                                       prevSpeed: Double, prevTime: Date,
                                       currSpeed: Double, currTime: Date) -> Date {
        guard prevTime != .distantPast, prevSpeed < threshold, currSpeed > prevSpeed else {
            return currTime
        }
        let frac = (threshold - prevSpeed) / (currSpeed - prevSpeed)
        return prevTime.addingTimeInterval(frac * currTime.timeIntervalSince(prevTime))
    }

    private func finishMeasurement() {
        endCoordinate = location.coordinate
        displayTimer?.invalidate()
        displayTimer = nil
        state = .finished  // タイマークロージャのガードを先に通過させる
        if let total = splits[3] {
            elapsedTime = total
            displayElapsedTime = total   // 画面にも確定タイムを正確に表示
            // グラフの終点を補間済み finish 時刻・100 km/h に固定
            // EMA ラグにより直前の GPS サンプルが ~95-98 km/h で終わるのを防ぐ
            speedSamples.append((time: total, speed: 100.0))
        }
        logger.logEvent("FINISH", startTime: startTime)
        DebugLogger.shared.logEvent("FINISH", state: stateName)
        // mph 表示時は 60mph 到達時に成功触覚済み。ここでの 100km/h 完了触覚は km/h 時のみ。
        if speedUnit == .kmh { hapticNotify.notificationOccurred(.success) }
        // 完了後もモーション(100Hz)を継続し、100km/h通過を滑らかに補間する（オーバーレイにも効く）。
        // 表示目標は直近GPS値。加速中は加速度で外挿、減速はGPS目標へイーズ（handleMotion .finished）。
        // 完了時：走行表示(やや遅れ)から「完了時点の実GPS速度」へ向けて補間開始。
        // これで最初のGPSが来るまで固まらず、100km/h通過を滑らかに繋ぐ。
        finishSegStart = fusedSpeedKmh
        finishSegTarget = max(fusedSpeedKmh, location.speedMs * 3.6)
        finishSegDur = 1.0
        finishSegProgress = 0
        finishPrevTargetTime = .distantPast
        // location は走行中のまま継続し、停車検知に使う
    }

    private func stopAll() {
        displayTimer?.invalidate()
        displayTimer = nil
        location.stopUpdating()
        motion.stopUpdates()
    }

    private func resetState() {
        displayTimer?.invalidate()
        displayTimer = nil
        splits              = [nil, nil, nil, nil]
        mphSplits           = [nil, nil, nil, nil]
        elapsedTime         = 0
        displayElapsedTime  = 0
        lastTimeDisplayTick = 0
        fusedSpeedKmh       = 0
        startTime           = nil
        lastGPSSpeedMs      = 0
        lastGPSTime         = .distantPast
        posAnchorCoord      = nil
        posAnchorTime       = .distantPast
        positionSpeedKmh    = 0
        kalman.reset()
        lastMotionTimestamp = 0
        accelSign           = 1.0
        recentGPSDeltas     = []
        gpsDisplayKmh       = 0
        motionDisplayKmh    = 0
        finishSegStart      = 0
        finishSegTarget     = 0
        finishSegDur        = 1.0
        finishSegProgress   = 1.0
        finishPrevTargetTime = .distantPast
        armedLaunchKmh      = 0
        armedLaunchActive   = false
        motionToWallOffset  = 0
        ringBuffer.removeAll(keepingCapacity: true)
        lpfWindow.removeAll()
        confirmedStoppedWhileArmed = false
        deviceSteadyWhileArmed = false
        autoResetRequested  = false
        isResultSaved       = false
        backgroundAbortedRun = false
        bestGPSAccuracy      = -1
        bestGPSSpeedAccuracy = -1
        highSpeedAccSamples  = []
        startDetectionFellBack = false
        startWasShaky       = false
        peakSpeedKmh        = 0
        startCoordinate     = nil
        endCoordinate       = nil
        speedSamples        = []
        accelSamples        = []
        routePoints         = []
        logger.reset()
    }

    private func persistResult(context: ModelContext, isComplete: Bool = false) {
        // 完走なら splits[3]、途中なら elapsedTime を totalTime に使う
        let total = isComplete ? (splits[3] ?? elapsedTime) : elapsedTime
        guard total > 0, peakSpeedKmh >= 60 else { return }  // 60 km/h 未満は保存しない
        let now = Date()
        // 到達付近(80 km/h 超)の平均速度精度。サンプルが無い場合は -1（不明）
        let finishAcc = highSpeedAccSamples.isEmpty
            ? -1.0
            : highSpeedAccSamples.reduce(0, +) / Double(highSpeedAccSamples.count)
        let record = MeasurementRecord(
            date:            now,
            totalTime:       total,
            split40:         splits[0] ?? 0,
            split60:         splits[1] ?? 0,
            split80:         splits[2] ?? 0,
            mphSplit15:      mphSplits[0] ?? 0,
            mphSplit30:      mphSplits[1] ?? 0,
            mphSplit45:      mphSplits[2] ?? 0,
            mphSplit60:      mphSplits[3] ?? 0,
            maxSpeedKmh:     peakSpeedKmh,
            gpsAccuracy:     bestGPSAccuracy,
            gpsSpeedAccuracy: bestGPSSpeedAccuracy,
            finishSpeedAccuracy: finishAcc,
            unstableStart:   startWasShaky,
            isComplete:      isComplete,
            startLatitude:   startCoordinate?.latitude  ?? 0,
            startLongitude:  startCoordinate?.longitude ?? 0,
            endLatitude:     endCoordinate?.latitude  ?? location.coordinate.latitude,
            endLongitude:    endCoordinate?.longitude ?? location.coordinate.longitude
        )
        record.speedTimelineData = (try? JSONEncoder().encode(
            speedSamples.map { SpeedSample(time: $0.time, speed: $0.speed) }
        )) ?? Data()
        record.accelTimelineData = (try? JSONEncoder().encode(
            accelSamples.map { AccelSample(time: $0.time, accel: $0.accel) }
        )) ?? Data()
        record.routeCoordinatesData = (try? JSONEncoder().encode(
            routePoints.map { RouteCoordinate(latitude: $0.lat, longitude: $0.lon) }
        )) ?? Data()
        // センサーログを CSV に書き出してレコードに紐付ける
        logger.stop()
        record.logFileName = logger.writeCSV(recordDate: now) ?? ""
        context.insert(record)
        lastSavedRecord = record
        trimHistory(context: context)
    }

    private func trimHistory(context: ModelContext) {
        let desc = FetchDescriptor<MeasurementRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        guard let records = try? context.fetch(desc) else { return }

        var keepIDs = Set<PersistentIdentifier>()

        // 各ランキングはユーザーが手動で除外したレコードを対象外にする
        // （除外したものはそのランキングの保持枠を占有しない）
        let dateVisible = records.filter { !$0.hiddenFromDate }
        let timeVisible = records.filter { !$0.hiddenFromTime }

        // 日付順 上位30件
        dateVisible.prefix(30).forEach { keepIDs.insert($0.persistentModelID) }

        // 0→100 上位10件（完走のみ）
        timeVisible.filter(\.isComplete)
            .sorted { $0.totalTime < $1.totalTime }
            .prefix(10).forEach { keepIDs.insert($0.persistentModelID) }

        // 0→80 上位10件
        timeVisible.filter { $0.split80 > 0 }
            .sorted { $0.split80 < $1.split80 }
            .prefix(10).forEach { keepIDs.insert($0.persistentModelID) }

        // 0→60 上位10件
        timeVisible.filter { $0.split60 > 0 }
            .sorted { $0.split60 < $1.split60 }
            .prefix(10).forEach { keepIDs.insert($0.persistentModelID) }

        // 0→40 上位10件
        timeVisible.filter { $0.split40 > 0 }
            .sorted { $0.split40 < $1.split40 }
            .prefix(10).forEach { keepIDs.insert($0.persistentModelID) }

        // 保持対象外を削除
        records.filter { !keepIDs.contains($0.persistentModelID) }
            .forEach {
                $0.deleteVideoFile()
                $0.deleteLogFile()
                context.delete($0)
            }
    }
}
