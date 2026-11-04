import Foundation
import Security

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
    /// Whether Claude Code's item is in the Keychain at all. Never prompts.
    func exists() -> Bool
    /// nil when Claude Code never signed in on this Mac. Throws .keychain when macOS refused.
    func read() async throws -> ClaudeCodeToken?
}

/// Reads Claude Code's item through /usr/bin/security, the tool Claude Code itself writes it with.
/// The item trusts that tool, so macOS never asks for the Mac password. Reading it directly (SecItem)
/// asked at every launch: each time Claude Code refreshes its sign-in it rewrites the item, which resets
/// "Always Allow" for every other app, and each update of this ad-hoc signed app looks like a new app.
final class SecurityToolClaudeCodeCredentials: ClaudeCodeCredentialsReading {
    static let defaultService = "Claude Code-credentials"
    static let securityTool = URL(fileURLWithPath: "/usr/bin/security")
    /// errSecItemNotFound (-25300) as the tool's exit status.
    static let itemNotFoundExitStatus: Int32 = 44
    /// The tool only hangs if macOS shows it a password dialog after all.
    static let timeout: TimeInterval = 10

    private let service: String
    private let runner: ProcessRunning

    init(service: String = SecurityToolClaudeCodeCredentials.defaultService, runner: ProcessRunning = ProcessRunner()) {
        self.service = service
        self.runner = runner
    }

    func exists() -> Bool {
        KeychainItem.exists(service: service)
    }

    func read() async throws -> ClaudeCodeToken? {
        let result = await runner.run(executable: Self.securityTool, arguments: ["find-generic-password", "-s", service, "-w"], timeout: Self.timeout)
        switch result.ending {
        case .exited(0):
            do {
                return try ClaudeCodeToken.parse(Self.trimmingTrailingNewlines(result.output))
            } catch {
                return nil   // Claude Code changed its format: treat as absent, never crash
            }
        case .exited(Self.itemNotFoundExitStatus):
            return nil
        case .exited(let status):
            throw ClaudeAPIError.keychain(status)
        case .timedOut:
            throw ClaudeAPIError.keychain(errSecInteractionNotAllowed)
        case .failedToLaunch:
            throw ClaudeAPIError.keychain(errSecNotAvailable)
        }
    }

    /// The tool ends the secret with a newline.
    private static func trimmingTrailingNewlines(_ data: Data) -> Data {
        var bytes = data
        while let last = bytes.last, last == UInt8(ascii: "\n") || last == UInt8(ascii: "\r") {
            bytes.removeLast()
        }
        return bytes
    }
}
