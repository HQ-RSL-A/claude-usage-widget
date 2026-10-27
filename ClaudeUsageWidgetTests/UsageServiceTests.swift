import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class UsageServiceTests: XCTestCase {

    private final class SpyDelegate: UsageServiceDelegate {
        var updates: [UsageData] = []
        var failures: [ClaudeAPIError] = []
        var expiries = 0
        var starts = 0
        func usageServiceDidStartFetching(_ service: UsageService) { starts += 1 }
        func usageService(_ service: UsageService, didUpdate data: UsageData) { updates.append(data) }
        func usageService(_ service: UsageService, didFailWith error: ClaudeAPIError) { failures.append(error) }
        func usageServiceDidDetectSessionExpiry(_ service: UsageService) { expiries += 1 }
    }

    private var api: FakeClaudeAPI!
    private var service: UsageService!
    private var spy: SpyDelegate!

    override func setUp() {
        super.setUp()
        api = FakeClaudeAPI()
        service = UsageService(source: WebSessionUsageSource(client: api, orgId: "chat-org"))
        spy = SpyDelegate()
        service.delegate = spy
    }

    override func tearDown() {
        service.stop()
        super.tearDown()
    }

    func test_initialState() {
        XCTAssertNil(service.lastData)
        XCTAssertFalse(service.isPolling)
    }

    func test_fetch_success_updatesDelegateAndLastData_usingOrgPath() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.usageMax20xJSON))]
        await service.fetchNow()
        XCTAssertEqual(api.paths, ["/api/organizations/chat-org/usage"])
        XCTAssertEqual(spy.updates.count, 1)
        XCTAssertEqual(spy.updates.first?.buckets.map(\.kind), [.session, .weeklyAll])
        XCTAssertNotNil(service.lastData)
        XCTAssertTrue(spy.failures.isEmpty)
    }

    func test_fetch_sessionInvalid_reportsExpiryAndStopsPolling() async {
        api.responses = [.success(Fixtures.sessionInvalid403)]
        service.start()
        XCTAssertTrue(service.isPolling)
        await service.fetchNow()
        XCTAssertEqual(spy.expiries, 1)
        XCTAssertTrue(spy.failures.isEmpty)
        XCTAssertFalse(service.isPolling)
    }

    func test_fetch_serverError_reportsFailure_keepsLastData() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.usageMinimalJSON)), .success(Fixtures.server500)]
        await service.fetchNow()
        await service.fetchNow()
        XCTAssertEqual(spy.failures, [.server(500)])
        XCTAssertEqual(service.lastData?.buckets.count, 2)
    }

    func test_fetch_transportFailure_reportsFailure() async {
        api.responses = [.failure(.transport("offline"))]
        await service.fetchNow()
        XCTAssertEqual(spy.failures, [.transport("offline")])
    }

    func test_fetch_undecodableBody_reportsDecodeFailure() async {
        api.responses = [.success(Fixtures.response(200, "<html>"))]
        await service.fetchNow()
        guard case .decode = spy.failures.first else { return XCTFail("\(spy.failures)") }
    }

    func test_fetch_permissionDenied_reportsForbidden_notExpiry() async {
        api.responses = [.success(Fixtures.permissionDenied403)]
        await service.fetchNow()
        XCTAssertEqual(spy.expiries, 0)
        XCTAssertEqual(spy.failures, [.forbidden("Permission denied.")])
    }

    func test_fetch_providerThrowsExpired_reportsExpiry() async {
        let oauth = OAuthClient(session: StubURLProtocol.session())
        let source = OAuthUsageSource(client: oauth, tokens: OwnTokenProvider(store: InMemoryTokenStore(), client: oauth), identity: .ownToken)
        let service = UsageService(source: source)
        let spy = SpyDelegate()
        service.delegate = spy
        await service.fetchNow()
        XCTAssertEqual(spy.expiries, 1)
        XCTAssertFalse(service.isPolling)
    }

    // MARK: - Fetch state

    func test_fetch_reportsStart_andClearsFetching() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.usageMinimalJSON))]
        await service.fetchNow()
        XCTAssertEqual(spy.starts, 1)
        XCTAssertEqual(spy.updates.count, 1)
        XCTAssertFalse(service.isFetching)
    }

    func test_fetch_whileFetching_isIgnored() async {
        let source = GatedUsageSource()
        let service = UsageService(source: source)
        let spy = SpyDelegate()
        service.delegate = spy
        let first = Task { await service.fetchNow() }
        for _ in 0..<50 where source.calls == 0 { await Task.yield() }
        XCTAssertTrue(service.isFetching)
        let second = Task { await service.fetchNow() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(source.calls, 1)
        source.release(Fixtures.response(200, Fixtures.usageMinimalJSON))
        await first.value
        await second.value
        XCTAssertEqual(spy.updates.count, 1)
        XCTAssertEqual(spy.starts, 1)
        XCTAssertFalse(service.isFetching)
    }

    // MARK: - Refresh when a limit resets

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func test_success_schedulesRefreshTenSecondsAfterEarliestReset() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.usageMinimalJSON))]
        service.now = { self.date("2026-10-12T20:00:00Z") }
        await service.fetchNow()
        XCTAssertEqual(service.resetRefreshDate, date("2026-10-12T22:00:10Z"))
        XCTAssertEqual(UsageService.resetRefreshDelay, 10)
    }

    func test_noFutureReset_schedulesNothing() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.usageMinimalJSON))]
        service.now = { self.date("2026-11-01T00:00:00Z") }
        await service.fetchNow()
        XCTAssertEqual(spy.updates.count, 1)
        XCTAssertNil(service.resetRefreshDate)
    }

    func test_stop_cancelsResetRefresh() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.usageMinimalJSON))]
        service.now = { self.date("2026-10-12T20:00:00Z") }
        await service.fetchNow()
        XCTAssertNotNil(service.resetRefreshDate)
        service.stop()
        XCTAssertNil(service.resetRefreshDate)
    }

    func test_fetchFinishingAfterStop_schedulesNothing() async {
        let source = GatedUsageSource()
        let service = UsageService(source: source)
        service.now = { self.date("2026-10-12T20:00:00Z") }
        let fetch = Task { await service.fetchNow() }
        for _ in 0..<50 where source.calls == 0 { await Task.yield() }
        service.stop()
        source.release(Fixtures.response(200, Fixtures.usageMinimalJSON))
        await fetch.value
        XCTAssertNil(service.resetRefreshDate)
    }

    func test_stop_beforeStart_doesNotCrash() {
        service.stop()
        XCTAssertFalse(service.isPolling)
    }
}

/// A usage source that holds every request until the test releases it.
@MainActor
private final class GatedUsageSource: UsageSource {
    let identity: IdentitySource = .ownToken
    private(set) var calls = 0
    private var waiting: [CheckedContinuation<APIResponse, Error>] = []

    func fetchUsage() async throws -> APIResponse {
        calls += 1
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func release(_ response: APIResponse) {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume(returning: response) }
    }
}
