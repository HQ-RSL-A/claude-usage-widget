import Foundation

/// Reads Codex's 5 hour and weekly usage from ChatGPT's usage endpoint, with the sign-in Codex saved on this Mac.
///
/// Codex owns `auth.json` and rewrites it whenever it renews its token. This reader only reads it, fresh on every
/// call: it never refreshes the token, never writes the file, never stores the token and never logs it. When the
/// token has expired the panel says so, and Codex renews it the next time it runs.
@MainActor
final class CodexReader: ServiceReader {
    let service = ServiceID.codex

    /// `$CODEX_HOME/auth.json` when that is set, else `~/.codex/auth.json`: the place Codex itself looks.
    nonisolated static var defaultAuthFile: URL {
        authFileURL(codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"],
                    home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// An empty `CODEX_HOME` counts as not set, the same as in Codex.
    nonisolated static func authFileURL(codexHome: String?, home: URL) -> URL {
        let folder = codexHome.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".codex", isDirectory: true)
        return folder.appendingPathComponent("auth.json")
    }

    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private static let signInHint = "Open Codex and sign in with ChatGPT"
    private static let chatGPTSignInHint = "Sign in to Codex with ChatGPT"
    private static let refreshHint = "Open Codex to refresh its sign-in"
    private static let unreachableReason = "Couldn't reach Codex"
    private static let formatChangedReason = "Codex changed its usage format"

    /// A window this long or shorter is the session. Anything longer is the week.
    private static let sessionWindowSeconds = 6.0 * 3600

    private let authFile: URL
    private let session: URLSession
    private let now: () -> Date

    init(authFile: URL = CodexReader.defaultAuthFile, session: URLSession = .shared, now: @escaping () -> Date = Date.init) {
        self.authFile = authFile
        self.session = session
        self.now = now
    }

    /// True when Codex's sign-in file is on this Mac. A file with only an API key still counts: the panel then says how to sign in.
    func isSetUp() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: authFile.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    func read() async -> ServiceState {
        // Fresh every time: Codex rewrites the file when it renews its token, and the old token stops working.
        // A file that cannot be read or understood counts as no sign-in.
        guard let authData = try? Data(contentsOf: authFile),
              let auth = try? JSONDecoder().decode(RawCodexAuth.self, from: authData) else {
            return .notSignedIn(hint: Self.signInHint)
        }
        // Codex signed in with an API key has no ChatGPT token, and the usage endpoint needs one.
        guard let token = auth.tokens?.access_token, !token.isEmpty else {
            return .notSignedIn(hint: Self.chatGPTSignInHint)
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData   // A cached answer would show old numbers as current.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountId = auth.tokens?.account_id, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue(OAuthConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: Data
        let status: Int
        do {
            let (data, response) = try await session.data(for: request)
            body = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return .unavailable(reason: Self.unreachableReason)
        }

        switch status {
        case 200..<300:
            break
        case 401, 403:
            // The token has expired or been revoked. Renewing it is Codex's job, never this reader's.
            return .notSignedIn(hint: Self.refreshHint)
        default:
            return .unavailable(reason: Self.unreachableReason)
        }

        guard let usage = try? JSONDecoder().decode(RawCodexUsage.self, from: body) else {
            return .unavailable(reason: Self.formatChangedReason)
        }
        let readAt = now()
        let limits = [usage.rate_limit?.primary_window, usage.rate_limit?.secondary_window]
            .compactMap { Self.limit(from: $0, readAt: readAt) }
        guard !limits.isEmpty else { return .unavailable(reason: Self.formatChangedReason) }
        return .reading(limits: limits, readAt: readAt)
    }

    /// One window as a limit, or nil when it lacks the number or the length that the label depends on.
    private static func limit(from window: RawCodexUsage.Window?, readAt: Date) -> ServiceLimit? {
        guard let window, let used = window.used_percent, let length = window.limit_window_seconds else { return nil }
        // ChatGPT counts percent from 0 to 100 and time in seconds. The absolute reset time wins over the one counted from now.
        let resetsAt = window.reset_at.map { Date(timeIntervalSince1970: $0) }
            ?? window.reset_after_seconds.map { readAt.addingTimeInterval($0) }
        return ServiceLimit(label: length <= sessionWindowSeconds ? "5hr Session" : "Weekly",
                            percentUsed: used / 100,
                            resetsAt: resetsAt)
    }
}

// MARK: - What Codex saves and what ChatGPT answers

// Every field is optional, so a key that is missing never throws, and keys that are not listed are ignored.
// A value of the wrong type still throws, and the reader treats that like a changed format.
// `OPENAI_API_KEY` is not listed on purpose: nothing here needs it, so it is never decoded.

private struct RawCodexAuth: Decodable {
    struct Tokens: Decodable {
        let access_token: String?
        let account_id: String?
    }
    let tokens: Tokens?
}

private struct RawCodexUsage: Decodable {
    struct Window: Decodable {
        let used_percent: Double?
        let limit_window_seconds: Double?
        let reset_at: Double?
        let reset_after_seconds: Double?
    }
    struct RateLimit: Decodable {
        let primary_window: Window?
        let secondary_window: Window?
    }
    let rate_limit: RateLimit?
}
