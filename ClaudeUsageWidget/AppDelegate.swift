import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Components

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var menuViewController: MenuViewController!
    private var client: ClaudeAPIClient!
    private var authManager: AuthManager!
    private var usageService: UsageService?
    private var ringMetricMode: RingMetricMode = .saved

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()                 // before any WebKit object exists (Sonoma NSStatusBar issue)
        setupPopover()
        client = ClaudeAPIClient()
        authManager = AuthManager(client: client)
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
            if case .signedIn = self.authManager.state {
                self.usageService?.fetch()
            } else {
                Task { await self.authManager.checkAuthStatus() }
            }
        }
        menuViewController.onSignOut = { [weak self] in self?.signOut() }
        menuViewController.onSignIn = { [weak self] in self?.authManager.showLoginWindow() }
        menuViewController.onToggleMode = { [weak self] mode in
            guard let self = self else { return }
            self.ringMetricMode = mode
            if let data = self.usageService?.lastData {
                let progress = data.ringValue(for: mode)
                let colorState = data.ringColorState(for: mode)
                self.updateStatusIcon(progress: progress, colorState: colorState)
            }
        }

        popover = NSPopover()
        popover.contentViewController = menuViewController
        popover.behavior = .transient
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

    private func startUsageService(for org: Organization) {
        if let service = usageService, service.orgId == org.uuid { return }
        stopUsageService()
        let service = UsageService(client: client, orgId: org.uuid)
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

// MARK: - AuthManagerDelegate

extension AppDelegate: AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didChange state: AuthState) {
        menuViewController.render(state: state)
        switch state {
        case .signedIn(let org, _):
            startUsageService(for: org)
        default:
            stopUsageService()
        }
    }
}

// MARK: - UsageServiceDelegate

extension AppDelegate: UsageServiceDelegate {
    func usageService(_ service: UsageService, didUpdate data: UsageData) {
        updateStatusIcon(progress: data.ringValue(for: ringMetricMode), colorState: data.ringColorState(for: ringMetricMode))
        menuViewController.update(with: data)
    }

    func usageService(_ service: UsageService, didFailWith error: ClaudeAPIError) {
        var message = error.userMessage
        if case .decode = error { message += " (v\(MenuViewController.appVersion))" }   // bug reports need the version
        menuViewController.showError(message)
    }

    func usageServiceDidDetectSessionExpiry(_ service: UsageService) {
        authManager.sessionDidExpire()
    }
}
