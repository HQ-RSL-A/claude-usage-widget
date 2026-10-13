import XCTest
@testable import ClaudeUsageWidget

final class TokenStoreTests: XCTestCase {

    private let sample = TokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), scope: "user:profile user:inference")

    func test_inMemory_roundTrip() throws {
        let store = InMemoryTokenStore()
        XCTAssertNil(try store.load())
        try store.save(sample)
        XCTAssertEqual(try store.load(), sample)
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func test_keychain_roundTrip_underTestService() throws {
        let store = KeychainTokenStore(service: "io.rsla.ClaudeUsageWidget.tests", account: "oauth")
        addTeardownBlock { try? store.clear() }
        try store.clear()
        XCTAssertNil(try store.load())
        try store.save(sample)
        XCTAssertEqual(try store.load(), sample)
        let updated = TokenSet(accessToken: "a2", refreshToken: "r2", expiresAt: sample.expiresAt, scope: nil)
        try store.save(updated)
        XCTAssertEqual(try store.load(), updated)
        try store.clear()
        XCTAssertNil(try store.load())
        try store.clear()   // deleting twice is fine
    }
}
