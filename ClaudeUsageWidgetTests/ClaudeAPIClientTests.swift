import XCTest
import WebKit
@testable import ClaudeUsageWidget

@MainActor
final class ClaudeAPIClientTests: XCTestCase {

    func test_init_doesNotLoadUntilFirstRequest() {
        let client = ClaudeAPIClient(dataStore: .nonPersistent())
        XCTAssertFalse(client.isReady)
    }

    func test_reset_clearsReadyFlag() {
        let client = ClaudeAPIClient(dataStore: .nonPersistent())
        client.markReadyForTesting()
        XCTAssertTrue(client.isReady)
        client.reset()
        XCTAssertFalse(client.isReady)
    }

    func test_bridgeParsing_acceptsStatusAndBody() throws {
        let response = try ClaudeAPIClient.parseBridgeResult(#"{"status":403,"body":"{\"type\":\"error\"}"}"#)
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"type":"error"}"#)
    }

    func test_bridgeParsing_rejectsGarbage() {
        XCTAssertThrowsError(try ClaudeAPIClient.parseBridgeResult(42)) { error in
            guard case ClaudeAPIError.transport = error else { return XCTFail("\(error)") }
        }
    }
}
