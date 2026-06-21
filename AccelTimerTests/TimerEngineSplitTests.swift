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

    /// 微速クリープの誤開始を避けるため、GPS発進トリガーは速度精度にかかわらず10km/h。
    /// 実際のt=0はCoreMotionのlookBackで補正するため、開始時刻精度はここで落とさない。
    func testLaunchThresholdIsTenKmh() {
        XCTAssertEqual(TimerEngine.launchThresholdMs(speedAccuracyMs: 0.3), 10.0 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(TimerEngine.launchThresholdMs(speedAccuracyMs: 1.8), 10.0 / 3.6, accuracy: 1e-9)
    }
}
