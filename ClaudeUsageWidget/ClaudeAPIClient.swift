import Foundation
import WebKit

/// Talks to claude.ai through a hidden WKWebView so the session cookie rides along with every fetch.
/// The page is loaded once (claude.ai redirects to /login when signed out, same origin, fetches still work).
@MainActor
final class ClaudeAPIClient: NSObject, ClaudeAPI {

    private let webView: WKWebView
    private let baseURL = URL(string: "https://claude.ai")!
    private let loadTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000

    private(set) var isReady = false
    private var isLoading = false
    private var readyContinuations: [CheckedContinuation<Void, Error>] = []
    private var timeoutTask: Task<Void, Never>?

    init(dataStore: WKWebsiteDataStore = .default()) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - ClaudeAPI

    func get(_ path: String) async throws -> APIResponse {
        try await ensureReady()
        let js = """
        const response = await fetch(path, { credentials: 'include', signal: AbortSignal.timeout(15000) });
        const body = await response.text();
        return JSON.stringify({ status: response.status, body: body });
        """
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(js, arguments: ["path": path], in: nil, contentWorld: .defaultClient)
        } catch {
            throw ClaudeAPIError.transport(error.localizedDescription)
        }
        return try Self.parseBridgeResult(result)
    }

    func lastActiveOrgId() async -> String? {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        return cookies.first { $0.name == "lastActiveOrg" && $0.domain.hasSuffix("claude.ai") }?.value
    }

    func reset() {
        isReady = false
    }

    // MARK: - Bridge result

    /// The JS returns JSON.stringify({status, body}); anything else is a transport failure.
    static func parseBridgeResult(_ result: Any?) throws -> APIResponse {
        guard let string = result as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = object["status"] as? Int,
              let body = object["body"] as? String else {
            throw ClaudeAPIError.transport("Bridge returned an unexpected value")
        }
        return APIResponse(status: status, body: Data(body.utf8))
    }

    // MARK: - Page readiness

    private func ensureReady() async throws {
        if isReady { return }
        if !isLoading {
            isLoading = true
            webView.load(URLRequest(url: baseURL))
            timeoutTask = Task { [weak self, loadTimeoutNanoseconds] in
                try? await Task.sleep(nanoseconds: loadTimeoutNanoseconds)
                guard let self, !Task.isCancelled, !self.isReady else { return }
                self.finishLoading(.failure(ClaudeAPIError.transport("claude.ai did not load")))
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuations.append(continuation)
        }
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        isLoading = false
        timeoutTask?.cancel()
        timeoutTask = nil
        if case .success = result { isReady = true }
        let waiters = readyContinuations
        readyContinuations.removeAll()
        waiters.forEach { $0.resume(with: result) }
    }

    func markReadyForTesting() {
        finishLoading(.success(()))
    }
}

// MARK: - WKNavigationDelegate

extension ClaudeAPIClient: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(ClaudeAPIError.transport(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(ClaudeAPIError.transport(error.localizedDescription)))
    }
}
