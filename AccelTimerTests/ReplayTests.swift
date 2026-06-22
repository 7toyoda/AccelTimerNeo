import XCTest
@testable import AccelTimer

/// 実走ログ(debug.csv)から切り出した「録画サンプル列」をそのまま判定ロジックへ通すリプレイテスト。
///
/// 目的：実機で再走行せずに、過去の実データに対して計測判定の正しさを永続的に回帰検証する。
/// これにより「走る→ログ共有→修正→7日ごと再インストール→また走る」という人力ループを断つ。
///
/// 新しいログで問題を見つけたら、その区間を `ReplaySample` 配列として下の Fixtures に追加するだけで、
/// 以降は `xcodebuild test -only-testing:AccelTimerTests`（シミュレーター・数秒）で永久に回帰検証される。
/// 同じ現象で二度と走らなくてよい。
///
/// 抽出方法（debug.csv の ARMED 行）：
///   rawKmh = gps_mps × 3.6 ／ sAcc = gps_acc_mps ／ conf = conf_stopped ／
///   grace = event に "GPS_POOR_LAUNCH_GRACE" を含むか ／ loggedUI = event の "UI=..."（録画時の表示）
/// v0.1.76 以降は debug.csv の event 欄に `pos=`(位置ベース速度)/`posOK=`/`fake=` が出るので、
/// 停車確認(updateArmedLaunch)も近似なしでフル・リプレイできる（下の full pipeline テスト参照）。
final class ReplayTests: XCTestCase {

    struct ReplaySample {
        let rawKmh: Double   // 生GPS速度(km/h)
        let sAcc: Double     // Doppler速度精度(m/s)
        let conf: Bool       // 停車確認(エンジンの判断・録画時点)
        let grace: Bool      // 赤GPS発進の猶予中
        let loggedUI: String // 録画時(v0.1.70)に表示されていたUI（回帰対比用）
    }

    private func phase(_ s: ReplaySample) -> TimerEngine.ArmedPhase {
        TimerEngine.armedPhase(confirmedStopped: s.conf, rawGpsSpeedKmh: s.rawKmh,
                               gpsSpeedAccuracyMs: s.sAcc, inPoorGPSLaunchGrace: s.grace)
    }

    // MARK: - Fixtures（実走 2026-06-22 13時台 / AccelTimer-logs-20260622_134836 由来）

    /// 12:36 信号待ち：sAccが赤(2.4〜3.7)に張り付いたまま停車→発進。
    /// 録画時(v0.1.70)は停車中ずっと「GPS確認中」を表示していた（これがユーザー報告の不具合）。
    private let fixture1236: [ReplaySample] = [
        .init(rawKmh: 0.0,   sAcc: 2.4851, conf: false, grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 10.88, sAcc: 2.448,  conf: false, grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 9.2,   sAcc: 2.5045, conf: false, grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 7.96,  sAcc: 2.5334, conf: false, grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 7.15,  sAcc: 2.535,  conf: false, grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 6.4,   sAcc: 2.5337, conf: false, grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 3.32,  sAcc: 3.7014, conf: false, grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.15,  sAcc: 3.7532, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.18,  sAcc: 3.7181, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.722,  conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7254, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7247, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7267, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7183, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.761,  conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7455, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7152, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.739,  conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7299, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7323, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.0,   sAcc: 3.7144, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 0.51,  sAcc: 3.7155, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 4.94,  sAcc: 3.7317, conf: true,  grace: false, loggedUI: "GPS_CHECK"),
        .init(rawKmh: 14.16, sAcc: 2.4051, conf: true,  grace: true,  loggedUI: "GPS_CHECK"),
        .init(rawKmh: 28.24, sAcc: 2.0008, conf: true,  grace: true,  loggedUI: "GPS_CHECK"),
    ]

    /// 12:20 クリーンな停車(緑sAcc)→発進。最後の1件は発進直前の表示推定でDRIVINGが出ていた。
    private let fixture1220: [ReplaySample] = [
        .init(rawKmh: 29.76, sAcc: 0.3071, conf: false, grace: false, loggedUI: "DRIVING"),
        .init(rawKmh: 23.87, sAcc: 0.3072, conf: false, grace: false, loggedUI: "DRIVING"),
        .init(rawKmh: 13.84, sAcc: 0.3066, conf: false, grace: false, loggedUI: "DRIVING"),
        .init(rawKmh: 4.19,  sAcc: 0.2754, conf: false, grace: false, loggedUI: "DRIVING"),
        .init(rawKmh: 0.17,  sAcc: 0.3034, conf: true,  grace: false, loggedUI: "READY"),
        .init(rawKmh: 0.25,  sAcc: 0.3018, conf: true,  grace: false, loggedUI: "READY"),
        .init(rawKmh: 0.17,  sAcc: 0.3038, conf: true,  grace: false, loggedUI: "READY"),
        .init(rawKmh: 0.0,   sAcc: 0.3057, conf: true,  grace: false, loggedUI: "READY"),
        .init(rawKmh: 0.0,   sAcc: 0.3057, conf: true,  grace: false, loggedUI: "DRIVING"),
    ]

    private var allFixtures: [[ReplaySample]] { [fixture1236, fixture1220] }

    // MARK: - armedPhase 単体リプレイ（録画時の conf をそのまま使い、表示判定だけ検証）

    /// 【バグ核心・永続回帰】12:36 で停車確認済み(conf)かつ生GPS≈0(<3km/h)の区間は必ず READY。
    /// 録画時(v0.1.70)に「GPS確認中」だったものが READY に救済されることを実データで固定する。
    func testReplay1236_confirmedStopIsReady() {
        var recovered = 0
        for s in fixture1236 where s.conf && s.rawKmh < 3.0 {
            XCTAssertEqual(phase(s), .ready,
                           "停車確認済み・生GPS\(s.rawKmh)km/h・sAcc\(s.sAcc) なのに READY でない")
            if s.loggedUI == "GPS_CHECK" { recovered += 1 }
        }
        XCTAssertGreaterThan(recovered, 0, "GPS確認中→READYの救済が0件＝修正が効いていない")
    }

    /// 12:36 発進加速中（赤猶予・生GPS>3km/h）は READY にしない＝走行中。
    func testReplay1236_acceleratingIsDriving() {
        for s in fixture1236 where s.grace && s.rawKmh > 3.0 {
            XCTAssertEqual(phase(s), .driving)
        }
    }

    /// 12:20 緑の停車区間は READY（発進直前にDRIVINGが出ていた最後の1件も含めて修正される）。
    func testReplay1220_greenStopIsReady() {
        for s in fixture1220 where s.conf && s.rawKmh < 3.0 {
            XCTAssertEqual(phase(s), .ready)
        }
    }

    /// 【全fixture共通の不変条件】完全停車(生GPS<1)＋停車確認済みなら絶対に「GPS確認中」を出さない。
    func testInvariant_confirmedStopNeverShowsAcquiringGPS() {
        for fx in allFixtures {
            for s in fx where s.conf && s.rawKmh < 1.0 {
                XCTAssertNotEqual(phase(s), .acquiringGPS,
                                  "停車確認済み・生GPS\(s.rawKmh) で GPS確認中 を出している")
            }
        }
    }

    /// 表示が READY だった録画サンプルが、新ロジックでも READY を維持する（READYの取りこぼし回帰防止）。
    func testInvariant_loggedReadyStaysReady() {
        for fx in allFixtures {
            for s in fx where s.loggedUI == "READY" {
                XCTAssertEqual(phase(s), .ready)
            }
        }
    }

    // MARK: - 全ARMEDパイプライン・リプレイ（停車確認 updateArmedLaunch → 表示 armedPhase）

    /// 12:36 を end-to-end でリプレイ：録画された(生GPS速度, sAcc)列を `updateArmedLaunch` に流して
    /// 停車確認(latch)を「再導出」し、その latch から `armedPhase` を計算する。
    /// 検証する実世界の事実：sAccが赤(3.7)に張り付いたまま生GPS≈0が続く停車では、
    /// エンジンは Path B(位置ベース)で停車確認し、表示は READY になる（旧版は GPS確認中 のままだった）。
    ///
    /// 注意：positionSpeedKmh は当時のログに無いため rawKmh で近似する（停車/低速では座標速度≈実速度で妥当・
    /// 偽Doppler域 >30km/h には入らない）。v0.1.76 以降は debug.csv の `pos=` を使い近似なしでリプレイ可能。
    func testReplayFullPipeline1236_redStopConfirmsAndShowsReady() {
        var latch = TimerEngine.ArmedLaunch(confirmedStopped: false, readySince: nil, poorGPSGraceSince: nil)
        let base = Date(timeIntervalSinceReferenceDate: 0)
        var settledStopSamples = 0
        var readyDuringStop = 0
        var everConfirmed = false
        for (i, s) in fixture1236.enumerated() {
            _ = TimerEngine.updateArmedLaunch(
                &latch,
                speedMs: s.rawKmh / 3.6, speedKmh: s.rawKmh, speedAccuracyMs: s.sAcc,
                positionSpeedKmh: s.rawKmh,        // ← 近似（座標未ログのため）
                positionSpeedValid: i > 0,         // 初回は未確定扱い（早期確定の人工成立を防ぐ）
                dopplerLooksFake: false, gpsSampleFresh: true,
                timestamp: base.addingTimeInterval(Double(i)))
            everConfirmed = everConfirmed || latch.confirmedStopped
            let ph = TimerEngine.armedPhase(
                confirmedStopped: latch.confirmedStopped, rawGpsSpeedKmh: s.rawKmh,
                gpsSpeedAccuracyMs: s.sAcc, inPoorGPSLaunchGrace: latch.poorGPSGraceSince != nil)
            // 「落ち着いた停車」＝生GPS<1km/h・sAcc赤・直前サンプルも低速(<3)。先頭の瞬間的な0読み(過渡値)は除外。
            let prevSettled = i > 0 && fixture1236[i - 1].rawKmh < 3.0
            if s.rawKmh < 1.0 && s.sAcc >= 2.0 && prevSettled {
                settledStopSamples += 1
                XCTAssertTrue(latch.confirmedStopped, "落ち着いた停車(sample \(i))なのに停車確認できていない")
                if ph == .ready { readyDuringStop += 1 }
            }
        }
        XCTAssertTrue(everConfirmed, "赤sAcc停車を一度も停車確認できていない（Path Bが効いていない）")
        XCTAssertGreaterThan(settledStopSamples, 5, "落ち着いた停車サンプルが不足（fixtureを確認）")
        XCTAssertEqual(readyDuringStop, settledStopSamples,
                       "落ち着いた停車・赤sAcc 区間が全てREADYになっていない（全パイプラインで取りこぼし）")
    }
}
