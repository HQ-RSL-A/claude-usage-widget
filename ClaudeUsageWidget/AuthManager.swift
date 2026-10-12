import AppKit
import Foundation

enum AuthState: Equatable {
    case unknown
    case unreachable
    case signedOut(claudeCodeAvailable: Bool)     // which sign-in buttons to show
    case signingIn                                 // browser flow waiting for the redirect
    case signedIn(IdentitySource, Profile?)
    case sessionExpired(IdentitySource)
    case noChatOrg                                 // web session only
}

@MainActor
protocol AuthManagerDelegate: AnyObject {
    func authManager(_ manager: AuthManager, didChange state: AuthState)
}

/// Picks the identity the widget runs on (own OAuth token, Claude Code's token, or the v0.3.0 web session),
/// runs the sign-in flows, and owns the usage source for the current identity.
@MainActor
final class AuthManager {

    struct Dependencies {
        var oauth: OAuthClient
        var tokenStore: TokenStoring
        var claudeCode: ClaudeCodeCredentialsReading
        var webSession: WebSessionAuth
        var defaults: UserDefaults
        var makeCallbackServer: @MainActor () -> CallbackServing
        var openURL: (URL) -> Void
        var hasWebSessionCookies: () async -> Bool
    }

    static let optOutKey = "claudeCodeTokenOptOut"
    static let deniedKey = "claudeCodeTokenDenied"
    static let webSessionKey = "webSessionEnabled"
    static let claudeCodeExpiredMessage = "Claude Code's sign-in has expired. Open Claude Code once, or sign in with your browser"

    weak var delegate: AuthManagerDelegate?

    private(set) var state: AuthState = .unknown {
        didSet {
            guard oldValue != state else { return }
            delegate?.authManager(self, didChange: state)
            if state == .unreachable { scheduleRetry() } else { cancelRetry() }
            if waitsForClaudeCode { scheduleClaudeCodeRecheck() } else { cancelClaudeCodeRecheck() }
        }
    }

    /// The source to poll while `.signedIn`; nil otherwise.
    private(set) var usageSource: UsageSource?
    /// Why the last sign-in attempt ended, for the popover. Cleared on the next attempt.
    private(set) var signInMessage: String?

    var unreachableRetryInterval: TimeInterval = 60
    /// While Claude Code's token is expired, look again on this interval (Claude Code refreshes it when it runs).
    var claudeCodeRecheckInterval: TimeInterval = 300
    var browserTimeout: TimeInterval = 300
    var isRetryScheduled: Bool { retryTimer != nil }

    private let deps: Dependencies
    private var claudeCodeItemExists = false
    /// True while the web session is the identity in use; web-session events are ignored otherwise.
    private var webSessionActive = false
    private var browserFlow: CallbackServing?
    private var retryTimer: Timer?
    private var recheckTimer: Timer?

    init(dependencies: Dependencies) {
        deps = dependencies
        deps.webSession.delegate = self
        deps.webSession.retriesWhenUnreachable = false   // this coordinator owns retries
    }

    // MARK: - Resolution

    func checkAuthStatus() async {
        claudeCodeItemExists = deps.claudeCode.exists()   // attribute query, never prompts
        webSessionActive = false
        signInMessage = nil
        if await resolveOwnToken() { return }
        if await resolveClaudeCode() { return }
        if await resolveWebSession() { return }
        usageSource = nil
        state = .signedOut(claudeCodeAvailable: claudeCodeItemExists)
    }

    /// True when the own token produced a terminal state (signed in, or unreachable while refreshing it).
    private func resolveOwnToken() async -> Bool {
        let provider = OwnTokenProvider(store: deps.tokenStore, client: deps.oauth)
        do {
            let token = try await provider.accessToken()
            let profile = try? await deps.oauth.profile(accessToken: token)
            usageSource = OAuthUsageSource(client: deps.oauth, tokens: provider, identity: .ownToken)
            state = .signedIn(.ownToken, profile)
            return true
        } catch ClaudeAPIError.sessionExpired {
            return false            // no own token, or the refresh was refused (store already cleared)
        } catch let error as ClaudeAPIError {
            switch error {
            case .transport, .server, .forbidden, .http:
                usageSource = nil   // the token is fine, the network or Anthropic is not: keep it and retry
                state = .unreachable
                return true
            default:
                return false        // unreadable store or undecodable token: fall through to the next source
            }
        } catch {
            return false
        }
    }

    private func resolveClaudeCode() async -> Bool {
        guard !deps.defaults.bool(forKey: Self.optOutKey), !deps.defaults.bool(forKey: Self.deniedKey) else { return false }
        do {
            guard let token = try deps.claudeCode.read() else {
                claudeCodeItemExists = false
                return false
            }
            claudeCodeItemExists = true
            guard token.isValid else {
                signInMessage = Self.claudeCodeExpiredMessage
                return false
            }
            let profile = try? await deps.oauth.profile(accessToken: token.accessToken)
            usageSource = OAuthUsageSource(client: deps.oauth, tokens: ClaudeCodeTokenProvider(reader: deps.claudeCode, initial: token), identity: .claudeCode)
            state = .signedIn(.claudeCode, profile)
            return true
        } catch {
            // The item exists and macOS refused us (Deny). Remember it so the prompt does not return every poll.
            claudeCodeItemExists = true
            deps.defaults.set(true, forKey: Self.deniedKey)
            return false
        }
    }

    private func resolveWebSession() async -> Bool {
        if !deps.defaults.bool(forKey: Self.webSessionKey), await deps.hasWebSessionCookies() {
            deps.defaults.set(true, forKey: Self.webSessionKey)   // upgrading from v0.3.0 keeps the user signed in
        }
        guard deps.defaults.bool(forKey: Self.webSessionKey) else { return false }
        return apply(webState: await deps.webSession.verifySession())
    }

    /// Maps the web-session machine onto ours. False only when it is simply signed out.
    @discardableResult
    private func apply(webState: WebSessionState) -> Bool {
        switch webState {
        case .signedIn(let org, let chatOrgCount):
            webSessionActive = true
            usageSource = WebSessionUsageSource(client: deps.webSession.client, orgId: org.uuid)
            let profile = chatOrgCount > 1 ? Profile(email: nil, displayName: nil, organizationName: org.displayName, organizationType: nil) : nil
            state = .signedIn(.webSession, profile)
            return true
        case .noChatOrg:
            webSessionActive = true
            usageSource = nil
            state = .noChatOrg
            return true
        case .sessionExpired:
            webSessionActive = true
            usageSource = nil
            state = .sessionExpired(.webSession)
            return true
        case .unreachable:
            webSessionActive = true
            usageSource = nil
            state = .unreachable
            return true
        case .signedOut, .unknown:
            webSessionActive = false
            return false
        }
    }

    // MARK: - Browser sign-in

    func signInWithBrowser() async {
        cancelBrowserSignIn()
        signInMessage = nil
        let pkce = PKCE.generate()
        let stateToken = PKCE.randomState()
        let server = deps.makeCallbackServer()
        browserFlow = server
        state = .signingIn
        do {
            let port = try await server.start(expectedState: stateToken)
            let redirectURI = "http://localhost:\(port)/callback"
            deps.openURL(deps.oauth.authorizeURL(redirectURI: redirectURI, challenge: pkce.challenge, state: stateToken))
            let code = try await server.waitForCode(timeout: browserTimeout)
            server.stop()
            browserFlow = nil
            let tokens = try await deps.oauth.exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI, state: stateToken)
            try deps.tokenStore.save(tokens)
            await checkAuthStatus()
        } catch {
            server.stop()
            browserFlow = nil
            signInMessage = ((error as? ClaudeAPIError) ?? .transport(error.localizedDescription)).userMessage
            usageSource = nil
            state = .signedOut(claudeCodeAvailable: claudeCodeItemExists)
        }
    }

    func cancelBrowserSignIn() {
        browserFlow?.stop()
        browserFlow = nil
    }

    // MARK: - Claude Code

    func useClaudeCodeToken() async {
        deps.defaults.set(false, forKey: Self.optOutKey)
        deps.defaults.set(false, forKey: Self.deniedKey)
        await checkAuthStatus()
    }

    // MARK: - Embedded login (fallback)

    func signInInsideApp() {
        deps.defaults.set(true, forKey: Self.webSessionKey)
        deps.webSession.showLoginWindow()
    }

    // MARK: - Expiry

    /// From UsageService: the current identity no longer works.
    func sessionDidExpire() {
        guard case .signedIn(let source, _) = state else { return }
        usageSource = nil
        switch source {
        case .ownToken:
            try? deps.tokenStore.clear()
            state = .sessionExpired(.ownToken)
        case .claudeCode:
            state = .sessionExpired(.claudeCode)
        case .webSession:
            deps.webSession.sessionDidExpire()   // opens the embedded login once; its delegate maps the state
        }
    }

    // MARK: - Sign out

    func signOut() {
        cancelBrowserSignIn()
        try? deps.tokenStore.clear()
        deps.defaults.set(true, forKey: Self.optOutKey)
        deps.defaults.set(false, forKey: Self.webSessionKey)
        deps.webSession.signOut(showLoginWindow: false)   // always: v0.3.0 cookies may exist even if never used here
        webSessionActive = false
        usageSource = nil
        signInMessage = nil
        state = .signedOut(claudeCodeAvailable: claudeCodeItemExists)
    }

    // MARK: - Unreachable retry

    private func scheduleRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: unreachableRetryInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.retryTimer = nil
                await self.checkAuthStatus()
                if self.state == .unreachable { self.scheduleRetry() }
            }
        }
    }

    private func cancelRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    // MARK: - Claude Code recheck

    /// Signed out or expired with a Claude Code item present and not opted out: Claude Code may refresh it any time.
    private var waitsForClaudeCode: Bool {
        guard claudeCodeItemExists, !deps.defaults.bool(forKey: Self.optOutKey), !deps.defaults.bool(forKey: Self.deniedKey) else { return false }
        switch state {
        case .signedOut, .sessionExpired(.claudeCode): return true
        default: return false
        }
    }

    private func scheduleClaudeCodeRecheck() {
        recheckTimer?.invalidate()
        recheckTimer = Timer.scheduledTimer(withTimeInterval: claudeCodeRecheckInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.recheckTimer = nil
                await self.checkAuthStatus()
                if self.waitsForClaudeCode { self.scheduleClaudeCodeRecheck() }   // no transition, so didSet did not run
            }
        }
    }

    private func cancelClaudeCodeRecheck() {
        recheckTimer?.invalidate()
        recheckTimer = nil
    }
}

// MARK: - WebSessionAuthDelegate

extension AuthManager: WebSessionAuthDelegate {
    func webSessionAuth(_ auth: WebSessionAuth, didChange webState: WebSessionState) {
        guard webSessionActive, deps.defaults.bool(forKey: Self.webSessionKey) else { return }
        if !apply(webState: webState) {
            usageSource = nil
            state = .signedOut(claudeCodeAvailable: claudeCodeItemExists)
        }
    }
}
