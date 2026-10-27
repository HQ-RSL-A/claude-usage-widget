import AppKit

// MARK: - ProgressBarView

/// Custom thin progress bar drawn with Core Graphics. 4pt tall, 2pt corner radius.
/// The filled part is what's used; color adapts to the usage threshold (normal/amber/critical).
class ProgressBarView: NSView {

    var progress: Double = 0.0 {
        didSet { needsDisplay = true }
    }

    var colorState: RingColorState = .normal {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        let trackColor = NSColor.separatorColor
        let fillColor = StatusIcon.color(for: colorState, foreground: .labelColor)
        let radius: CGFloat = 2.0

        // Track
        let trackPath = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        trackColor.setFill()
        trackPath.fill()

        // Fill
        let clampedProgress = min(max(progress, 0.0), 1.0)
        guard clampedProgress > 0 else { return }
        let fillWidth = bounds.width * clampedProgress
        let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        fillColor.setFill()
        fillPath.fill()
    }
}

// MARK: - UsageRowView

class UsageRowView: NSView {

    private let nameLabel: NSTextField
    private let progressBar: ProgressBarView
    private let percentLabel: NSTextField
    private let detailLabel: NSTextField

    init(label: String) {
        nameLabel = NSTextField(labelWithString: label)
        progressBar = ProgressBarView()
        percentLabel = NSTextField(labelWithString: "")
        detailLabel = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    var percentText: String { percentLabel.stringValue }
    var detailText: String { detailLabel.stringValue }

    private func setupUI() {
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 10, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        // Top row: name + percent
        let topRow = NSStackView(views: [nameLabel, percentLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .lastBaseline
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // Main stack: top row, progress bar, detail (hidden when empty)
        let stack = NSStackView(views: [topRow, progressBar, detailLabel])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
        ])
    }

    /// `percentText` says what's left; the bar fills with what's used, so its empty part is what's left.
    func update(percentText: String, used: Double, colorState: RingColorState, detail: String) {
        progressBar.progress = used
        progressBar.colorState = colorState
        percentLabel.stringValue = percentText
        setDetail(detail)
    }

    func setDetail(_ detail: String) {
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty
    }
}

// MARK: - MenuViewController

class MenuViewController: NSViewController {

    // Callbacks set by AppDelegate
    var onRefresh: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onSignInBrowser: (() -> Void)?
    var onUseClaudeCode: (() -> Void)?
    var onSignInInsideApp: (() -> Void)?
    var onCancelSignIn: (() -> Void)?
    var onChangeLayout: ((MenuBarLayout) -> Void)?
    var onToggleOpenAtLogin: (() -> Void)?

    // Read each time the settings menu opens
    var currentLayout: () -> MenuBarLayout = { .both }
    var isOpenAtLoginEnabled: () -> Bool = { false }

    /// Plain words for the current moment; tests swap in a fixed clock.
    var makeText: () -> UsageText = { UsageText() }

    /// Shown under the empty-state title until the next sign-in attempt.
    var signInMessage: String?

    private let browserButton = NSButton(title: "Sign in with your browser", target: nil, action: nil)
    private let claudeCodeButton = NSButton(title: "Use Claude Code's sign-in", target: nil, action: nil)
    private let insideAppButton = NSButton(title: "Sign in inside the app", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var buttonStack: NSStackView!

    // MARK: - State

    private var state: AuthState = .unknown
    private var lastData: UsageData?
    private var isFetching = false
    private var failure: String?
    /// Rows whose reset text moves with the clock.
    private var bucketRows: [(row: UsageRowView, bucket: UsageBucket)] = []
    private var clockTimer: Timer?

    // MARK: - UI Elements

    private let titleLabel = NSTextField(labelWithString: "Claude Usage")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let emptyTitleLabel = NSTextField(labelWithString: "Not signed in")
    private let emptySubtitleLabel = NSTextField(labelWithString: "Sign in to see your usage")
    private let refreshButton = MenuViewController.iconButton(symbol: "arrow.clockwise", label: "Refresh")
    private let spinner = NSProgressIndicator()
    private let settingsButton = MenuViewController.iconButton(symbol: "gearshape", label: "Settings")
    private let rowsStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let authButton = NSButton(title: "Sign Out", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let separator = NSBox()
    private let versionLabel = NSTextField(labelWithString: "v" + MenuViewController.appVersion)

    static var appVersion: String { AppInfo.version }

    // Containers for toggling visibility
    private var usageStack: NSStackView!
    private var emptyStateView: NSView!

    // MARK: - View Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 280))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        // Apply deferred auth state (updateAuthState may have been called before view loaded)
        applyAuthState()
    }

    // MARK: - Setup

    private static func iconButton(symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = NSButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func setupUI() {
        // Title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Subtitle ("Signed in as ...")
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.isHidden = true
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        // Refresh, its spinner while a fetch runs, and settings
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped(_:))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [spinner, refreshButton, settingsButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.setContentHuggingPriority(.required, for: .horizontal)

        // Header row
        let headerRow = NSStackView(views: [titleStack, controls])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // Usage rows (rebuilt from data on every update)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // Status line: updated, updating, or couldn't refresh (may wrap to two lines)
        statusLabel.font = .systemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.preferredMaxLayoutWidth = 272
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        // Usage stack (visible when signed in)
        usageStack = NSStackView(views: [rowsStack, statusLabel])
        usageStack.orientation = .vertical
        usageStack.alignment = .leading
        usageStack.spacing = 10
        usageStack.translatesAutoresizingMaskIntoConstraints = false

        // Empty state (visible when signed out)
        emptyStateView = createEmptyStateView()
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true

        // Separator
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Auth button (Sign Out)
        authButton.bezelStyle = .inline
        authButton.isBordered = false
        authButton.font = .systemFont(ofSize: 11, weight: .regular)
        authButton.contentTintColor = .secondaryLabelColor
        authButton.target = self
        authButton.action = #selector(authTapped)
        authButton.translatesAutoresizingMaskIntoConstraints = false

        // Quit button
        quitButton.bezelStyle = .inline
        quitButton.isBordered = false
        quitButton.font = .systemFont(ofSize: 11, weight: .regular)
        quitButton.contentTintColor = .secondaryLabelColor
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        // Version label
        versionLabel.font = .systemFont(ofSize: 10, weight: .regular)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        // Footer row
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let footerRow = NSStackView(views: [versionLabel, spacer, authButton, quitButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 12
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        // Main stack
        let mainStack = NSStackView(views: [
            headerRow,
            usageStack,
            emptyStateView,
            separator,
            footerRow,
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.distribution = .fill
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        // Full-width constraints
        separator.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        headerRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        footerRow.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        usageStack.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        emptyStateView.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        rowsStack.widthAnchor.constraint(equalTo: usageStack.widthAnchor).isActive = true

        view.addSubview(mainStack)

        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            view.widthAnchor.constraint(equalToConstant: 300),
        ])
    }

    private func createEmptyStateView() -> NSView {
        let container = NSView()

        let ringSymbol = NSTextField(labelWithString: "○")
        ringSymbol.font = .systemFont(ofSize: 28, weight: .ultraLight)
        ringSymbol.textColor = .tertiaryLabelColor
        ringSymbol.alignment = .center
        ringSymbol.translatesAutoresizingMaskIntoConstraints = false

        emptyTitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyTitleLabel.alignment = .center
        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        emptySubtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        emptySubtitleLabel.textColor = .tertiaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Sign-in routes; which ones show depends on the state
        for (button, action) in [(browserButton, #selector(browserTapped)), (claudeCodeButton, #selector(claudeCodeTapped)), (cancelButton, #selector(cancelTapped))] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.target = self
            button.action = action
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        browserButton.keyEquivalent = "\r"
        insideAppButton.isBordered = false
        insideAppButton.font = .systemFont(ofSize: 10, weight: .regular)
        insideAppButton.contentTintColor = .secondaryLabelColor
        insideAppButton.target = self
        insideAppButton.action = #selector(insideAppTapped)
        insideAppButton.translatesAutoresizingMaskIntoConstraints = false

        buttonStack = NSStackView(views: [])
        buttonStack.orientation = .vertical
        buttonStack.alignment = .centerX
        buttonStack.spacing = 6
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [ringSymbol, emptyTitleLabel, emptySubtitleLabel, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.setCustomSpacing(12, after: emptySubtitleLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        return container
    }

    // MARK: - Read-only state (for tests and diagnostics)

    var rowCount: Int { rowsStack.arrangedSubviews.count }
    var usageRowCount: Int { rowsStack.arrangedSubviews.filter { $0 is UsageRowView }.count }
    var rowPercentTexts: [String] { rowsStack.arrangedSubviews.compactMap { ($0 as? UsageRowView)?.percentText } }
    var rowDetailTexts: [String] { rowsStack.arrangedSubviews.compactMap { ($0 as? UsageRowView)?.detailText } }
    var statusText: String { statusLabel.stringValue }
    var isShowingSpinner: Bool { !spinner.isHidden }
    var isShowingUsage: Bool { !usageStack.isHidden }
    var visibleSignInButtons: [String] { buttonStack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }
    var subtitleText: String { subtitleLabel.isHidden ? "" : subtitleLabel.stringValue }
    var footerAuthTitle: String? { authButton.isHidden ? nil : authButton.title }
    var emptyTitle: String { emptyTitleLabel.stringValue }
    var emptySubtitle: String { emptySubtitleLabel.stringValue }
    var containsSegmentedControl: Bool {
        func search(_ view: NSView) -> Bool { view is NSSegmentedControl || view.subviews.contains(where: search) }
        return search(view)
    }

    // MARK: - Public Update Methods

    func update(with data: UsageData) {
        lastData = data
        isFetching = false
        failure = nil
        rebuildRows(from: data)
        renderStatus()
        resizeToFit()
    }

    private func rebuildRows(from data: UsageData) {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        bucketRows = []
        let text = makeText()
        for bucket in data.buckets {
            let row = UsageRowView(label: bucket.kind.label)
            row.update(percentText: text.percentLeft(bucket), used: bucket.percentUsed, colorState: bucket.barColorState, detail: text.detail(bucket))
            addRow(row)
            bucketRows.append((row, bucket))
        }
        if let extra = data.extraUsage, extra.isEnabled, let used = extra.percentUsed {
            let row = UsageRowView(label: "Extra usage")
            row.update(percentText: "\(UsageBucket.percentLeft(forUsed: used))% left", used: used, colorState: .from(percent: used), detail: "Monthly budget")
            addRow(row)
        }
        if rowsStack.arrangedSubviews.isEmpty {
            let label = NSTextField(labelWithString: "No usage limits reported for this plan")
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            rowsStack.addArrangedSubview(label)
        }
    }

    private func addRow(_ row: UsageRowView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    /// Reset countdowns and the status line, worked out again for the current time.
    func renderTimes() {
        let text = makeText()
        for entry in bucketRows { entry.row.setDetail(text.detail(entry.bucket)) }
        renderStatus()
        resizeToFit()
    }

    private func renderStatus() {
        statusLabel.stringValue = makeText().status(lastUpdated: lastData?.lastUpdated, isFetching: isFetching, failure: failure)
        spinner.isHidden = !isFetching
        refreshButton.isHidden = isFetching
        if isFetching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// NSPopover tracks preferredContentSize, so two rows and five rows both fit.
    private func resizeToFit() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 300, height: view.fittingSize.height)
    }

    /// Call when the popover is about to show: the times catch up, then keep moving while it stays open.
    func popoverWillShow() {
        renderTimes()
        clockTimer?.invalidate()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderTimes() }
        }
    }

    func popoverDidClose() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    func render(state: AuthState) {
        self.state = state
        // View may not be loaded yet (popover is lazy); applyAuthState runs in viewDidLoad
        guard isViewLoaded else { return }
        applyAuthState()
    }

    private func applyAuthState() {
        switch state {
        case .signedIn(let source, let profile):
            usageStack.isHidden = false
            emptyStateView.isHidden = true
            refreshButton.isEnabled = true
            setSubtitle(Self.subtitle(for: source, profile: profile))
            setFooter(authTitle: "Sign Out")
        case .unknown:
            showEmpty(title: "Checking sign-in...", subtitle: "One moment", buttons: [], refreshEnabled: false, authTitle: nil)
        case .unreachable:
            showEmpty(title: "Could not reach claude.ai", subtitle: "Check your connection and refresh", buttons: [], refreshEnabled: true, authTitle: nil)
        case .signedOut(let claudeCodeAvailable):
            var buttons = [browserButton]
            if claudeCodeAvailable { buttons.append(claudeCodeButton) }
            buttons.append(insideAppButton)
            showEmpty(title: "Not signed in", subtitle: signInMessage ?? "Your browser does the signing in", buttons: buttons, refreshEnabled: false, authTitle: nil)
        case .signingIn:
            showEmpty(title: "Waiting for your browser...", subtitle: "Approve the sign-in in the tab that opened", buttons: [cancelButton], refreshEnabled: false, authTitle: nil)
        case .sessionExpired(let source):
            let buttons: [NSButton]
            switch source {
            case .ownToken: buttons = [browserButton]
            case .claudeCode: buttons = [claudeCodeButton, browserButton]
            case .webSession: buttons = [insideAppButton, browserButton]
            }
            showEmpty(title: "Session expired", subtitle: "Sign in again to keep tracking usage", buttons: buttons, refreshEnabled: false, authTitle: "Sign Out")
        case .noChatOrg:
            showEmpty(title: "No Claude plan on this account", subtitle: "This account only has API access", buttons: [browserButton], refreshEnabled: false, authTitle: "Sign Out")
        }
        resizeToFit()
    }

    static func subtitle(for source: IdentitySource, profile: Profile?) -> String {
        if let email = profile?.email { return "Signed in as \(email)" }
        if let org = profile?.organizationName { return org }
        switch source {
        case .claudeCode: return "via Claude Code"
        case .ownToken: return "Signed in with your browser"
        case .webSession: return ""
        }
    }

    private func showEmpty(title: String, subtitle: String, buttons: [NSButton], refreshEnabled: Bool, authTitle: String?) {
        usageStack.isHidden = true
        emptyStateView.isHidden = false
        setSubtitle("")
        refreshButton.isEnabled = refreshEnabled
        emptyTitleLabel.stringValue = title
        emptySubtitleLabel.stringValue = subtitle
        buttonStack.arrangedSubviews.forEach {
            buttonStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for button in [browserButton, claudeCodeButton, insideAppButton, cancelButton] {
            button.isHidden = !buttons.contains(button)
        }
        buttons.forEach { buttonStack.addArrangedSubview($0) }
        setFooter(authTitle: authTitle)
    }

    private func setSubtitle(_ text: String) {
        subtitleLabel.stringValue = text
        subtitleLabel.isHidden = text.isEmpty
    }

    private func setFooter(authTitle: String?) {
        authButton.isHidden = authTitle == nil
        authButton.title = authTitle ?? ""
        authButton.contentTintColor = .secondaryLabelColor
        authButton.font = .systemFont(ofSize: 11, weight: .regular)
    }

    func showLoading() {
        isFetching = true
        renderStatus()
    }

    func showError(_ message: String) {
        isFetching = false
        failure = message
        renderStatus()
        resizeToFit()
    }

    // MARK: - Settings menu

    func makeSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let heading = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let current = currentLayout()
        for layout in MenuBarLayout.allCases {
            let item = NSMenuItem(title: layout.menuTitle, action: #selector(layoutChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            item.state = layout == current ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let openAtLogin = NSMenuItem(title: "Open at Login", action: #selector(openAtLoginChosen(_:)), keyEquivalent: "")
        openAtLogin.target = self
        openAtLogin.state = isOpenAtLoginEnabled() ? .on : .off
        menu.addItem(openAtLogin)
        return menu
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        onRefresh?()
    }

    @objc private func settingsTapped(_ sender: NSButton) {
        // Drop the menu just below the gear.
        let y = sender.isFlipped ? sender.bounds.maxY + 4 : -4
        makeSettingsMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
    }

    @objc private func layoutChosen(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let layout = MenuBarLayout(rawValue: raw) else { return }
        onChangeLayout?(layout)
    }

    @objc private func openAtLoginChosen(_ item: NSMenuItem) {
        onToggleOpenAtLogin?()
    }

    @objc private func authTapped() {
        onSignOut?()
    }

    @objc private func browserTapped() { onSignInBrowser?() }
    @objc private func claudeCodeTapped() { onUseClaudeCode?() }
    @objc private func insideAppTapped() { onSignInInsideApp?() }
    @objc private func cancelTapped() { onCancelSignIn?() }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }
}
