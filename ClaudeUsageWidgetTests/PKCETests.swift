import XCTest
@testable import ClaudeUsageWidget

final class PKCETests: XCTestCase {

    // RFC 7636 appendix B
    func test_challenge_matchesRFC7636Vector() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func test_generate_verifierIsBase64URL43Chars_andChallengeMatches() {
        let pkce = PKCE.generate()
        XCTAssertEqual(pkce.verifier.count, 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertTrue(pkce.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertEqual(pkce.challenge, PKCE.challenge(for: pkce.verifier))
        XCTAssertNotEqual(PKCE.generate().verifier, pkce.verifier)
    }

    func test_randomState_isUniqueAndURLSafe() {
        let a = PKCE.randomState(), b = PKCE.randomState()
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("+") || a.contains("/") || a.contains("="))
    }

    /// Observed 2026-10-12: claude.ai's Authorize step answered "Invalid request format" when the app sent a
    /// 22-character state (16 bytes), while a 32-character state was accepted. 32 bytes gives 43 characters,
    /// the same size as the PKCE verifier.
    func test_randomState_is43Characters() {
        XCTAssertEqual(PKCE.randomState().count, 43)
    }
}
