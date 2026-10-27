import XCTest
@testable import ClaudeUsageWidget

final class ModelsTests: XCTestCase {

    private func bucket(_ kind: BucketKind, _ percent: Double, resetsAt: Date? = nil) -> UsageBucket {
        UsageBucket(kind: kind, percentUsed: percent, resetsAt: resetsAt, lockedReason: nil)
    }

    // MARK: - RingColorState (unchanged behaviour)

    func test_ringColor_thresholds() {
        XCTAssertEqual(RingColorState.from(percent: 0.0), .normal)
        XCTAssertEqual(RingColorState.from(percent: 0.59), .normal)
        XCTAssertEqual(RingColorState.from(percent: 0.60), .amber)
        XCTAssertEqual(RingColorState.from(percent: 0.84), .amber)
        XCTAssertEqual(RingColorState.from(percent: 0.85), .critical)
        XCTAssertEqual(RingColorState.from(percent: 1.0), .critical)
    }

    func test_ringMetricMode_defaultIsSession() {
        XCTAssertEqual(RingMetricMode.default, .session)
    }

    // MARK: - Ring value per mode

    func test_ringValue_sessionMode_returnsSessionPercent() {
        let data = UsageData(buckets: [bucket(.session, 0.42), bucket(.weeklyAll, 0.67), bucket(.weeklySonnet, 0.23)], extraUsage: nil)
        XCTAssertEqual(data.ringValue(for: .session), 0.42, accuracy: 0.001)
    }

    func test_ringValue_weeklyMode_returnsMaxWeekly() {
        let data = UsageData(buckets: [bucket(.session, 0.42), bucket(.weeklyAll, 0.67), bucket(.weeklyOpus, 0.80), bucket(.weeklySonnet, 0.23)], extraUsage: nil)
        XCTAssertEqual(data.ringValue(for: .weekly), 0.80, accuracy: 0.001)
    }

    func test_ringValue_missingBuckets_isZero() {
        let weeklyOnly = UsageData(buckets: [bucket(.weeklyAll, 0.5)], extraUsage: nil)
        XCTAssertEqual(weeklyOnly.ringValue(for: .session), 0.0, accuracy: 0.001)
        let sessionOnly = UsageData(buckets: [bucket(.session, 0.5)], extraUsage: nil)
        XCTAssertEqual(sessionOnly.ringValue(for: .weekly), 0.0, accuracy: 0.001)
        XCTAssertEqual(UsageData(buckets: [], extraUsage: nil).ringValue(for: .session), 0.0, accuracy: 0.001)
    }

    func test_ringColorState_forMode() {
        let data = UsageData(buckets: [bucket(.session, 0.42), bucket(.weeklyAll, 0.67)], extraUsage: nil)
        XCTAssertEqual(data.ringColorState(for: .session), .normal)
        XCTAssertEqual(data.ringColorState(for: .weekly), .amber)
    }

    // MARK: - Bucket display

    func test_barColorState_perBucket() {
        XCTAssertEqual(bucket(.session, 0.42).barColorState, .normal)
        XCTAssertEqual(bucket(.session, 0.67).barColorState, .amber)
        XCTAssertEqual(bucket(.session, 0.90).barColorState, .critical)
    }

    func test_resetsInDisplay_future_showsCountdown() {
        let display = bucket(.session, 0.5, resetsAt: Date().addingTimeInterval(2520)).resetsInDisplay
        XCTAssertTrue(display.hasPrefix("resets in"), display)
        XCTAssertTrue(display.contains("m"), display)
    }

    func test_resetsInDisplay_pastDate_showsPlaceholder() {
        XCTAssertEqual(bucket(.session, 0.5, resetsAt: Date().addingTimeInterval(-60)).resetsInDisplay, "–")
        XCTAssertEqual(bucket(.session, 0.5, resetsAt: nil).resetsInDisplay, "–")
    }

    func test_resetsAtDisplay_formatsClockTime() {
        var comps = DateComponents()
        comps.weekday = 6
        comps.hour = 9
        comps.minute = 0
        let date = Calendar.current.nextDate(after: Date(), matching: comps, matchingPolicy: .nextTime)!
        XCTAssertTrue(bucket(.weeklyAll, 0.2, resetsAt: date).resetsAtDisplay?.contains("9:00") == true)
        XCTAssertNil(bucket(.weeklyAll, 0.2, resetsAt: nil).resetsAtDisplay)
    }

    // MARK: - What's left

    func test_percentLeft_isHundredMinusRoundedUsed() {
        XCTAssertEqual(bucket(.session, 0.12).percentLeft, 88)
        XCTAssertEqual(bucket(.session, 0.125).percentLeft, 87)
        XCTAssertEqual(bucket(.session, 0.0).percentLeft, 100)
        XCTAssertEqual(bucket(.session, 1.0).percentLeft, 0)
        XCTAssertEqual(bucket(.session, 1.3).percentLeft, 0)
        XCTAssertEqual(bucket(.session, -0.1).percentLeft, 100)
    }

    func test_isAtLimit_whenNothingIsLeft() {
        XCTAssertTrue(bucket(.session, 0.996).isAtLimit)
        XCTAssertFalse(bucket(.session, 0.99).isAtLimit)
    }

    func test_weekBucket_isTheWeeklyLimitClosestToRunningOut() {
        let mixed = UsageData(buckets: [bucket(.session, 0.9), bucket(.weeklyAll, 0.67), bucket(.weeklyOpus, 0.80), bucket(.weeklySonnet, 0.23)], extraUsage: nil)
        XCTAssertEqual(mixed.weekBucket?.kind, .weeklyOpus)
        XCTAssertEqual(mixed.sessionBucket?.kind, .session)
        let tie = UsageData(buckets: [bucket(.weeklyAll, 0.5), bucket(.weeklySonnet, 0.5)], extraUsage: nil)
        XCTAssertEqual(tie.weekBucket?.kind, .weeklyAll)
        XCTAssertNil(UsageData(buckets: [bucket(.session, 0.5)], extraUsage: nil).weekBucket)
    }

    func test_nextReset_isTheEarliestFutureReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = UsageData(buckets: [
            bucket(.session, 0.1, resetsAt: now.addingTimeInterval(-60)),
            bucket(.weeklyAll, 0.1, resetsAt: now.addingTimeInterval(4 * 86400)),
            bucket(.weeklyOpus, 0.1, resetsAt: now.addingTimeInterval(3 * 3600)),
            bucket(.weeklySonnet, 0.1, resetsAt: nil),
        ], extraUsage: nil)
        XCTAssertEqual(data.nextReset(after: now), now.addingTimeInterval(3 * 3600))
        XCTAssertNil(data.nextReset(after: now.addingTimeInterval(5 * 86400)))
    }

    // MARK: - Menu bar layout preference

    private func freshDefaults() -> UserDefaults {
        let name = "io.rsla.ClaudeUsageWidget.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func test_menuBarLayout_defaultsToBoth_andRoundTrips() {
        let defaults = freshDefaults()
        XCTAssertEqual(MenuBarLayout.load(from: defaults), .both)
        MenuBarLayout.week.save(to: defaults)
        XCTAssertEqual(MenuBarLayout.load(from: defaults), .week)
        defaults.set("sideways", forKey: MenuBarLayout.userDefaultsKey)
        XCTAssertEqual(MenuBarLayout.load(from: defaults), .both)
        XCTAssertEqual(MenuBarLayout.userDefaultsKey, "menuBarShows")
        XCTAssertEqual(MenuBarLayout.allCases.map(\.menuTitle), ["Session and Week", "Session Only", "Week Only"])
    }

    func test_menuBarLayout_removeLegacyKeys_deletesRingMetricMode() {
        let defaults = freshDefaults()
        defaults.set("weekly", forKey: "ringMetricMode")
        MenuBarLayout.week.save(to: defaults)
        MenuBarLayout.removeLegacyKeys(from: defaults)
        XCTAssertNil(defaults.object(forKey: "ringMetricMode"))
        XCTAssertEqual(MenuBarLayout.load(from: defaults), .week)
    }

    func test_bucketKind_labelsAndWeeklyFlag() {
        XCTAssertEqual(BucketKind.session.label, "Current session")
        XCTAssertEqual(BucketKind.weeklyAll.label, "Weekly (all models)")
        XCTAssertEqual(BucketKind.weeklyOpus.label, "Weekly (Opus)")
        XCTAssertEqual(BucketKind.weeklySonnet.label, "Weekly (Sonnet)")
        XCTAssertFalse(BucketKind.session.isWeekly)
        XCTAssertTrue(BucketKind.weeklyOpus.isWeekly)
    }

    // MARK: - Decoding real shapes

    func test_decode_max20x_dropsNullBucketsAndIgnoresNoise() throws {
        let data = try UsageData.decode(from: Data(Fixtures.usageMax20xJSON.utf8))
        XCTAssertEqual(data.buckets.map(\.kind), [.session, .weeklyAll])
        XCTAssertEqual(data.bucket(.session)?.percentUsed ?? -1, 0.08, accuracy: 0.001)
        XCTAssertEqual(data.bucket(.weeklyAll)?.percentUsed ?? -1, 0.73, accuracy: 0.001)
        XCTAssertNotNil(data.bucket(.session)?.resetsAt)
        XCTAssertNil(data.bucket(.weeklySonnet))
        XCTAssertEqual(data.extraUsage, ExtraUsage(isEnabled: false, percentUsed: nil))
    }

    func test_decode_proLike_keepsOpusSonnetAndExtraUsage() throws {
        let data = try UsageData.decode(from: Data(Fixtures.usageProLikeJSON.utf8))
        XCTAssertEqual(data.buckets.map(\.kind), [.session, .weeklyAll, .weeklyOpus, .weeklySonnet])
        XCTAssertEqual(data.bucket(.weeklyOpus)?.percentUsed ?? -1, 0.40, accuracy: 0.001)
        XCTAssertEqual(data.extraUsage?.isEnabled, true)
        XCTAssertEqual(data.extraUsage?.percentUsed ?? -1, 0.35, accuracy: 0.001)
    }

    func test_decode_minimal_hasTwoBuckets() throws {
        let data = try UsageData.decode(from: Data(Fixtures.usageMinimalJSON.utf8))
        XCTAssertEqual(data.buckets.count, 2)
        XCTAssertNil(data.extraUsage)
    }

    func test_decode_nullSession_keepsWeekly() throws {
        let data = try UsageData.decode(from: Data(Fixtures.usageNoSessionJSON.utf8))
        XCTAssertEqual(data.buckets.map(\.kind), [.weeklyAll])
        XCTAssertEqual(data.ringValue(for: .session), 0.0, accuracy: 0.001)
    }

    func test_decode_skipsBucketWithNullUtilization() throws {
        let data = try UsageData.decode(from: Data(Fixtures.usageNullUtilizationJSON.utf8))
        XCTAssertEqual(data.buckets.map(\.kind), [.weeklyAll])
        XCTAssertNil(data.bucket(.weeklyAll)?.resetsAt)
    }

    func test_decode_wholeSecondDates() throws {
        let data = try UsageData.decode(from: Data(#"{"five_hour": {"utilization": 78, "resets_at": "2026-03-08T01:00:00+00:00"}}"#.utf8))
        XCTAssertNotNil(data.bucket(.session)?.resetsAt)
    }

    func test_decode_garbage_throws() {
        XCTAssertThrowsError(try UsageData.decode(from: Data("<html>".utf8)))
    }
}
