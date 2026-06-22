import XCTest
@testable import AccelTimer

/// 計測ロジックの中核である「速度しきい値クロス時刻の線形補間」を検証する。
/// `TimerEngine.interpolatedCrossTime` はセンサー状態に依存しない純粋関数のため、
/// 実機・シミュレーターのセンサー無しで決定的にテストできる。
@MainActor
final class TimerEngineSplitTests: XCTestCase {

    private let base = Date(timeIntervalSinceReferenceDate: 1_000)

    /// 区間の中点でしきい値に到達するケース：0→20 m/s を 2 秒、しきい値 10 m/s → 1.0 秒。
    func testInterpolatesMidpoint() {
        let cross = TimerEngine.interpolatedCrossTime(
            threshold: 10,
            prev: (speed: 0, time: base),
            curr: (speed: 20, time: base.addingTimeInterval(2))
        )
        XCTAssertEqual(cross.timeIntervalSince(base), 1.0, accuracy: 1e-9)
    }

    /// しきい値が curr 速度と一致 → クロス時刻は curr の時刻（frac = 1）。
    func testThresholdEqualsCurrSpeed() {
        let curr = base.addingTimeInterval(0.5)
        let cross = TimerEngine.interpolatedCrossTime(
            threshold: 20,
            prev: (speed: 10, time: base),
            curr: (speed: 20, time: curr)
        )
        XCTAssertEqual(cross.timeIntervalSince(base), 0.5, accuracy: 1e-9)
    }

    /// しきい値が prev 速度と一致 → クロス時刻は prev の時刻（frac = 0）。
    func testThresholdEqualsPrevSpeed() {
        let cross = TimerEngine.interpolatedCrossTime(
            threshold: 10,
            prev: (speed: 10, time: base),
            curr: (speed: 20, time: base.addingTimeInterval(1))
        )
        XCTAssertEqual(cross.timeIntervalSince(base), 0.0, accuracy: 1e-9)
    }

    /// 実走に近い GPS サンプル間（40 km/h = 11.111… m/s 通過）をミリ秒精度で補間。
    func testRealisticSubsampleInterpolation() {
        let threshold = 40.0 / 3.6                 // ≒ 11.1111 m/s
        let prevSpeed = 11.0
        let currSpeed = 11.2
        let dt = 0.1
        let cross = TimerEngine.interpolatedCrossTime(
            threshold: threshold,
            prev: (speed: prevSpeed, time: base),
            curr: (speed: currSpeed, time: base.addingTimeInterval(dt))
        )
        let expectedFrac = (threshold - prevSpeed) / (currSpeed - prevSpeed)
        XCTAssertEqual(cross.timeIntervalSince(base), expectedFrac * dt, accuracy: 1e-9)
        // 区間内（0〜0.1 秒）に収まることも確認
        XCTAssertGreaterThanOrEqual(cross.timeIntervalSince(base), 0)
        XCTAssertLessThanOrEqual(cross.timeIntervalSince(base), dt)
    }

    /// スプリットしきい値が 40/60/80/100 km/h を m/s 換算した値であること。
    func testSplitThresholdsAreCorrect() {
        let expected = [40.0, 60.0, 80.0, 100.0].map { $0 / 3.6 }
        XCTAssertEqual(TimerEngine.splitThresholdsMs.count, 4)
        for (actual, exp) in zip(TimerEngine.splitThresholdsMs, expected) {
            XCTAssertEqual(actual, exp, accuracy: 1e-9)
        }
    }

    /// 位置ベース速度が未確定の間は、古い値で正常な発進直後のGPSを偽Doppler扱いしない。
    func testFakeDopplerRequiresFreshPositionSpeed() {
        XCTAssertFalse(TimerEngine.isFakeDopplerSpeed(speedKmh: 45.0, positionSpeedKmh: nil))
    }

    /// Doppler速度だけが高く、同じサンプルで確認した位置ベース速度が大きく低い場合は偽高速とみなす。
    func testFakeDopplerRejectsStationaryHighSpeedSpike() {
        XCTAssertTrue(TimerEngine.isFakeDopplerSpeed(speedKmh: 80.0, positionSpeedKmh: 5.0))
        XCTAssertFalse(TimerEngine.isFakeDopplerSpeed(speedKmh: 80.0, positionSpeedKmh: 45.0))
    }

    /// CoreMotionだけでスプリットを先行検出できるのは、直近GPS補正が新鮮な間だけ。
    /// GPSが数秒途切れた状態で加速度積分だけが進むと偽スプリット/偽FINISHの原因になる。
    func testMotionSplitRequiresFreshGPSAnchor() {
        let lastGPS = base
        XCTAssertTrue(TimerEngine.canUseMotionSplit(
            currentTime: lastGPS.addingTimeInterval(1.0),
            lastGPSTime: lastGPS))
        XCTAssertFalse(TimerEngine.canUseMotionSplit(
            currentTime: lastGPS.addingTimeInterval(2.0),
            lastGPSTime: lastGPS))
        XCTAssertFalse(TimerEngine.canUseMotionSplit(
            currentTime: base,
            lastGPSTime: .distantPast))
    }

    /// 微速クリープの誤開始を避けるため、GPS発進トリガーは速度精度にかかわらず13km/h。
    /// 実際のt=0はCoreMotionのlookBackで補正するため、開始時刻精度はここで落とさない。
    func testLaunchThresholdIsThirteenKmh() {
        XCTAssertEqual(TimerEngine.launchThresholdMs(speedAccuracyMs: 0.3), 13.0 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(TimerEngine.launchThresholdMs(speedAccuracyMs: 1.8), 13.0 / 3.6, accuracy: 1e-9)
    }

    /// 停車確認 Path A：Doppler速度精度が良好なときはDoppler速度だけで判定する。
    /// （sAcc赤時の位置ベース Path B は TimerEngineLaunchTests で検証）
    func testStoppedConfirmationUsesDopplerSpeedAccuracy() {
        XCTAssertTrue(TimerEngine.shouldConfirmStopped(speedMs: 0.0, speedAccuracyMs: 0.31,
                                                       positionSpeedKmh: 0, positionSpeedValid: false))
        XCTAssertTrue(TimerEngine.shouldConfirmStopped(speedMs: 0.9, speedAccuracyMs: 0.31,
                                                       positionSpeedKmh: 0, positionSpeedValid: false))
        XCTAssertFalse(TimerEngine.shouldConfirmStopped(speedMs: 1.2, speedAccuracyMs: 0.31,
                                                        positionSpeedKmh: 0, positionSpeedValid: false))
        XCTAssertFalse(TimerEngine.shouldConfirmStopped(speedMs: 0.0, speedAccuracyMs: 2.0,
                                                        positionSpeedKmh: 0, positionSpeedValid: false))
    }

    /// 停車確認済みからGPS速度精度が赤のまま発進した直後は、緑へ戻るまで短時間だけラッチを保持する。
    func testPoorGPSLaunchGracePreservesStoppedLatchBriefly() {
        XCTAssertTrue(TimerEngine.shouldPreserveStoppedLatchDuringPoorGPS(
            wasConfirmedStopped: true,
            movingDuration: 2.0
        ))
        XCTAssertFalse(TimerEngine.shouldPreserveStoppedLatchDuringPoorGPS(
            wasConfirmedStopped: true,
            movingDuration: 6.0
        ))
        XCTAssertFalse(TimerEngine.shouldPreserveStoppedLatchDuringPoorGPS(
            wasConfirmedStopped: false,
            movingDuration: 1.0
        ))
    }

    /// 偽発進判定はlookBackされたt=0ではなく、GPSが発進を検知した実時刻から5秒後に評価する。
    func testFalseLaunchConfirmationUsesDetectionTime() {
        let detected = base.addingTimeInterval(10)
        XCTAssertFalse(TimerEngine.shouldAbortFalseLaunch(
            launchDetectedAt: detected,
            currentTime: detected.addingTimeInterval(1),
            peakSpeedKmh: 0
        ))
        XCTAssertTrue(TimerEngine.shouldAbortFalseLaunch(
            launchDetectedAt: detected,
            currentTime: detected.addingTimeInterval(6),
            peakSpeedKmh: 20
        ))
        XCTAssertFalse(TimerEngine.shouldAbortFalseLaunch(
            launchDetectedAt: detected,
            currentTime: detected.addingTimeInterval(6),
            peakSpeedKmh: 30
        ))
    }

    /// READY/発進判定に使えるGPSは、処理時刻から大きく遅れていないfixだけ。
    func testLiveGPSFreshnessRejectsDelayedBatchSamples() {
        XCTAssertTrue(TimerEngine.isFreshLiveGPSSample(processingAge: 0.2))
        XCTAssertTrue(TimerEngine.isFreshLiveGPSSample(processingAge: 2.0))
        XCTAssertFalse(TimerEngine.isFreshLiveGPSSample(processingAge: 2.5))
        XCTAssertFalse(TimerEngine.isFreshLiveGPSSample(processingAge: -0.1))
    }

    /// 元の AccelTimer では新しい実験的GPS鮮度ゲートを無効にし、従来挙動を維持する。
    /// AccelTimerX のみ enabled=true で検証する。
    func testExperimentalFreshnessGateCanBeDisabledForOriginalApp() {
        XCTAssertTrue(TimerEngine.isFreshLiveGPSSample(processingAge: 20.0, enabled: false))
        XCTAssertTrue(TimerEngine.canUseMotionSplit(
            currentTime: base.addingTimeInterval(20.0),
            lastGPSTime: base,
            enabled: false))
    }
}
