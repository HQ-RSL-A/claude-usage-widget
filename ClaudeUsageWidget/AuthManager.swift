import AppKit
import WebKit

enum AuthState: Equatable {
    case unknown                                     // launch, first check in flight
    case unreachable                                 // claude.ai could not be reached or answered 5xx
    case signedOut                                   // no session (first launch, or after sign-out)
    case signedIn(Organization, chatOrgCount: Int)   // usage can be polled for this org
    case sessionExpired                              // was signed in, session no longer valid
    case noChatOrg                                   // valid session, but no org can chat (console-only account)
}

@MainActor
protocol AuthManagerDelegate: AnyObject {
    func authManager(_ manager: AuthManager, didChange state: AuthState)
}

/// Decides whether the app is signed in, by asking the API. Owns the login window.
@MainActor
final class AuthManager {
    weak var delegate: AuthManagerDelegate?

    private(set) var state: AuthState = .unknown {
        didSet { if oldValue != state { delegate?.authManager(self, didChange: state) } }
    }

    /// Tests set this to false; showLoginWindow() then only counts.
    var presentsLoginWindow = true
    private(set) var loginWindowRequests = 0

    private let client: ClaudeAPI
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
    func verifySession() async -> AuthState {
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
        state = .sessionExpired
        guard !expiryWindowShown else { return }
        expiryWindowShown = true
        showLoginWindow()
    }

    // MARK: - Sign out

    func signOut() {
        dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.client.reset()
                self.expiryWindowShown = false
                self.state = .signedOut
                self.showLoginWindow()
            }
        }
    }

    // MARK: - Login window

    func showLoginWindow() {
        loginWindowRequests += 1
        guard presentsLoginWindow else { return }
        if loginWindow == nil {
            loginWindow = LoginWindowController(authManager: self)
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
