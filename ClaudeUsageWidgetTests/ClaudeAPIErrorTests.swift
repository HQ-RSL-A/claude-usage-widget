import XCTest
@testable import ClaudeUsageWidget

final class ClaudeAPIErrorTests: XCTestCase {

    func test_classify_2xx_isNil() {
        XCTAssertNil(ClaudeAPIError.classify(Fixtures.response(200, "[]")))
        XCTAssertNil(ClaudeAPIError.classify(Fixtures.response(204, "")))
    }

    func test_classify_401_isSessionExpired() {
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.unauthorized401), .sessionExpired)
    }

    func test_classify_403AccountSessionInvalid_isSessionExpired() {
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.sessionInvalid403), .sessionExpired)
    }

    func test_classify_403PermissionDenied_isForbidden() {
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.permissionDenied403), .forbidden("Permission denied."))
    }

    func test_classify_403WithoutErrorCode_isForbidden() {
        let drifted = Fixtures.response(403, #"{"type":"error","error":{"type":"permission_error","message":"Invalid authorization"}}"#)
        XCTAssertEqual(ClaudeAPIError.classify(drifted), .forbidden("Invalid authorization"))
    }

    func test_classify_403NonJSON_isForbiddenWithDefaultMessage() {
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.response(403, "<html>blocked</html>")), .forbidden("Permission denied"))
    }

    func test_classify_404_isNotFound() {
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.notFound404), .notFound)
    }

    func test_classify_5xx_isServer() {
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.server500), .server(500))
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.response(503, "")), .server(503))
    }

    func test_classify_other_isHttp() {
        XCTAssertEqual(ClaudeAPIError.classify(Fixtures.response(418, "")), .http(418))
    }

    func test_userMessage_signInErrors() {
        XCTAssertEqual(ClaudeAPIError.callbackTimeout.userMessage, "Sign-in timed out, try again")
        XCTAssertEqual(ClaudeAPIError.signInCancelled.userMessage, "Sign-in cancelled")
        XCTAssertEqual(ClaudeAPIError.stateMismatch.userMessage, "Sign-in response did not match, try again")
        XCTAssertEqual(ClaudeAPIError.keychain(-25293).userMessage, "Could not read the Keychain (code -25293)")
        XCTAssertEqual(ClaudeAPIError.oauth("invalid_grant").userMessage, "Sign-in failed: invalid_grant")
    }

    func test_appInfo_versionMatchesBundle() {
        XCTAssertEqual(AppInfo.version, "0.4.1")
    }

    func test_userMessage_isHumanReadable() {
        XCTAssertEqual(ClaudeAPIError.sessionExpired.userMessage, "Session expired")
        XCTAssertEqual(ClaudeAPIError.server(502).userMessage, "claude.ai error 502")
        XCTAssertEqual(ClaudeAPIError.transport("x").userMessage, "Offline or claude.ai unreachable")
    }
}
