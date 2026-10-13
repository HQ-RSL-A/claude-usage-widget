import Foundation

// MARK: - Configuration

/// Anthropic's consumer OAuth, as used by Claude Code (client id read from Claude Code 2.1.296; no third-party registration exists).
enum OAuthConfig {
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let scopes = "user:profile user:inference"
    static let betaHeader = "oauth-2025-04-20"
    static var userAgent: String { "ClaudeUsageWidget/\(AppInfo.version) (macOS)" }
}

// MARK: - TokenSet

struct TokenSet: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String?

    var secondsUntilExpiry: TimeInterval { expiresAt.timeIntervalSinceNow }

    private struct Raw: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
        let scope: String?
    }

    static func decode(from data: Data, now: Date) throws -> TokenSet {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return TokenSet(accessToken: raw.access_token, refreshToken: raw.refresh_token, expiresAt: now.addingTimeInterval(raw.expires_in), scope: raw.scope)
    }

    /// `{"error":"invalid_grant","error_description":"..."}` or the API envelope; falls back to a generic message.
    static func refusalMessage(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "token request refused" }
        if let description = object["error_description"] as? String { return description }
        if let error = object["error"] as? String { return error }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String { return message }
        return "token request refused"
    }
}

// MARK: - Profile

struct Profile: Codable, Equatable {
    let email: String?
    let displayName: String?
    let organizationName: String?
    let organizationType: String?

    private struct Raw: Decodable {
        struct Account: Decodable { let email: String?; let display_name: String? }
        struct Organization: Decodable { let name: String?; let organization_type: String? }
        let account: Account?
        let organization: Organization?
    }

    static func decode(from data: Data) throws -> Profile {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        return Profile(email: raw.account?.email, displayName: raw.account?.display_name, organizationName: raw.organization?.name, organizationType: raw.organization?.organization_type)
    }
}

// MARK: - OAuthClient

/// Thin HTTP layer for the OAuth endpoints. Every request carries the beta header and an honest User-Agent
/// (Cloudflare in front of the token endpoint rejects anonymous-looking clients).
@MainActor
final class OAuthClient {
    private let session: URLSession
    private let now: () -> Date

    init(session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    func authorizeURL(redirectURI: String, challenge: String, state: String) -> URL {
        var components = URLComponents(url: OAuthConfig.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthConfig.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: OAuthConfig.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    func exchange(code: String, verifier: String, redirectURI: String, state: String) async throws -> TokenSet {
        try await token(body: [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": OAuthConfig.clientId,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
        ])
    }

    func refresh(_ refreshToken: String) async throws -> TokenSet {
        try await token(body: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": OAuthConfig.clientId,
        ])
    }

    func usage(accessToken: String) async throws -> APIResponse {
        try await get(OAuthConfig.usageURL, accessToken: accessToken)
    }

    func profile(accessToken: String) async throws -> Profile {
        let response = try await get(OAuthConfig.profileURL, accessToken: accessToken)
        if let error = ClaudeAPIError.classify(response) { throw error }
        do {
            return try Profile.decode(from: response.body)
        } catch {
            throw ClaudeAPIError.decode(error.localizedDescription)
        }
    }

    // MARK: - HTTP

    private func token(body: [String: String]) async throws -> TokenSet {
        var request = URLRequest(url: OAuthConfig.tokenURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let response = try await send(request)
        guard response.isSuccess else {
            if response.status == 400 || response.status == 401 {
                throw ClaudeAPIError.oauth(TokenSet.refusalMessage(in: response.body))
            }
            throw ClaudeAPIError.classify(response) ?? .http(response.status)
        }
        do {
            return try TokenSet.decode(from: response.body, now: now())
        } catch {
            throw ClaudeAPIError.decode(error.localizedDescription)
        }
    }

    private func get(_ url: URL, accessToken: String) async throws -> APIResponse {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> APIResponse {
        var request = request
        request.setValue(OAuthConfig.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(OAuthConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        do {
            let (data, response) = try await session.data(for: request)
            return APIResponse(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        } catch {
            throw ClaudeAPIError.transport(error.localizedDescription)
        }
    }
}
