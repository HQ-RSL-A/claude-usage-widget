import Foundation

// MARK: - APIResponse

struct APIResponse: Equatable {
    let status: Int
    let body: Data

    var isSuccess: Bool { (200..<300).contains(status) }
}

// MARK: - ClaudeAPIError

enum ClaudeAPIError: Error, Equatable {
    case transport(String)     // webView gone, fetch threw, claude.ai did not load
    case sessionExpired        // 401, or 403 with error_code account_session_invalid
    case forbidden(String)     // any other 403, message from the envelope
    case notFound              // 404
    case server(Int)           // 5xx
    case http(Int)             // any other non-2xx
    case decode(String)        // body did not match the expected shape

    /// nil for 2xx. Pure.
    static func classify(_ response: APIResponse) -> ClaudeAPIError? {
        if response.isSuccess { return nil }
        let envelope = APIErrorEnvelope.parse(response.body)
        switch response.status {
        case 401:
            return .sessionExpired
        case 403:
            if envelope?.errorCode == "account_session_invalid" { return .sessionExpired }
            return .forbidden(envelope?.message ?? "Permission denied")
        case 404:
            return .notFound
        case 500...599:
            return .server(response.status)
        default:
            return .http(response.status)
        }
    }

    var userMessage: String {
        switch self {
        case .transport: return "Offline or claude.ai unreachable"
        case .sessionExpired: return "Session expired"
        case .forbidden: return "Permission denied for this org"
        case .notFound: return "Org no longer exists, sign out and back in"
        case .server(let code): return "claude.ai error \(code)"
        case .http(let code): return "claude.ai returned \(code)"
        case .decode: return "Unexpected response, please report"
        }
    }
}

// MARK: - Error envelope

/// {"type":"error","error":{"type":"...","message":"...","details":{"error_code":"..."}},"request_id":"..."}
struct APIErrorEnvelope: Decodable, Equatable {
    struct Inner: Decodable, Equatable {
        struct Details: Decodable, Equatable {
            let error_code: String?
        }
        let type: String
        let message: String?
        let details: Details?
    }

    let error: Inner

    var errorCode: String? { error.details?.error_code }
    var message: String? { error.message }

    static func parse(_ data: Data) -> APIErrorEnvelope? {
        try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
    }
}

// MARK: - ClaudeAPI

/// The only way the app talks to claude.ai. Implemented by ClaudeAPIClient (WKWebView) and by test fakes.
@MainActor
protocol ClaudeAPI: AnyObject {
    /// Same-origin GET. Throws only ClaudeAPIError.transport; HTTP errors come back as a response for classify().
    func get(_ path: String) async throws -> APIResponse
    /// Value of the lastActiveOrg cookie, if claude.ai has set one.
    func lastActiveOrgId() async -> String?
    /// Forget the loaded page; the next get() reloads claude.ai first. Call after sign-out.
    func reset()
}
