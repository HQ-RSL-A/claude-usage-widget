import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class OAuthClientTests: XCTestCase {

    private var client: OAuthClient!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let now = fixedNow
        client = OAuthClient(session: StubURLProtocol.session(), now: { now })
    }

    private func body(of request: URLRequest) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: request.bodyData ?? Data()) as? [String: String]) ?? [:]
    }

    func test_authorizeURL_carriesEveryParameter() {
        let url = client.authorizeURL(redirectURI: "http://localhost:4242/callback", challenge: "CH", state: "ST")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "claude.com")
        XCTAssertEqual(url.path, "/cai/oauth/authorize")
        XCTAssertEqual(dict["code"], "true")
        XCTAssertEqual(dict["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(dict["response_type"], "code")
        XCTAssertEqual(dict["redirect_uri"], "http://localhost:4242/callback")
        XCTAssertEqual(dict["scope"], "user:profile user:inference")
        XCTAssertEqual(dict["code_challenge"], "CH")
        XCTAssertEqual(dict["code_challenge_method"], "S256")
        XCTAssertEqual(dict["state"], "ST")
    }

    func test_exchange_postsExactBodyAndHeaders_andDecodesTokens() async throws {
        StubURLProtocol.handler = { _ in (200, Data(Fixtures.tokenResponseJSON.utf8)) }
        let tokens = try await client.exchange(code: "CODE", verifier: "VER", redirectURI: "http://localhost:4242/callback", state: "ST")
        XCTAssertEqual(tokens.accessToken, "access-1")
        XCTAssertEqual(tokens.refreshToken, "refresh-1")
        XCTAssertEqual(tokens.expiresAt, fixedNow.addingTimeInterval(28800))
        XCTAssertEqual(tokens.scope, "user:inference user:profile")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ClaudeUsageWidget/\(AppInfo.version) (macOS)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(body(of: request), ["grant_type": "authorization_code", "code": "CODE", "state": "ST", "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e", "redirect_uri": "http://localhost:4242/callback", "code_verifier": "VER"])
    }

    func test_refresh_postsRefreshGrant() async throws {
        StubURLProtocol.handler = { _ in (200, Data(Fixtures.refreshedTokenJSON.utf8)) }
        let tokens = try await client.refresh("refresh-1")
        XCTAssertEqual(tokens.accessToken, "access-2")
        XCTAssertEqual(body(of: StubURLProtocol.requests[0]), ["grant_type": "refresh_token", "refresh_token": "refresh-1", "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"])
    }

    func test_tokenRefused_throwsOAuthWithDescription() async {
        StubURLProtocol.handler = { _ in (400, Data(Fixtures.tokenRefusedJSON.utf8)) }
        do {
            _ = try await client.refresh("bad")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .oauth("The refresh token is invalid"))
        }
    }

    func test_cloudflare403_throwsForbidden() async {
        StubURLProtocol.handler = { _ in (403, Data("error code: 1010".utf8)) }
        do {
            _ = try await client.exchange(code: "c", verifier: "v", redirectURI: "r", state: "s")
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .forbidden("Permission denied"))
        }
    }

    func test_usage_sendsBearer_andReturnsRawResponse() async throws {
        StubURLProtocol.handler = { _ in (200, Data(Fixtures.usageMax20xJSON.utf8)) }
        let response = try await client.usage(accessToken: "access-1")
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(StubURLProtocol.requests[0].url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(StubURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        XCTAssertNoThrow(try UsageData.decode(from: response.body))
    }

    func test_profile_decodes() async throws {
        StubURLProtocol.handler = { _ in (200, Data(Fixtures.profileJSON.utf8)) }
        let profile = try await client.profile(accessToken: "access-1")
        XCTAssertEqual(profile, Profile(email: "test@example.com", displayName: "Test", organizationName: "Test's Organization", organizationType: "claude_max"))
    }

    func test_transportFailure_throwsTransport() async {
        let now = fixedNow
        let failing = OAuthClient(session: FailingURLProtocol.session(), now: { now })
        do {
            _ = try await failing.usage(accessToken: "x")
            XCTFail("expected a throw")
        } catch {
            guard case .transport = error as? ClaudeAPIError else { return XCTFail("\(error)") }
        }
    }
}
