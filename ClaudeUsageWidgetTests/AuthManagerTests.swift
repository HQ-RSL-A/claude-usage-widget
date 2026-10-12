import XCTest
import WebKit
@testable import ClaudeUsageWidget

@MainActor
final class AuthManagerTests: XCTestCase {

    private final class SpyDelegate: AuthManagerDelegate {
        var states: [AuthState] = []
        func authManager(_ manager: AuthManager, didChange state: AuthState) { states.append(state) }
    }

    private static let suite = "io.rsla.ClaudeUsageWidget.tests.auth"

    private var oauth: OAuthClient!
    private var store: InMemoryTokenStore!
    private var claudeCode: FakeClaudeCodeCredentials!
    private var webApi: FakeClaudeAPI!
    private var web: WebSessionAuth!
    private var defaults: UserDefaults!
    private var callback: FakeCallbackServer!
    private var openedURLs: [URL] = []
    private var hasCookies = false
    private var manager: AuthManager!
    private var spy: SpyDelegate!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            if request.url == OAuthConfig.profileURL { return (200, Data(Fixtures.profileJSON.utf8)) }
            if request.url == OAuthConfig.tokenURL { return (200, Data(Fixtures.tokenResponseJSON.utf8)) }
            return (200, Data(Fixtures.usageMax20xJSON.utf8))
        }
        oauth = OAuthClient(session: StubURLProtocol.session())
        store = InMemoryTokenStore()
        claudeCode = FakeClaudeCodeCredentials()
        webApi = FakeClaudeAPI()
        web = WebSessionAuth(client: webApi, dataStore: .nonPersistent())
        web.presentsLoginWindow = false
        defaults = UserDefaults(suiteName: Self.suite)!
        defaults.removePersistentDomain(forName: Self.suite)
        callback = FakeCallbackServer()
        openedURLs = []
        hasCookies = false
        manager = makeManager(oauth: oauth)
        spy = SpyDelegate()
        manager.delegate = spy
    }

    private func makeManager(oauth: OAuthClient) -> AuthManager {
        AuthManager(dependencies: .init(
            oauth: oauth, tokenStore: store, claudeCode: claudeCode, webSession: web, defaults: defaults,
            makeCallbackServer: { [unowned self] in self.callback },
            openURL: { [unowned self] in self.openedURLs.append($0) },
            hasWebSessionCookies: { [unowned self] in self.hasCookies }
        ))
    }

    private func validTokens() -> TokenSet { TokenSet(accessToken: "access-1", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scope: nil) }
    private func validClaudeCode() -> ClaudeCodeToken { ClaudeCodeToken(accessToken: "cc", expiresAt: Date().addingTimeInterval(3600), subscriptionType: "max") }

    func test_nothingAvailable_isSignedOut_withoutClaudeCode() async {
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: false))
        XCTAssertNil(manager.usageSource)
    }

    func test_ownToken_wins_andLoadsProfile() async {
        store.tokens = validTokens()
        claudeCode.token = validClaudeCode()
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .signedIn(.ownToken, Profile(email: "test@example.com", displayName: "Test", organizationName: "Test's Organization", organizationType: "claude_max")))
        XCTAssertEqual(manager.usageSource?.identity, .ownToken)
    }

    func test_claudeCode_usedWhenNoOwnToken() async {
        claudeCode.token = validClaudeCode()
        await manager.checkAuthStatus()
        guard case .signedIn(.claudeCode, let profile) = manager.state else { return XCTFail("\(manager.state)") }
        XCTAssertEqual(profile?.email, "test@example.com")
        XCTAssertEqual(manager.usageSource?.identity, .claudeCode)
    }

    func test_claudeCodeExpired_isSignedOut_butAvailable() async {
        claudeCode.token = ClaudeCodeToken(accessToken: "cc", expiresAt: Date().addingTimeInterval(-10), subscriptionType: nil)
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: true))
    }

    func test_claudeCodeDenied_isRememberedAcrossChecks() async {
        claudeCode.failure = .keychain(-25293)
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: true))
        XCTAssertTrue(defaults.bool(forKey: AuthManager.deniedKey))
        await manager.checkAuthStatus()
        XCTAssertEqual(claudeCode.reads, 1)   // no second prompt
        claudeCode.failure = nil
        claudeCode.token = validClaudeCode()
        await manager.useClaudeCodeToken()
        guard case .signedIn(.claudeCode, _) = manager.state else { return XCTFail("\(manager.state)") }
    }

    func test_upgrade_withWebCookies_enablesWebSession() async {
        hasCookies = true
        webApi.responses = [.success(Fixtures.response(200, Fixtures.twoOrgsJSON))]
        await manager.checkAuthStatus()
        XCTAssertTrue(defaults.bool(forKey: AuthManager.webSessionKey))
        guard case .signedIn(.webSession, _) = manager.state else { return XCTFail("\(manager.state)") }
        XCTAssertEqual(manager.usageSource?.identity, .webSession)
    }

    func test_browserSignIn_savesTokens_andSignsIn() async {
        await manager.signInWithBrowser()
        XCTAssertEqual(callback.expectedState?.isEmpty, false)
        let opened = openedURLs.first
        XCTAssertEqual(opened?.host, "claude.com")
        let items = opened.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        XCTAssertEqual(items.first { $0.name == "redirect_uri" }?.value, "http://localhost:4242/callback")
        XCTAssertEqual(items.first { $0.name == "state" }?.value, callback.expectedState)
        XCTAssertEqual(store.tokens?.accessToken, "access-1")
        XCTAssertTrue(callback.stopped)
        guard case .signedIn(.ownToken, _) = manager.state else { return XCTFail("\(manager.state)") }
        XCTAssertTrue(spy.states.contains(.signingIn))
    }

    func test_browserSignIn_timeout_isSignedOut_withMessage() async {
        callback.codeToDeliver = .failure(.callbackTimeout)
        await manager.signInWithBrowser()
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: false))
        XCTAssertEqual(manager.signInMessage, "Sign-in timed out, try again")
        XCTAssertTrue(callback.stopped)
    }

    func test_signOut_duringBrowserFlow_cancelsIt() async {
        callback.hold = true
        let flow = Task { await self.manager.signInWithBrowser() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(manager.state, .signingIn)
        manager.signOut()
        await flow.value
        XCTAssertTrue(callback.stopped)
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: false))
    }

    func test_signOut_clearsOwnToken_andOptsOutOfClaudeCode() async {
        store.tokens = validTokens()
        claudeCode.token = validClaudeCode()
        await manager.checkAuthStatus()
        manager.signOut()
        XCTAssertNil(store.tokens)
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: true))
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: true))   // opted out, Claude Code not used
        XCTAssertNil(manager.usageSource)
    }

    func test_sessionDidExpire_ownToken_clearsStore() async {
        store.tokens = validTokens()
        await manager.checkAuthStatus()
        manager.sessionDidExpire()
        XCTAssertEqual(manager.state, .sessionExpired(.ownToken))
        XCTAssertNil(store.tokens)
        XCTAssertNil(manager.usageSource)
    }

    func test_sessionDidExpire_whenSignedOut_isIgnored() async {
        await manager.checkAuthStatus()
        manager.sessionDidExpire()
        XCTAssertEqual(manager.state, .signedOut(claudeCodeAvailable: false))
    }

    func test_transportFailureOnOwnToken_isUnreachable_andRetries() async {
        store.tokens = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(10), scope: nil)   // needs a refresh
        manager = makeManager(oauth: OAuthClient(session: FailingURLProtocol.session()))
        manager.unreachableRetryInterval = 60
        await manager.checkAuthStatus()
        XCTAssertEqual(manager.state, .unreachable)
        XCTAssertTrue(manager.isRetryScheduled)
    }
}
