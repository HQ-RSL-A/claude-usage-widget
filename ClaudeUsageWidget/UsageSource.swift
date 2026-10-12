import Foundation

enum IdentitySource: Equatable {
    case ownToken      // the widget's own OAuth token (browser sign-in)
    case claudeCode    // Claude Code's token, read from its Keychain item
    case webSession    // v0.3.0 claude.ai cookies in the hidden WKWebView
}

/// Something that can fetch the raw usage response for the current identity.
@MainActor
protocol UsageSource: AnyObject {
    var identity: IdentitySource { get }
    func fetchUsage() async throws -> APIResponse
}

/// Hands out a bearer token, refreshing when it can. Throws .sessionExpired when there is nothing usable.
@MainActor
protocol BearerTokenProvider: AnyObject {
    func accessToken() async throws -> String
    /// After the API answered 401: a fresh token, or .sessionExpired.
    func refreshAfterUnauthorized() async throws -> String
}

// MARK: - Own token

@MainActor
final class OwnTokenProvider: BearerTokenProvider {
    private let store: TokenStoring
    private let client: OAuthClient
    private let refreshLeeway: TimeInterval = 300
    private var refreshTask: Task<TokenSet, Error>?

    init(store: TokenStoring, client: OAuthClient) {
        self.store = store
        self.client = client
    }

    func accessToken() async throws -> String {
        guard let tokens = try store.load() else { throw ClaudeAPIError.sessionExpired }
        if tokens.secondsUntilExpiry > refreshLeeway { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    func refreshAfterUnauthorized() async throws -> String {
        guard let tokens = try store.load() else { throw ClaudeAPIError.sessionExpired }
        return try await refresh(tokens).accessToken
    }

    /// One refresh in flight at a time; concurrent callers share it. A refused refresh clears the store.
    private func refresh(_ tokens: TokenSet) async throws -> TokenSet {
        if let task = refreshTask { return try await task.value }
        let task = Task<TokenSet, Error> { [client, store] in
            do {
                let fresh = try await client.refresh(tokens.refreshToken)
                try store.save(fresh)
                return fresh
            } catch ClaudeAPIError.oauth {
                try? store.clear()
                throw ClaudeAPIError.sessionExpired
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}

// MARK: - Claude Code's token

@MainActor
final class ClaudeCodeTokenProvider: BearerTokenProvider {
    private let reader: ClaudeCodeCredentialsReading
    private let refreshLeeway: TimeInterval = 300
    private var cached: ClaudeCodeToken?

    /// `initial` is the token the caller already read, so the Keychain is not touched again on the first poll.
    init(reader: ClaudeCodeCredentialsReading, initial: ClaudeCodeToken? = nil) {
        self.reader = reader
        self.cached = initial
    }

    /// Each Keychain read can prompt (unless the user chose Always Allow), so the token is cached until it nears expiry.
    func accessToken() async throws -> String {
        if let cached, cached.expiresAt.timeIntervalSinceNow > refreshLeeway { return cached.accessToken }
        return try reload()
    }

    /// Claude Code may have refreshed since the last read; read again, never refresh it ourselves.
    func refreshAfterUnauthorized() async throws -> String {
        try reload()
    }

    private func reload() throws -> String {
        guard let token = try reader.read(), token.isValid else {
            cached = nil
            throw ClaudeAPIError.sessionExpired
        }
        cached = token
        return token.accessToken
    }
}

// MARK: - Sources

@MainActor
final class OAuthUsageSource: UsageSource {
    let identity: IdentitySource
    private let client: OAuthClient
    private let tokens: BearerTokenProvider

    init(client: OAuthClient, tokens: BearerTokenProvider, identity: IdentitySource) {
        self.client = client
        self.tokens = tokens
        self.identity = identity
    }

    func fetchUsage() async throws -> APIResponse {
        let token = try await tokens.accessToken()
        let response = try await client.usage(accessToken: token)
        guard response.status == 401 else { return response }
        let fresh = try await tokens.refreshAfterUnauthorized()
        return try await client.usage(accessToken: fresh)
    }
}

@MainActor
final class WebSessionUsageSource: UsageSource {
    let identity: IdentitySource = .webSession
    private let client: ClaudeAPI
    private let orgId: String

    init(client: ClaudeAPI, orgId: String) {
        self.client = client
        self.orgId = orgId
    }

    func fetchUsage() async throws -> APIResponse {
        try await client.get("/api/organizations/\(orgId)/usage")
    }
}
