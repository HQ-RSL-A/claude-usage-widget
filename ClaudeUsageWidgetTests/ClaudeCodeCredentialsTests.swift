import XCTest
@testable import ClaudeUsageWidget

final class ClaudeCodeCredentialsTests: XCTestCase {

    func test_parse_readsRealShape_millisecondsExpiry() throws {
        let token = try XCTUnwrap(ClaudeCodeToken.parse(Data(Fixtures.claudeCodeCredentialsJSON.utf8)))
        XCTAssertEqual(token.accessToken, "cc-access")
        XCTAssertEqual(token.subscriptionType, "max")
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertTrue(token.isValid)
    }

    func test_parse_expiredToken_isNotValid() throws {
        let token = try XCTUnwrap(ClaudeCodeToken.parse(Data(Fixtures.claudeCodeExpiredJSON.utf8)))
        XCTAssertFalse(token.isValid)
    }

    func test_parse_withoutOauthBlock_isNil() throws {
        XCTAssertNil(try ClaudeCodeToken.parse(Data(#"{"somethingElse":{}}"#.utf8)))
    }

    func test_parse_garbage_throws() {
        XCTAssertThrowsError(try ClaudeCodeToken.parse(Data("not json".utf8)))
    }

    func test_exists_isFalseForMissingItem_andTrueWithoutReadingTheSecret() throws {
        XCTAssertFalse(KeychainClaudeCodeCredentials(service: "io.rsla.ClaudeUsageWidget.tests.absent").exists())
        let service = "io.rsla.ClaudeUsageWidget.tests.exists"
        addTeardownBlock { try? KeychainItem.delete(service: service, account: "x") }
        try KeychainItem.write(Data("{}".utf8), service: service, account: "x")
        XCTAssertTrue(KeychainClaudeCodeCredentials(service: service).exists())
    }

    func test_keychainReader_missingItem_isNil() throws {
        // A service nobody writes to: no prompt, no item.
        XCTAssertNil(try KeychainClaudeCodeCredentials(service: "io.rsla.ClaudeUsageWidget.tests.absent").read())
    }
}
