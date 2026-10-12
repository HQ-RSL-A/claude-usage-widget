import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class WebSessionAuthTests: XCTestCase {

    private final class SpyDelegate: WebSessionAuthDelegate {
        var states: [WebSessionState] = []
        var onChange: ((WebSessionState) -> Void)?
        func webSessionAuth(_ auth: WebSessionAuth, didChange state: WebSessionState) {
            states.append(state)
            onChange?(state)
        }
    }

    private var api: FakeClaudeAPI!
    private var manager: WebSessionAuth!
    private var spy: SpyDelegate!

    override func setUp() {
        super.setUp()
        api = FakeClaudeAPI()
        manager = WebSessionAuth(client: api, dataStore: .nonPersistent())
        manager.presentsLoginWindow = false
        spy = SpyDelegate()
        manager.delegate = spy
    }

    func test_startsUnknown() {
        XCTAssertEqual(manager.state, .unknown)
    }

    func test_verify_validSession_signsInToChatOrg_notConsoleOrg() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.twoOrgsJSON))]
        let state = await manager.verifySession()
        guard case .signedIn(let org, let count) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(org.uuid, "chat-org")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(api.paths, ["/api/organizations"])
        XCTAssertEqual(spy.states, [state])
    }

    func test_verify_twoChatOrgs_lastActiveWins_andCountIsTwo() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.twoChatOrgsJSON))]
        api.lastActiveOrg = "chat-b"
        let state = await manager.verifySession()
        guard case .signedIn(let org, let count) = state else { return XCTFail("\(state)") }
        XCTAssertEqual(org.uuid, "chat-b")
        XCTAssertEqual(count, 2)
    }

    func test_verify_consoleOnly_isNoChatOrg() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.consoleOnlyJSON))]
        let state = await manager.verifySession()
        XCTAssertEqual(state, .noChatOrg)
    }

    func test_verify_emptyOrgList_isNoChatOrg() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.emptyOrgsJSON))]
        let state = await manager.verifySession()
        XCTAssertEqual(state, .noChatOrg)
    }

    func test_checkAuthStatus_noSession_isSignedOut_andRequestsLoginOnce() async {
        api.responses = [.success(Fixtures.sessionInvalid403)]
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertEqual(manager.loginWindowRequests, 1)
    }

    func test_checkAuthStatus_transportFailure_isUnreachable_noLoginWindow() async {
        api.responses = [.failure(.transport("offline"))]
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .unreachable)
        XCTAssertEqual(manager.loginWindowRequests, 0)
    }

    func test_checkAuthStatus_serverError_isUnreachable() async {
        api.responses = [.success(Fixtures.server500)]
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .unreachable)
    }

    func test_verify_sessionInvalidWhileSignedIn_isSessionExpired() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.twoOrgsJSON)), .success(Fixtures.sessionInvalid403)]
        _ = await manager.verifySession()
        let state = await manager.verifySession()
        XCTAssertEqual(state, .sessionExpired)
    }

    func test_sessionDidExpire_twice_opensLoginOnce() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.twoOrgsJSON))]
        _ = await manager.verifySession()
        manager.sessionDidExpire()
        manager.sessionDidExpire()
        XCTAssertEqual(manager.state, .sessionExpired)
        XCTAssertEqual(manager.loginWindowRequests, 1)
    }

    func test_signInAfterExpiry_allowsNextExpiryToOpenLoginAgain() async {
        api.responses = [
            .success(Fixtures.response(200, Fixtures.twoOrgsJSON)),
            .success(Fixtures.response(200, Fixtures.twoOrgsJSON)),
        ]
        _ = await manager.verifySession()
        manager.sessionDidExpire()
        _ = await manager.verifySession()
        manager.sessionDidExpire()
        XCTAssertEqual(manager.loginWindowRequests, 2)
    }

    func test_loginWindowSawCandidate_falseUntilSessionExists() async {
        api.responses = [.success(Fixtures.sessionInvalid403), .success(Fixtures.response(200, Fixtures.twoOrgsJSON))]
        let first = await manager.loginWindowSawCandidate()
        let second = await manager.loginWindowSawCandidate()
        XCTAssertFalse(first)
        XCTAssertTrue(second)
        guard case .signedIn = manager.state else { return XCTFail("\(manager.state)") }
    }

    func test_sessionDidExpire_whenNotSignedIn_isIgnored() async {
        api.responses = [.success(Fixtures.sessionInvalid403)]
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertEqual(manager.loginWindowRequests, 1)
        manager.sessionDidExpire()   // a stale poll finishing after sign-out
        XCTAssertEqual(manager.state, .signedOut)
        XCTAssertEqual(manager.loginWindowRequests, 1)
    }

    func test_unreachable_schedulesRetry_andRecoversWhenClaudeAnswers() async {
        manager.unreachableRetryInterval = 0.05
        api.responses = [.failure(.transport("offline")), .success(Fixtures.response(200, Fixtures.twoOrgsJSON))]
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .unreachable)
        XCTAssertTrue(manager.isRetryScheduled)
        let signedIn = expectation(description: "signed in after the retry")
        spy.onChange = { state in if case .signedIn = state { signedIn.fulfill() } }
        await fulfillment(of: [signedIn], timeout: 3)
        XCTAssertFalse(manager.isRetryScheduled)
        XCTAssertEqual(api.paths.count, 2)
    }

    func test_unreachable_retryCanBeDisabledByTheOwner() async {
        manager.retriesWhenUnreachable = false
        api.responses = [.failure(.transport("offline"))]
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .unreachable)
        XCTAssertFalse(manager.isRetryScheduled)
    }

    func test_unreachable_retryThatFailsAgain_reschedules() async {
        manager.unreachableRetryInterval = 0.05
        api.responses = [.failure(.transport("offline")), .failure(.transport("still offline"))]
        await manager.checkAuthStatus()
        let secondAttempt = expectation(description: "second attempt made")
        secondAttempt.assertForOverFulfill = false
        let check = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [api] _ in
            if (api?.paths.count ?? 0) >= 2 { secondAttempt.fulfill() }
        }
        await fulfillment(of: [secondAttempt], timeout: 3)
        check.invalidate()
        XCTAssertEqual(manager.state, .unreachable)
        XCTAssertTrue(manager.isRetryScheduled)
    }

    func test_verify_transientFailureWhileSignedIn_keepsSignedIn() async {
        api.responses = [.success(Fixtures.response(200, Fixtures.twoOrgsJSON)), .failure(.transport("blip"))]
        _ = await manager.verifySession()
        let state = await manager.verifySession()
        guard case .signedIn = state else { return XCTFail("\(state)") }
    }

    // MARK: - LoginWindowController URL heuristic (now only a trigger for an API check)

    func test_isCandidateLoginURL() {
        let vc = LoginWindowController(authManager: nil, dataStore: .nonPersistent())
        XCTAssertTrue(vc.isCandidateLoginURL(URL(string: "https://claude.ai/")!))
        XCTAssertTrue(vc.isCandidateLoginURL(URL(string: "https://claude.ai/chats")!))
        XCTAssertTrue(vc.isCandidateLoginURL(URL(string: "https://claude.ai/settings/usage")!))
        XCTAssertFalse(vc.isCandidateLoginURL(URL(string: "https://claude.ai/login")!))
        XCTAssertFalse(vc.isCandidateLoginURL(URL(string: "https://claude.ai/auth/callback")!))
        XCTAssertFalse(vc.isCandidateLoginURL(URL(string: "https://google.com/")!))
    }
}
