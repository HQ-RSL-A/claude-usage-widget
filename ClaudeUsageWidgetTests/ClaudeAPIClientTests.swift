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

    func test_webContentProcessTermination_clearsReady_soNextCallReloads() {
        let client = ClaudeAPIClient(dataStore: .nonPersistent())
        client.markReadyForTesting()
        client.webViewWebContentProcessDidTerminate(WKWebView())
        XCTAssertFalse(client.isReady)
    }

    func test_bridgeFailure_clearsReady_andThrowsTransport() async {
        // Marked ready without ever loading claude.ai: fetch('/path') from about:blank rejects, like a dead page would.
        let client = ClaudeAPIClient(dataStore: .nonPersistent())
        client.markReadyForTesting()
        do {
            _ = try await client.get("/api/organizations")
            XCTFail("expected a transport error")
        } catch {
            guard case ClaudeAPIError.transport = error else { return XCTFail("\(error)") }
        }
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
