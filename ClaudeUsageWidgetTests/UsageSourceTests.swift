import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class UsageSourceTests: XCTestCase {

    private var client: OAuthClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = OAuthClient(session: StubURLProtocol.session())
    }

    private func tokens(expiringIn seconds: TimeInterval) -> TokenSet {
        TokenSet(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(seconds), scope: nil)
    }

    func test_ownToken_fresh_isUsedWithoutRefresh() async throws {
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 3600))
        let provider = OwnTokenProvider(store: store, client: client)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "access-1")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func test_ownToken_nearExpiry_refreshesAndSaves() async throws {
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 120))
        StubURLProtocol.handler = { _ in (200, Data(Fixtures.refreshedTokenJSON.utf8)) }
        let provider = OwnTokenProvider(store: store, client: client)
        let token = try await provider.accessToken()
        XCTAssertEqual(token, "access-2")
        XCTAssertEqual(store.tokens?.refreshToken, "refresh-2")
        XCTAssertEqual(store.saves, 1)
    }

    func test_concurrentRefresh_sendsOneRequest() async throws {
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 120))
        StubURLProtocol.handler = { _ in (200, Data(Fixtures.refreshedTokenJSON.utf8)) }
        let provider = OwnTokenProvider(store: store, client: client)
        async let a = provider.accessToken()
        async let b = provider.accessToken()
        let (ta, tb) = try await (a, b)
        XCTAssertEqual(ta, "access-2")
        XCTAssertEqual(tb, "access-2")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func test_ownToken_refreshRefused_clearsStore_andThrowsExpired() async {
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 10))
        StubURLProtocol.handler = { _ in (400, Data(Fixtures.tokenRefusedJSON.utf8)) }
        let provider = OwnTokenProvider(store: store, client: client)
        do {
            _ = try await provider.accessToken()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .sessionExpired)
        }
        XCTAssertNil(store.tokens)
    }

    func test_ownToken_missing_throwsExpired() async {
        let provider = OwnTokenProvider(store: InMemoryTokenStore(), client: client)
        do {
            _ = try await provider.accessToken()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .sessionExpired)
        }
    }

    func test_claudeCodeProvider_validToken_isUsed_expiredThrows() async throws {
        let valid = FakeClaudeCodeCredentials(token: ClaudeCodeToken(accessToken: "cc", expiresAt: Date().addingTimeInterval(3600), subscriptionType: "max"))
        let token = try await ClaudeCodeTokenProvider(reader: valid).accessToken()
        XCTAssertEqual(token, "cc")
        let expired = FakeClaudeCodeCredentials(token: ClaudeCodeToken(accessToken: "cc", expiresAt: Date().addingTimeInterval(-1), subscriptionType: nil))
        do {
            _ = try await ClaudeCodeTokenProvider(reader: expired).accessToken()
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .sessionExpired)
        }
    }

    func test_claudeCodeProvider_cachesInitialToken_andRereadsNearExpiry() async throws {
        let reader = FakeClaudeCodeCredentials(token: ClaudeCodeToken(accessToken: "cc-new", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil))
        let fresh = ClaudeCodeToken(accessToken: "cc", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil)
        let provider = ClaudeCodeTokenProvider(reader: reader, initial: fresh)
        let first = try await provider.accessToken()
        XCTAssertEqual(first, "cc")
        XCTAssertEqual(reader.reads, 0)
        let nearExpiry = ClaudeCodeToken(accessToken: "cc", expiresAt: Date().addingTimeInterval(120), subscriptionType: nil)
        let provider2 = ClaudeCodeTokenProvider(reader: reader, initial: nearExpiry)
        let second = try await provider2.accessToken()
        XCTAssertEqual(second, "cc-new")
        XCTAssertEqual(reader.reads, 1)
    }

    func test_oauthSource_401_refreshesOnce_andRetries() async throws {
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 3600))
        StubURLProtocol.handler = { request in
            if request.url == OAuthConfig.tokenURL { return (200, Data(Fixtures.refreshedTokenJSON.utf8)) }
            let bearer = request.value(forHTTPHeaderField: "Authorization")
            return bearer == "Bearer access-2" ? (200, Data(Fixtures.usageMax20xJSON.utf8)) : (401, Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid"}}"#.utf8))
        }
        let source = OAuthUsageSource(client: client, tokens: OwnTokenProvider(store: store, client: client), identity: .ownToken)
        let response = try await source.fetchUsage()
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(StubURLProtocol.requests.count, 3)   // usage 401, refresh, usage 200
    }

    func test_oauthSource_401Twice_returnsThe401() async throws {
        let store = InMemoryTokenStore(tokens: tokens(expiringIn: 3600))
        StubURLProtocol.handler = { request in
            if request.url == OAuthConfig.tokenURL { return (200, Data(Fixtures.refreshedTokenJSON.utf8)) }
            return (401, Data("{}".utf8))
        }
        let source = OAuthUsageSource(client: client, tokens: OwnTokenProvider(store: store, client: client), identity: .ownToken)
        let response = try await source.fetchUsage()
        XCTAssertEqual(response.status, 401)
        XCTAssertEqual(ClaudeAPIError.classify(response), .sessionExpired)
    }

    func test_webSessionSource_usesOrgPath() async throws {
        let api = FakeClaudeAPI()
        api.responses = [.success(Fixtures.response(200, Fixtures.usageMinimalJSON))]
        let source = WebSessionUsageSource(client: api, orgId: "chat-org")
        _ = try await source.fetchUsage()
        XCTAssertEqual(api.paths, ["/api/organizations/chat-org/usage"])
        XCTAssertEqual(source.identity, .webSession)
    }
}
