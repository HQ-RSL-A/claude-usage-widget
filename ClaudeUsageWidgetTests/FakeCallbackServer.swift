import Foundation
@testable import ClaudeUsageWidget

@MainActor
final class FakeCallbackServer: CallbackServing {
    var port: UInt16 = 4242
    var codeToDeliver: Result<String, ClaudeAPIError> = .success("CODE")
    /// When true, waitForCode suspends until stop() (to test cancellation).
    var hold = false
    private(set) var expectedState: String?
    private(set) var stopped = false
    private var waiting: CheckedContinuation<String, Error>?

    func start(expectedState: String) async throws -> UInt16 {
        self.expectedState = expectedState
        return port
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        if !hold {
            switch codeToDeliver {
            case .success(let code): return code
            case .failure(let error): throw error
            }
        }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func stop() {
        stopped = true
        waiting?.resume(throwing: ClaudeAPIError.signInCancelled)
        waiting = nil
    }
}
