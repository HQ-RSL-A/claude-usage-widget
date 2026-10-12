import Foundation
@testable import ClaudeUsageWidget

/// Scripted ClaudeAPI: each get() pops the next result. Running out of script throws transport.
@MainActor
final class FakeClaudeAPI: ClaudeAPI {
    var responses: [Result<APIResponse, ClaudeAPIError>] = []
    var lastActiveOrg: String?
    private(set) var paths: [String] = []
    private(set) var resetCount = 0

    func get(_ path: String) async throws -> APIResponse {
        paths.append(path)
        guard !responses.isEmpty else { throw ClaudeAPIError.transport("no scripted response") }
        return try responses.removeFirst().get()
    }

    func lastActiveOrgId() async -> String? { lastActiveOrg }

    func reset() { resetCount += 1 }
}
