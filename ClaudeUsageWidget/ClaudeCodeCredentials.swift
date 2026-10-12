import Foundation

/// The access token Claude Code keeps in the Keychain. Read only; the widget never refreshes it.
struct ClaudeCodeToken: Equatable {
    let accessToken: String
    let expiresAt: Date
    let subscriptionType: String?

    /// Usable for at least another minute.
    var isValid: Bool { expiresAt.timeIntervalSinceNow > 60 }

    private struct Raw: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double        // milliseconds since the epoch (JavaScript Date.now())
            let subscriptionType: String?
        }
        let claudeAiOauth: OAuth?
    }

    static func parse(_ data: Data) throws -> ClaudeCodeToken? {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        guard let oauth = raw.claudeAiOauth else { return nil }
        return ClaudeCodeToken(accessToken: oauth.accessToken, expiresAt: Date(timeIntervalSince1970: oauth.expiresAt / 1000), subscriptionType: oauth.subscriptionType)
    }
}

protocol ClaudeCodeCredentialsReading: AnyObject {
    /// nil when Claude Code never signed in on this Mac. Throws .keychain when macOS refused (the user clicked Deny).
    func read() throws -> ClaudeCodeToken?
}

final class KeychainClaudeCodeCredentials: ClaudeCodeCredentialsReading {
    static let defaultService = "Claude Code-credentials"
    private let service: String

    init(service: String = KeychainClaudeCodeCredentials.defaultService) {
        self.service = service
    }

    func read() throws -> ClaudeCodeToken? {
        guard let data = try KeychainItem.read(service: service, account: nil) else { return nil }
        do {
            return try ClaudeCodeToken.parse(data)
        } catch {
            return nil   // Claude Code changed its format: treat as absent, never crash
        }
    }
}
