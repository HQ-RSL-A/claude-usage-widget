import AppKit
import WebKit

enum WebSessionState: Equatable {
    case unknown                                     // launch, first check in flight
    case unreachable                                 // claude.ai could not be reached or answered 5xx
    case signedOut                                   // no session (first launch, or after sign-out)
    case signedIn(Organization, chatOrgCount: Int)   // usage can be polled for this org
    case sessionExpired                              // was signed in, session no longer valid
    case noChatOrg                                   // valid session, but no org can chat (console-only account)
}

@MainActor
protocol WebSessionAuthDelegate: AnyObject {
    func webSessionAuth(_ auth: WebSessionAuth, didChange state: WebSessionState)
}

/// The v0.3.0 web-session state machine: signed in means a 2xx from /api/organizations through the hidden WKWebView. Owns the embedded login window.
@MainActor
final class WebSessionAuth {
    weak var delegate: WebSessionAuthDelegate?

    private(set) var state: WebSessionState = .unknown {
        didSet {
            guard oldValue != state else { return }
            delegate?.webSessionAuth(self, didChange: state)
            if state == .unreachable && retriesWhenUnreachable { scheduleRetry() } else { cancelRetry() }
        }
    }

    /// While unreachable, claude.ai is asked again on this interval (tests shorten it).
    var unreachableRetryInterval: TimeInterval = 60
    /// False when an owner (AuthManager) drives the retries itself.
    var retriesWhenUnreachable = true
    private var retryTimer: Timer?
    var isRetryScheduled: Bool { retryTimer != nil }

    /// Tests set this to false; showLoginWindow() then only counts.
    var presentsLoginWindow = true
    private(set) var loginWindowRequests = 0

    let client: ClaudeAPI
    private let dataStore: WKWebsiteDataStore
    private var loginWindow: LoginWindowController?
    private var expiryWindowShown = false

    init(client: ClaudeAPI, dataStore: WKWebsiteDataStore? = nil) {
        self.client = client
        self.dataStore = dataStore ?? .default()
    }

    // MARK: - Launch

    /// Launch path: find out who we are; with no session, open the login window.
    func checkAuthStatus() async {
        await verifySession()
        if state == .signedOut {
            showLoginWindow()
        }
    }

    /// GET /api/organizations and derive the state from the answer.
    @discardableResult
    func verifySession() async -> WebSessionState {
        do {
            let response = try await client.get("/api/organizations")
            if let error = ClaudeAPIError.classify(response) {
                apply(error)
                return state
            }
            let orgs = try Organization.decodeList(from: response.body)
            let activeId = await client.lastActiveOrgId()
            if let org = Organization.pickChatOrg(from: orgs, lastActiveOrgId: activeId) {
                expiryWindowShown = false
                state = .signedIn(org, chatOrgCount: orgs.filter(\.isChatOrg).count)
            } else {
                state = .noChatOrg
            }
        } catch let error as ClaudeAPIError {
            apply(error)
        } catch {
            apply(.decode(error.localizedDescription))
        }
        return state
    }

    private func apply(_ error: ClaudeAPIError) {
        switch error {
        case .sessionExpired:
            switch state {
            case .signedIn, .noChatOrg: state = .sessionExpired
            case .sessionExpired: break
            default: state = .signedOut
            }
        default:
            // Keep a signed-in (or signed-out) state through transient trouble; only the launch states move.
            if state == .unknown || state == .unreachable {
                state = .unreachable
            }
        }
    }

    // MARK: - Expiry

    /// Called by UsageService when a poll comes back session-invalid. Opens the login window once per expiry.
    func sessionDidExpire() {
        switch state {
        case .signedIn, .noChatOrg: break
        default: return   // a stale poll finishing after sign-out or expiry has nothing to add
        }
        state = .sessionExpired
        guard !expiryWindowShown else { return }
        expiryWindowShown = true
        showLoginWindow()
    }

    // MARK: - Sign out

    func signOut(showLoginWindow: Bool = true) {
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.client.reset()
                self.expiryWindowShown = false
                self.state = .signedOut
                if showLoginWindow { self.showLoginWindow() }
            }
        }
    }

    // MARK: - Unreachable retry

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: unreachableRetryInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.retryTimer = nil
                await self.checkAuthStatus()
                if self.state == .unreachable && self.retriesWhenUnreachable { self.scheduleRetry() }   // no transition, so didSet did not run
            }
        }
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Login window

    func showLoginWindow() {
        loginWindowRequests += 1
        guard presentsLoginWindow else { return }
        if loginWindow == nil {
            loginWindow = LoginWindowController(authManager: self, dataStore: dataStore)
        }
        loginWindow?.showWindow(nil)
        loginWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The login window saw a URL that may mean success, or its fallback timer fired. True once the API agrees.
    func loginWindowSawCandidate() async -> Bool {
        switch await verifySession() {
        case .signedIn, .noChatOrg: return true
        default: return false
        }
    }

    func loginWindowDidClose() {
        loginWindow = nil
    }
}
