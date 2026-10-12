import Foundation
@testable import ClaudeUsageWidget

final class InMemoryTokenStore: TokenStoring {
    var tokens: TokenSet?
    var failure: ClaudeAPIError?
    private(set) var saves = 0
    private(set) var clears = 0

    init(tokens: TokenSet? = nil) { self.tokens = tokens }

    func load() throws -> TokenSet? { if let failure { throw failure }; return tokens }
    func save(_ tokens: TokenSet) throws { if let failure { throw failure }; self.tokens = tokens; saves += 1 }
    func clear() throws { if let failure { throw failure }; tokens = nil; clears += 1 }
}

final class FakeClaudeCodeCredentials: ClaudeCodeCredentialsReading {
    var token: ClaudeCodeToken?
    var failure: ClaudeAPIError?
    private(set) var reads = 0

    init(token: ClaudeCodeToken? = nil, failure: ClaudeAPIError? = nil) { self.token = token; self.failure = failure }

    func read() throws -> ClaudeCodeToken? { reads += 1; if let failure { throw failure }; return token }
}
