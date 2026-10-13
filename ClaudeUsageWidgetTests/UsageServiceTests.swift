import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class UsageServiceTests: XCTestCase {

    private final class SpyDelegate: UsageServiceDelegate {
        var updates: [UsageData] = []
        var failures: [ClaudeAPIError] = []
        var expiries = 0
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

    func test_stop_beforeStart_doesNotCrash() {
        service.stop()
        XCTAssertFalse(service.isPolling)
    }
}
