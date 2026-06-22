import XCTest
@testable import AccelTimer

/// ARMED 発進検出の中核ロジックを純粋関数として検証する。
/// `shouldConfirmStopped` / `shouldAbortFalseLaunch` / `updateArmedLaunch` は
/// センサー状態に依存しないため、実機・シミュレーターのセンサー無しで決定的にテストできる。
/// v0.1.66 検証走行ログで判明した2バグ（赤sAcc停車の取りこぼし／クリープ破棄遅延）の回帰防止。
final class TimerEngineLaunchTests: XCTestCase {

    private let base = Date(timeIntervalSinceReferenceDate: 2_000)

    // MARK: - shouldConfirmStopped

    /// Path A: Doppler速度精度が良好(sAcc<2.0)・速度≈0 → 即停車確認。
    func testConfirmStopped_pathA_goodAccuracy() {
        XCTAssertTrue(TimerEngine.shouldConfirmStopped(
            speedMs: 0.0, speedAccuracyMs: 0.3,
            positionSpeedKmh: 0, positionSpeedValid: false))
    }

    /// Path B（Bug A の核心）: sAccが赤(3.74)でも、生GPS速度≈0かつ位置ベース速度≈0なら停車確認。
    /// iOSが停車直後にsAccを赤へ張り付かせても発進を取りこぼさないための救済。
    func testConfirmStopped_pathB_redAccuracyButNotMoving() {
        XCTAssertTrue(TimerEngine.shouldConfirmStopped(
            speedMs: 0.0, speedAccuracyMs: 3.74,
            positionSpeedKmh: 0.0, positionSpeedValid: true))
    }

    /// Path B は位置速度が未確定(valid=false)の間は使わない（初期値0の誤用防止）。
    func testConfirmStopped_pathB_blockedWhenPositionInvalid() {
        XCTAssertFalse(TimerEngine.shouldConfirmStopped(
            speedMs: 0.0, speedAccuracyMs: 3.74,
            positionSpeedKmh: 0.0, positionSpeedValid: false))
    }

    /// 赤sAccの偽高速グリッチ（生速度が高い）はPath Bを通らない＝誤って停車確認しない。
    func testConfirmStopped_pathB_blockedWhenRawSpeedHigh() {
        XCTAssertFalse(TimerEngine.shouldConfirmStopped(
            speedMs: 5.0, speedAccuracyMs: 3.74,
            positionSpeedKmh: 0.0, positionSpeedValid: true))
    }

    /// 赤sAccかつ位置も動いている（実走行）→ 停車確認しない。
    func testConfirmStopped_movingWithRedAccuracy() {
        XCTAssertFalse(TimerEngine.shouldConfirmStopped(
            speedMs: 8.0, speedAccuracyMs: 3.0,
            positionSpeedKmh: 28.0, positionSpeedValid: true))
    }

    // MARK: - shouldAbortFalseLaunch

    /// 発進検知から5秒超・ピーク<25km/h → 偽発進として破棄。
    func testFalseLaunch_abortsAfterWindow() {
        XCTAssertTrue(TimerEngine.shouldAbortFalseLaunch(
            launchDetectedAt: base,
            currentTime: base.addingTimeInterval(5.5),
            peakSpeedKmh: 16.0))
    }

    /// 5秒以内はまだ破棄しない（本物のフル加速の立ち上がりを待つ）。
    func testFalseLaunch_withinWindowKeepsRunning() {
        XCTAssertFalse(TimerEngine.shouldAbortFalseLaunch(
            launchDetectedAt: base,
            currentTime: base.addingTimeInterval(4.0),
            peakSpeedKmh: 16.0))
    }

    /// ピークが25km/h以上に達していれば本物の発進として破棄しない。
    func testFalseLaunch_realAccelNotAborted() {
        XCTAssertFalse(TimerEngine.shouldAbortFalseLaunch(
            launchDetectedAt: base,
            currentTime: base.addingTimeInterval(6.0),
            peakSpeedKmh: 30.0))
    }

    // MARK: - updateArmedLaunch（遷移の集約・end-to-end）

    /// Bug A 再現シナリオ end-to-end：sAcc赤で完全停止 → 位置ベースで停車確認 →
    /// readyHold経過 → 発進(緑へ回復・高速)でトリガー。修正前はトリガーを取りこぼしていた。
    func testUpdateArmedLaunch_redStopThenLaunchTriggers() {
        var s = TimerEngine.ArmedLaunch(confirmedStopped: false, readySince: nil, poorGPSGraceSince: nil)

        // t=0: sAcc赤(3.74)・速度0・位置不動 → 停車確認成立
        let r0 = TimerEngine.updateArmedLaunch(
            &s, speedMs: 0.0, speedKmh: 0.0, speedAccuracyMs: 3.74,
            positionSpeedKmh: 0.0, positionSpeedValid: true,
            dopplerLooksFake: false, timestamp: base)
        XCTAssertTrue(s.confirmedStopped)
        XCTAssertTrue(r0.didConfirmStop)
        XCTAssertFalse(r0.shouldTrigger)   // readyHold未経過

        // t=0.6s: まだ赤で動き始め(8km/h) → 停車確認済みからの赤発進は猶予で保持
        let r1 = TimerEngine.updateArmedLaunch(
            &s, speedMs: 8.0 / 3.6, speedKmh: 8.0, speedAccuracyMs: 3.74,
            positionSpeedKmh: 0.0, positionSpeedValid: true,
            dopplerLooksFake: false, timestamp: base.addingTimeInterval(0.6))
        XCTAssertTrue(s.confirmedStopped)  // grace で保持
        XCTAssertFalse(r1.shouldTrigger)   // 赤(sAcc>=2.0)なのでトリガー不可

        // t=1.6s: GPSが緑へ回復(sAcc1.8)・42km/h → 発進トリガー
        let r2 = TimerEngine.updateArmedLaunch(
            &s, speedMs: 42.0 / 3.6, speedKmh: 42.0, speedAccuracyMs: 1.8,
            positionSpeedKmh: 30.0, positionSpeedValid: true,
            dopplerLooksFake: false, timestamp: base.addingTimeInterval(1.6))
        XCTAssertTrue(r2.shouldTrigger)
    }

    /// ロールング発進防止：一度も停車確認せず走行(>15km/h, 緑)し続けてもトリガーしない。
    func testUpdateArmedLaunch_rollingNeverTriggers() {
        var s = TimerEngine.ArmedLaunch(confirmedStopped: false, readySince: nil, poorGPSGraceSince: nil)
        for i in 0..<10 {
            let r = TimerEngine.updateArmedLaunch(
                &s, speedMs: 40.0 / 3.6, speedKmh: 40.0, speedAccuracyMs: 0.5,
                positionSpeedKmh: 40.0, positionSpeedValid: true,
                dopplerLooksFake: false, timestamp: base.addingTimeInterval(Double(i)))
            XCTAssertFalse(r.shouldTrigger)
        }
        XCTAssertFalse(s.confirmedStopped)
    }

    /// 緑sAccでの通常発進：停車確認 → readyHold経過 → 13km/h超でトリガー。
    func testUpdateArmedLaunch_greenNormalLaunch() {
        var s = TimerEngine.ArmedLaunch(confirmedStopped: false, readySince: nil, poorGPSGraceSince: nil)
        _ = TimerEngine.updateArmedLaunch(
            &s, speedMs: 0.0, speedKmh: 0.0, speedAccuracyMs: 0.3,
            positionSpeedKmh: 0.0, positionSpeedValid: true,
            dopplerLooksFake: false, timestamp: base)
        XCTAssertTrue(s.confirmedStopped)
        // readyHold(0.5s)経過後に18km/hで発進
        let r = TimerEngine.updateArmedLaunch(
            &s, speedMs: 18.0 / 3.6, speedKmh: 18.0, speedAccuracyMs: 0.5,
            positionSpeedKmh: 16.0, positionSpeedValid: true,
            dopplerLooksFake: false, timestamp: base.addingTimeInterval(0.8))
        XCTAssertTrue(r.shouldTrigger)
    }

    /// 停車確認済みの赤GPS発進は猶予(5s)を超えるとラッチ解除（長い赤移動後のロールング発進を防ぐ）。
    func testUpdateArmedLaunch_poorGPSGraceExpires() {
        var s = TimerEngine.ArmedLaunch(confirmedStopped: true,
                                        readySince: base, poorGPSGraceSince: nil)
        // 赤のまま動き続ける。猶予開始からの経過が5s超でラッチ解除。
        let r1 = TimerEngine.updateArmedLaunch(
            &s, speedMs: 6.0, speedKmh: 21.6, speedAccuracyMs: 3.0,
            positionSpeedKmh: 22.0, positionSpeedValid: true,
            dopplerLooksFake: false, timestamp: base)
        XCTAssertTrue(s.confirmedStopped)             // 初回は猶予保持
        XCTAssertEqual(r1.log, .poorGPSGrace)
        let r2 = TimerEngine.updateArmedLaunch(
            &s, speedMs: 6.0, speedKmh: 21.6, speedAccuracyMs: 3.0,
            positionSpeedKmh: 22.0, positionSpeedValid: true,
            dopplerLooksFake: false, timestamp: base.addingTimeInterval(6.0))
        XCTAssertFalse(s.confirmedStopped)            // 猶予超過で解除
        XCTAssertEqual(r2.log, .poorGPSExpired)
    }

    // MARK: - armedPhase（ARMED表示の単一の真実）

    /// バグ核心（2026-06-22 12:36ログ）: 停車確認済み＋sAcc赤(2.7)でも、生GPS速度≈0なら READY。
    /// 旧実装は赤ゲートを優先して「GPS確認中」を出しREADYを隠していた。
    func testArmedPhase_confirmedStopWithRedGPS_isReady() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: true, rawGpsSpeedKmh: 0.2,
                                   gpsSpeedAccuracyMs: 2.7, inPoorGPSLaunchGrace: false),
            .ready)
    }

    /// 停車確認済みでもクリープ中（生GPS 9km/h）なら READY にしない＝走行中。
    func testArmedPhase_confirmedButCreeping_isDriving() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: true, rawGpsSpeedKmh: 9.0,
                                   gpsSpeedAccuracyMs: 0.7, inPoorGPSLaunchGrace: false),
            .driving)
    }

    /// 停車確認済みのまま赤GPSで動き始めた猶予中（生GPS 20km/h）＝発進推定中＝走行中（READYにしない）。
    func testArmedPhase_poorGPSGraceMoving_isDriving() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: true, rawGpsSpeedKmh: 20.0,
                                   gpsSpeedAccuracyMs: 2.7, inPoorGPSLaunchGrace: true),
            .driving)
    }

    /// 完全停車・GPS緑 → READY。
    func testArmedPhase_parkedGreen_isReady() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: true, rawGpsSpeedKmh: 0.0,
                                   gpsSpeedAccuracyMs: 0.3, inPoorGPSLaunchGrace: false),
            .ready)
    }

    /// GPS未取得(sAcc<0) → GPS確認中。
    func testArmedPhase_noGPS_isAcquiring() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: false, rawGpsSpeedKmh: 0.0,
                                   gpsSpeedAccuracyMs: -1, inPoorGPSLaunchGrace: false),
            .acquiringGPS)
    }

    /// 赤sAcc・未停車 → GPS確認中（速度を信用できない）。
    func testArmedPhase_redNotConfirmed_isAcquiring() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: false, rawGpsSpeedKmh: 10.0,
                                   gpsSpeedAccuracyMs: 3.0, inPoorGPSLaunchGrace: false),
            .acquiringGPS)
    }

    /// 緑・未停車・走行 → 走行中。
    func testArmedPhase_greenDriving_isDriving() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: false, rawGpsSpeedKmh: 30.0,
                                   gpsSpeedAccuracyMs: 0.3, inPoorGPSLaunchGrace: false),
            .driving)
    }

    /// 緑・未停車・低速で減速中 → 停止確認中。
    func testArmedPhase_greenSlowing_isConfirmingStop() {
        XCTAssertEqual(
            TimerEngine.armedPhase(confirmedStopped: false, rawGpsSpeedKmh: 1.5,
                                   gpsSpeedAccuracyMs: 0.5, inPoorGPSLaunchGrace: false),
            .confirmingStop)
    }
}
