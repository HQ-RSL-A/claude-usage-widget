import CryptoKit
import Foundation
import Security

/// RFC 7636 code verifier and S256 challenge, plus the random `state` for the authorize request.
struct PKCE: Equatable {
    let verifier: String
    let challenge: String

    static func generate() -> PKCE {
        let verifier = randomBytes(32).base64URLEncoded()
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    /// 32 bytes (43 characters). A 16-byte state loads the consent page but is refused at Authorize
    /// with "Invalid request format".
    static func randomState() -> String {
        randomBytes(32).base64URLEncoded()
    }

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return Data(bytes)
    }
}

extension Data {
    /// Base64 without padding, with the URL-safe alphabet (RFC 4648 section 5).
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
