import AppKit
import WebKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var menuViewController: MenuViewController!
    private var client: ClaudeAPIClient!
    private var authManager: AuthManager!
    private var usageService: UsageService?
    private var outsideClick: OutsideClickDismisser!
    private var ringMetricMode: RingMetricMode = .saved

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()                 // before any WebKit object exists (Sonoma NSStatusBar issue)
        setupPopover()
        client = ClaudeAPIClient()
        authManager = AuthManager(dependencies: .init(
            oauth: OAuthClient(),
            tokenStore: KeychainTokenStore(),
            claudeCode: KeychainClaudeCodeCredentials(),
            webSession: WebSessionAuth(client: client),
            defaults: .standard,
            makeCallbackServer: { CallbackServer() },
            openURL: { NSWorkspace.shared.open($0) },
            hasWebSessionCookies: {
                let records = await WKWebsiteDataStore.default().dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
                return records.contains { $0.displayName.contains("claude.ai") }
            }
        ))
        authManager.delegate = self
        Task { await authManager.checkAuthStatus() }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = RingView.image(progress: 0.0, colorState: .normal)
        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
    }

    private func setupPopover() {
        menuViewController = MenuViewController()
        menuViewController.onRefresh = { [weak self] in
            guard let self else { return }
            switch self.authManager.state {
            case .signedIn: self.usageService?.fetch()
            case .signingIn: break
            default: Task { await self.authManager.checkAuthStatus() }
            }
        }
        menuViewController.onSignOut = { [weak self] in self?.signOut() }
        menuViewController.onSignInBrowser = { [weak self] in Task { await self?.authManager.signInWithBrowser() } }
        menuViewController.onUseClaudeCode = { [weak self] in Task { await self?.authManager.useClaudeCodeToken() } }
        menuViewController.onSignInInsideApp = { [weak self] in self?.authManager.signInInsideApp() }
        menuViewController.onCancelSignIn = { [weak self] in self?.authManager.cancelBrowserSignIn() }
        popover = NSPopover()
        popover.contentViewController = menuViewController
        popover.behavior = .transient
        popover.delegate = self
        outsideClick = OutsideClickDismisser(
            isShown: { [weak self] in self?.popover.isShown ?? false },
            close: { [weak self] in self?.popover.performClose(nil) }
        )
    }

    // MARK: - Status Icon

    private func updateStatusIcon(progress: Double, colorState: RingColorState) {
        let image = RingView.image(progress: progress, colorState: colorState)
        statusItem.button?.image = image
        statusItem.button?.imageScaling = .scaleProportionallyDown
    }

    // MARK: - Popover Toggle

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    // MARK: - Usage Service

    private func startUsageService(source: UsageSource, identity: IdentitySource) {
        if let service = usageService, service.identity == identity { return }
        stopUsageService()
        let service = UsageService(source: source)
        service.delegate = self
        usageService = service
        menuViewController.showLoading()
        service.start()
    }

    private func stopUsageService() {
        usageService?.stop()
        usageService = nil
        updateStatusIcon(progress: 0.0, colorState: .normal)
    }

    // MARK: - Sign Out

    private func signOut() {
        stopUsageService()
        authManager.signOut()
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        outsideClick.popoverDidShow()
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClick.popoverDidClose()
    }
}

// MARK: - AuthManagerDelegate

extension AppDelegate: AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didChange state: AuthState) {
        menuViewController.signInMessage = manager.signInMessage
        menuViewController.render(state: state)
        switch state {
        case .signedIn(let source, _):
            if let usageSource = manager.usageSource { startUsageService(source: usageSource, identity: source) }
        default:
            stopUsageService()
        }
    }
}

// MARK: - UsageServiceDelegate

extension AppDelegate: UsageServiceDelegate {
    func usageService(_ service: UsageService, didUpdate data: UsageData) {
        guard service === usageService else { return }   // a poll that finished after sign-out or expiry
        updateStatusIcon(progress: data.ringValue(for: ringMetricMode), colorState: data.ringColorState(for: ringMetricMode))
        menuViewController.update(with: data)
    }

    func usageService(_ service: UsageService, didFailWith error: ClaudeAPIError) {
        guard service === usageService else { return }
        var message = error.userMessage
        if case .decode = error { message += " (v\(MenuViewController.appVersion))" }   // bug reports need the version
        menuViewController.showError(message)
    }

    func usageServiceDidDetectSessionExpiry(_ service: UsageService) {
        guard service === usageService else { return }
        authManager.sessionDidExpire()
    }
}
