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
    private let openAtLogin = OpenAtLogin()
    private var appearanceObservation: NSKeyValueObservation?
    private var statusTimer: Timer?
    private var authState: AuthState = .unknown

    /// `-previewUsage <scenario>`: made-up numbers, no sign-in, no Keychain, no WebKit.
    private let preview = PreviewScenario.fromLaunchArguments()
    private var previewData: UsageData?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()                 // before any WebKit object exists (Sonoma NSStatusBar issue)
        setupPopover()
        startStatusUpdates()
        if let preview {
            showPreview(preview)
            return
        }
        MenuBarLayout.removeLegacyKeys(from: .standard)
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.imageScaling = .scaleProportionallyDown
        button.action = #selector(togglePopover)
        button.target = self
        button.setAccessibilityLabel("Claude Usage")
        // The menu bar turns light or dark with the wallpaper; a non-template image has to follow it.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.renderStatusItem() }
        }
        renderStatusItem()
    }

    private func setupPopover() {
        menuViewController = MenuViewController()
        menuViewController.onRefresh = { [weak self] in self?.refresh() }
        menuViewController.onSignOut = { [weak self] in self?.signOut() }
        menuViewController.onSignInBrowser = { [weak self] in Task { await self?.authManager?.signInWithBrowser() } }
        menuViewController.onUseClaudeCode = { [weak self] in Task { await self?.authManager?.useClaudeCodeToken() } }
        menuViewController.onSignInInsideApp = { [weak self] in self?.authManager?.signInInsideApp() }
        menuViewController.onCancelSignIn = { [weak self] in self?.authManager?.cancelBrowserSignIn() }
        menuViewController.currentLayout = { MenuBarLayout.load(from: .standard) }
        menuViewController.onChangeLayout = { [weak self] layout in
            layout.save(to: .standard)
            self?.renderStatusItem()
        }
        menuViewController.isOpenAtLoginEnabled = { [weak self] in self?.openAtLogin.isEnabled ?? false }
        menuViewController.onToggleOpenAtLogin = { [weak self] in self?.openAtLogin.toggle() }

        popover = NSPopover()
        popover.contentViewController = menuViewController
        popover.behavior = .transient
        popover.delegate = self
        outsideClick = OutsideClickDismisser(
            isShown: { [weak self] in self?.popover.isShown ?? false },
            close: { [weak self] in self?.popover.performClose(nil) }
        )
    }

    /// Keeps the menu bar honest between polls: stale numbers dim and the tooltip's times move.
    /// After a sleep the numbers are refreshed at once instead of at the next poll.
    private func startStatusUpdates() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderStatusItem() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Status Item

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let data = preview != nil ? previewData : usageService?.lastData
        let presentation = StatusPresentation.make(state: authState, data: data, layout: MenuBarLayout.load(from: .standard), text: UsageText())
        let isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        button.image = StatusIcon.image(for: presentation.icon, darkMenuBar: isDark)
        button.toolTip = presentation.toolTip
        button.setAccessibilityValue(presentation.accessibilityValue)
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

    // MARK: - Refresh

    private func refresh() {
        if let preview {
            showPreview(preview)
            return
        }
        switch authManager.state {
        case .signedIn: usageService?.fetch()
        case .signingIn: break
        default: Task { await authManager.checkAuthStatus() }
        }
    }

    @objc private func systemDidWake() {
        guard case .signedIn = authState else { return }
        usageService?.fetch()
    }

    private func showPreview(_ scenario: PreviewScenario) {
        authState = scenario.state
        previewData = scenario.data(now: Date())
        menuViewController.render(state: scenario.state)
        if let previewData { menuViewController.update(with: previewData) }
        renderStatusItem()
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
        renderStatusItem()
    }

    // MARK: - Sign Out

    private func signOut() {
        guard preview == nil else { return }
        stopUsageService()
        authManager.signOut()
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        menuViewController.popoverWillShow()
    }

    func popoverDidShow(_ notification: Notification) {
        outsideClick.popoverDidShow()
    }

    func popoverDidClose(_ notification: Notification) {
        outsideClick.popoverDidClose()
        menuViewController.popoverDidClose()
    }
}

// MARK: - AuthManagerDelegate

extension AppDelegate: AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didChange state: AuthState) {
        authState = state
        menuViewController.signInMessage = manager.signInMessage
        menuViewController.render(state: state)
        switch state {
        case .signedIn(let source, _):
            if let usageSource = manager.usageSource { startUsageService(source: usageSource, identity: source) }
        default:
            stopUsageService()
        }
        renderStatusItem()
    }
}

// MARK: - UsageServiceDelegate

extension AppDelegate: UsageServiceDelegate {
    func usageServiceDidStartFetching(_ service: UsageService) {
        guard service === usageService else { return }
        menuViewController.showLoading()
    }

    func usageService(_ service: UsageService, didUpdate data: UsageData) {
        guard service === usageService else { return }   // a poll that finished after sign-out or expiry
        renderStatusItem()
        menuViewController.update(with: data)
    }

    func usageService(_ service: UsageService, didFailWith error: ClaudeAPIError) {
        guard service === usageService else { return }
        var message = error.userMessage
        if case .decode = error { message += " (v\(MenuViewController.appVersion))" }   // bug reports need the version
        menuViewController.showError(message)
        renderStatusItem()
    }

    func usageServiceDidDetectSessionExpiry(_ service: UsageService) {
        guard service === usageService else { return }
        authManager.sessionDidExpire()
    }
}
