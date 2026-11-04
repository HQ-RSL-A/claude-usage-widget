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
    private let settings = ServiceSettings(defaults: .standard)
    private var statusRenderer: StatusItemRenderer?
    private var statusTimer: Timer?
    private var authState: AuthState = .unknown
    /// Reads Grok Bot and Codex by itself, beside Claude's own sign-in and polling. Nil in preview mode.
    private var servicesPoller: ServicesPoller?

    /// `-previewUsage <scenario>`: made-up numbers, no sign-in, no Keychain, no WebKit, no file or network reads.
    private let preview = PreviewScenario.fromLaunchArguments()
    private var previewData: UsageData?
    private var previewServices: [ServiceID: ServiceState] = [:]

    /// Opening the panel reads again when the last read was longer ago than this.
    private static let openRefreshAfter: TimeInterval = 60

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any request: versions before 0.6.0 sent theirs through URLSession.shared, which kept each one,
        // bearer token included, in the disk cache.
        HTTP.purgeCachedResponses()
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()                 // before any WebKit object exists (Sonoma NSStatusBar issue)
        setupPopover()
        startStatusUpdates()
        if let preview {
            showPreview(preview)
            return
        }
        ServiceSettings.removeLegacyKeys(from: .standard)
        client = ClaudeAPIClient()
        authManager = AuthManager(dependencies: .init(
            oauth: OAuthClient(),
            tokenStore: KeychainTokenStore(),
            claudeCode: SecurityToolClaudeCodeCredentials(),
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
        startServicesPoller()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: StatusIcon.itemLength())   // one width for every title
        guard let button = statusItem.button else { return }
        StatusIcon.configure(button)
        button.action = #selector(togglePopover)
        button.target = self
        // No appearance observer: the image picks light or dark while it is drawn (StatusIcon). Re-setting it
        // on appearance changes was an endless loop, because macOS sets the appearance on every redraw.
        statusRenderer = StatusItemRenderer(display: button)
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
        menuViewController.shownServices = { [weak self] in self?.shownServices() ?? [.claude] }
        menuViewController.setUpServices = { [weak self] in self?.setUpServices() ?? [.claude] }
        menuViewController.currentMenuBarChoice = { [weak self] in self?.settings.menuBarChoice ?? .lowest }
        menuViewController.onToggleService = { [weak self] in self?.toggleService($0) }
        menuViewController.onChooseMenuBar = { [weak self] in self?.chooseMenuBar($0) }
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
            Task { @MainActor in self?.render() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// Grok Bot and Codex are read from files on this Mac, every five minutes and on demand. A service the person
    /// hid is not read at all: reading Codex sends its token to ChatGPT.
    private func startServicesPoller() {
        let poller = ServicesPoller(readers: [GrokBotReader(), CodexReader()])
        poller.isEnabled = { [weak self] service in !(self?.settings.isHidden(service) ?? false) }
        poller.onChange = { [weak self] in self?.render() }
        servicesPoller = poller
        render()   // the services set up on this Mac get their sections now, loading, before the first read lands
        poller.start()
    }

    // MARK: - What is shown

    /// The services this Mac has: Claude always (its sign-in is its own), the others when their files are here.
    /// Preview mode has its own list.
    private func setUpServices() -> [ServiceID] {
        if let preview { return preview.setUpServices }
        return [.claude] + (servicesPoller?.setUpServices() ?? [])
    }

    /// The services with a section in the panel and a say in the menu bar: the set-up ones minus the hidden ones,
    /// and never fewer than one.
    private func shownServices() -> [ServiceID] {
        settings.shownServices(among: setUpServices())
    }

    /// What each set-up service has to show now. Claude's comes from its own sign-in and polling; the others from the
    /// poller, loading until their first read lands. Preview mode brings made-up numbers.
    private func serviceStates(setUp: [ServiceID]) -> [ServiceID: ServiceState] {
        let claudeData = preview != nil ? previewData : usageService?.lastData
        let others = preview != nil ? previewServices : servicesPoller?.states ?? [:]
        return ServiceState.merged(claude: .claude(state: authState, data: claudeData), others: others, setUp: setUp)
    }

    // MARK: - Status Item

    /// The menu bar item only. It runs once before the panel exists, so nothing here may touch the panel.
    private func renderStatusItem() {
        guard let statusRenderer else { return }
        let setUp = setUpServices()
        statusRenderer.render(StatusPresentation.make(
            services: serviceStates(setUp: setUp),
            visible: settings.shownServices(among: setUp),
            choice: settings.menuBarChoice,
            text: UsageText()
        ))
    }

    /// The menu bar item and the panel, from what every service has to show right now.
    private func render() {
        renderStatusItem()
        menuViewController.update(services: serviceStates(setUp: setUpServices()))
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

    // MARK: - "..." menu choices

    /// Hides a shown service or shows a hidden one. The last shown service stays: an empty panel is a dead end.
    private func toggleService(_ service: ServiceID) {
        let shown = shownServices()
        let isShown = shown.contains(service)
        if isShown && shown.count == 1 { return }
        settings.setHidden(isShown, for: service)
        render()
        // It was not read while it was hidden, so it is read now rather than at the next poll.
        if !isShown { refreshServices() }
    }

    private func chooseMenuBar(_ choice: MenuBarChoice) {
        settings.menuBarChoice = choice
        render()
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
        refreshServices()
    }

    /// Reads Grok Bot and Codex now. Each state that changes redraws the menu bar and the panel (`onChange`).
    private func refreshServices() {
        guard let servicesPoller else { return }
        Task { await servicesPoller.refresh() }
    }

    /// Everything that can go stale: Claude's numbers, then the other services'.
    private func refreshEverything() {
        if case .signedIn = authState { usageService?.fetch() }
        refreshServices()
    }

    @objc private func systemDidWake() {
        refreshEverything()
    }

    /// Opening the panel brings the numbers up to date, unless they were read within the last minute.
    private func refreshWhenOpened() {
        guard let servicesPoller else { return }
        if let last = servicesPoller.lastRefresh, Date().timeIntervalSince(last) <= Self.openRefreshAfter { return }
        refreshEverything()
    }

    private func showPreview(_ scenario: PreviewScenario) {
        let now = Date()
        authState = scenario.state
        previewData = scenario.data(now: now)
        previewServices = scenario.services(now: now)
        menuViewController.render(state: scenario.state)
        if let previewData { menuViewController.update(with: previewData) }
        render()
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
        refreshWhenOpened()
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
        render()
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
        menuViewController.update(with: data)
        render()
    }

    func usageService(_ service: UsageService, didFailWith error: ClaudeAPIError) {
        guard service === usageService else { return }
        var message = error.userMessage
        if case .decode = error { message += " (v\(MenuViewController.appVersion))" }   // bug reports need the version
        menuViewController.showError(message)
        render()
    }

    func usageServiceDidDetectSessionExpiry(_ service: UsageService) {
        guard service === usageService else { return }
        authManager.sessionDidExpire()
    }
}
