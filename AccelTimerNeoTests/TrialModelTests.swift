import XCTest
@testable import AccelTimerNeo

/// トライアル課金モデル（累計30回 + 以後1日1回）の回帰テスト。
@MainActor
final class TrialModelTests: XCTestCase {
    private let today = "2026-06-21"
    private let yesterday = "2026-06-20"

    func testCanMeasureBeforeTrialLimit() {
        XCTAssertTrue(StoreManager.canMeasure(isPurchased: false,
                                              trialCount: StoreManager.freeTrialLimit - 1,
                                              lastFreeDay: today,
                                              today: today))
    }

    func testCannotMeasureAfterDailyFreeUsed() {
        XCTAssertFalse(StoreManager.canMeasure(isPurchased: false,
                                               trialCount: StoreManager.freeTrialLimit,
                                               lastFreeDay: today,
                                               today: today))
    }

    func testCanMeasureOncePerNewDayAfterTrialLimit() {
        XCTAssertTrue(StoreManager.canMeasure(isPurchased: false,
                                              trialCount: StoreManager.freeTrialLimit,
                                              lastFreeDay: yesterday,
                                              today: today))
    }

    func testPurchasedCanAlwaysMeasure() {
        XCTAssertTrue(StoreManager.canMeasure(isPurchased: true,
                                              trialCount: StoreManager.freeTrialLimit + 100,
                                              lastFreeDay: today,
                                              today: today))
    }

    func testKmhTrialTargetRequires100KmhCompletion() {
        let complete = makeRecord(isComplete: true)
        let partial = makeRecord(isComplete: false)

        XCTAssertTrue(complete.completedTrialTarget(unit: .kmh))
        XCTAssertFalse(partial.completedTrialTarget(unit: .kmh))
    }

    func testMphTrialTargetRequires60MphSplit() {
        let reached60 = makeRecord(isComplete: false, mphSplit60: 8.7)
        let below60 = makeRecord(isComplete: true, mphSplit60: 0)

        XCTAssertTrue(reached60.completedTrialTarget(unit: .mph))
        XCTAssertFalse(below60.completedTrialTarget(unit: .mph))
    }

    private func makeRecord(isComplete: Bool, mphSplit60: Double = 0) -> MeasurementRecord {
        MeasurementRecord(date: Date(),
                          totalTime: isComplete ? 10.0 : 6.0,
                          split40: 3.0,
                          split60: 5.0,
                          split80: isComplete ? 7.0 : 0,
                          mphSplit15: mphSplit60 > 0 ? 2.0 : 0,
                          mphSplit30: mphSplit60 > 0 ? 4.0 : 0,
                          mphSplit45: mphSplit60 > 0 ? 6.0 : 0,
                          mphSplit60: mphSplit60,
                          maxSpeedKmh: isComplete ? 101.0 : 90.0,
                          isComplete: isComplete)
    }
}
