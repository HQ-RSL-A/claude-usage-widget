import AppKit

// MARK: - IconButton

/// A borderless button that is exactly the size it is given: AppKit's own leaves part of it outside the
/// layout rect, which would leave only part of the space around the dots to click.
private final class IconButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

// MARK: - LinkButton

/// The quiet "Sign in inside the app" link. A borderless button draws its words a little inside its frame;
/// this one lines them up with the edge of the column.
private final class LinkButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 0) }
}

// MARK: - MenuViewController

/// The popover: a header with a "..." menu, one section per shown service, and a footer.
/// Claude is shown from its own sign-in and numbers; the other services come in through `update(services:)`.
class MenuViewController: NSViewController {

    // Callbacks set by AppDelegate
    var onRefresh: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onSignInBrowser: (() -> Void)?
    var onUseClaudeCode: (() -> Void)?
    var onSignInInsideApp: (() -> Void)?
    var onCancelSignIn: (() -> Void)?
    var onToggleOpenAtLogin: (() -> Void)?
    var onToggleService: ((ServiceID) -> Void)?
    var onChooseMenuBar: ((MenuBarChoice) -> Void)?

    // Read each time the panel is drawn or the "..." menu opens
    var isOpenAtLoginEnabled: () -> Bool = { false }
    var currentMenuBarChoice: () -> MenuBarChoice = { .lowest }
    /// The services with a section, in panel order. Never empty: an empty panel is a dead end.
    var shownServices: () -> [ServiceID] = { [.claude] }
    /// The services worth offering in the "Show" menu: the ones set up on this Mac.
    var setUpServices: () -> [ServiceID] = { [.claude] }
    /// Each service's icon, from the app's shared cache: the panel redraws often, and a lookup is not free.
    var panelIcon: (ServiceID) -> NSImage = { ServiceIcon.panelIcons.icon(for: $0) } {
        didSet { renderedSections = nil }
    }

    /// Plain words for the current moment; tests swap in a fixed clock.
    var makeText: () -> UsageText = { UsageText() }

    /// Shown under the sign-in title until the next sign-in attempt.
    var signInMessage: String?

    // MARK: - State

    private var state: AuthState = .unknown
    private var lastData: UsageData?
    private var otherServices: [ServiceID: ServiceState] = [:]
    private var isFetching = false
    private var failure: String?
    private var renderedSections: [PanelSection]?
    private var clockTimer: Timer?

    /// A reading this old gets a note saying so, whichever service it is from.
    private static let noteAfter: TimeInterval = 15 * 60
    /// The "..." button is wider than its dots, so it hangs this far past the margin and the dots end where the columns end.
    private static let dotsOverhang: CGFloat = 6
    /// All the click target the header has to give the dots.
    private static let dotsSize = NSSize(width: 28, height: 22)
    /// The space between the header, the sections and the footer, and around the whole panel.
    private static let spacing: CGFloat = 10
    private static let topInset: CGFloat = 12
    private static let bottomInset: CGFloat = 10

    // MARK: - UI Elements

    private let titleLabel = NSTextField(labelWithString: "Usage Remaining")
    private let spinner = NSProgressIndicator()
    private let moreButton = MenuViewController.iconButton(symbol: "ellipsis", label: "More")
    private let sectionsStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "v" + MenuViewController.appVersion)

    static var appVersion: String { AppInfo.version }

    // MARK: - View Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 160))
        view.wantsLayer = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        // Whatever came in before the view loaded is applied now.
        reload()
    }

    // MARK: - Setup

    private static func iconButton(symbol: String, label: String) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = IconButton(image: image, target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func setupUI() {
        // Header: the title, a spinner while a fetch runs, and the "..." button
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        moreButton.target = self
        moreButton.action = #selector(moreTapped(_:))
        moreButton.sendAction(on: .leftMouseDown)   // a menu opens as the mouse goes down, like a pull-down button

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        header.addSubview(spinner)
        header.addSubview(moreButton)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: Self.dotsSize.height),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: Self.dotsOverhang),
            moreButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: Self.dotsSize.width),
            moreButton.heightAnchor.constraint(equalToConstant: Self.dotsSize.height),
            spinner.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: header.centerYAnchor),
        ])

        // Sections (rebuilt whenever what they say changes)
        sectionsStack.orientation = .vertical
        sectionsStack.alignment = .leading
        sectionsStack.spacing = Self.spacing
        sectionsStack.translatesAutoresizingMaskIntoConstraints = false

        // Footer: Claude's status line on the left, the version on the right
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.setContentHuggingPriority(.required, for: .horizontal)
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.preferredMaxLayoutWidth = PanelMetrics.contentWidth - versionLabel.intrinsicContentSize.width - 8

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(statusLabel)
        footer.addSubview(versionLabel)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: footer.topAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: footer.bottomAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            versionLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            versionLabel.firstBaselineAnchor.constraint(equalTo: statusLabel.firstBaselineAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: versionLabel.leadingAnchor, constant: -8),
        ])

        let headerSeparator = Self.separator()
        let footerSeparator = Self.separator()
        let mainStack = NSStackView(views: [header, headerSeparator, sectionsStack, footerSeparator, footer])
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.distribution = .fill
        mainStack.spacing = Self.spacing
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        for full in [header, headerSeparator, sectionsStack, footerSeparator, footer] {
            full.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }

        view.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.topInset),
            mainStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: PanelMetrics.margin),
            mainStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -PanelMetrics.margin),
            mainStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Self.bottomInset),
            view.widthAnchor.constraint(equalToConstant: PanelMetrics.width),
        ])
    }

    private static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    // MARK: - Public Update Methods

    func update(with data: UsageData) {
        lastData = data
        isFetching = false
        failure = nil
        reload()
    }

    /// What the other services (Grok Bot, Codex) have to show. It is the whole list: a service missing from it has no section.
    /// Claude is not taken from here; it is shown from its own sign-in and numbers.
    func update(services: [ServiceID: ServiceState]) {
        otherServices = services
        reload()
    }

    /// The times and ages, worked out again for the current time. Anything that did not change is left alone.
    func renderTimes() {
        reload()
    }

    func showLoading() {
        isFetching = true
        reload()
    }

    func showError(_ message: String) {
        isFetching = false
        failure = message
        reload()
    }

    func render(state: AuthState) {
        self.state = state
        // A fetch cut short by an expiry or a sign-out never reports back.
        if case .signedIn = state {} else { isFetching = false }
        reload()
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

    // MARK: - Drawing

    /// The view may not be loaded yet (the popover is lazy); `viewDidLoad` draws what came in before.
    private func reload() {
        guard isViewLoaded else { return }
        let text = makeText()
        let sections = makeSections(text: text)
        if sections != renderedSections {
            renderedSections = sections
            rebuildSections(sections)
        }
        renderFooter(text: text)
        resizeToFit()
    }

    private func rebuildSections(_ sections: [PanelSection]) {
        sectionsStack.arrangedSubviews.forEach {
            sectionsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, section) in sections.enumerated() {
            if index > 0 { addArranged(Self.separator()) }
            addArranged(ServiceSectionView(section: section, icon: panelIcon(section.service), makeButton: makeSignInButton))
        }
    }

    private func addArranged(_ view: NSView) {
        sectionsStack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: sectionsStack.widthAnchor).isActive = true
    }

    private func renderFooter(text: UsageText) {
        if case .signedIn = state, shownServices().contains(.claude) {
            statusLabel.stringValue = text.status(lastUpdated: lastData?.lastUpdated, isFetching: isFetching, failure: failure)
        } else {
            statusLabel.stringValue = ""
        }
        spinner.isHidden = !isFetching
        if isFetching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    /// NSPopover tracks preferredContentSize, so two rows and ten rows both fit.
    private func resizeToFit() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: PanelMetrics.width, height: view.fittingSize.height)
    }

    // MARK: - What each section says

    private func makeSections(text: UsageText) -> [PanelSection] {
        shownServices().compactMap { service in
            if service == .claude { return claudeSection(text: text) }
            return otherServices[service].map { section(for: service, state: $0, text: text) }
        }
    }

    /// Claude's own sign-in decides what its section says; its numbers count only while it is signed in.
    private func claudeSection(text: UsageText) -> PanelSection {
        var section = PanelSection(service: .claude, toolTip: claudeToolTip())
        guard case .signedIn = state else {
            section.signIn = signInPrompt()
            return section
        }
        guard let data = lastData else {
            section.note = failure != nil && !isFetching ? "Couldn't load usage" : "Loading..."
            return section
        }
        fill(&section, limits: data.serviceLimits, readAt: data.lastUpdated, text: text)
        return section
    }

    private func section(for service: ServiceID, state: ServiceState, text: UsageText) -> PanelSection {
        var section = PanelSection(service: service, toolTip: service.displayName)
        switch state {
        case .loading: section.note = "Loading..."
        case .reading(let limits, let readAt): fill(&section, limits: limits, readAt: readAt, text: text)
        case .notSignedIn(let hint): section.note = hint
        case .unavailable(let reason): section.note = reason
        }
        return section
    }

    private func fill(_ section: inout PanelSection, limits: [ServiceLimit], readAt: Date, text: UsageText) {
        section.rows = limits.map { row(for: $0, text: text) }
        // The menu bar asks the same question of the same reading, so the two never disagree about what is current.
        section.isDimmed = !ServiceState.reading(limits: limits, readAt: readAt).isCurrent(section.service, now: text.now)
        if limits.isEmpty {
            section.note = "No usage limits reported for this plan"
        } else if section.service != .claude, text.now.timeIntervalSince(readAt) > Self.noteAfter {
            // Claude's age is in the footer; the other services' is here, under their numbers.
            section.note = "Updated \(text.age(of: readAt))"
        }
    }

    private func row(for limit: ServiceLimit, text: UsageText) -> PanelRow {
        PanelRow(label: limit.label,
                 percent: "\(limit.percentLeft)%",
                 reset: text.shortReset(limit.resetsAt),
                 toolTip: limit.isBudget ? "Monthly budget" : text.fullReset(limit.resetsAt),
                 colorState: limit.colorState)
    }

    private func claudeToolTip() -> String {
        guard case .signedIn(let source, let profile) = state else { return ServiceID.claude.displayName }
        let who = Self.subtitle(for: source, profile: profile)
        return who.isEmpty ? ServiceID.claude.displayName : ServiceID.claude.displayName + "\n" + who
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

    /// Where Claude's sign-in stands, and the buttons that move it on. Nil while signed in.
    private func signInPrompt() -> SignInPrompt? {
        switch state {
        case .signedIn:
            return nil
        case .unknown:
            return SignInPrompt(title: "Checking sign-in...", subtitle: "One moment", buttons: [])
        case .unreachable:
            return SignInPrompt(title: "Could not reach claude.ai", subtitle: "Check your connection and refresh", buttons: [])
        case .signedOut(let claudeCodeAvailable):
            var buttons: [SignInButton] = [.browser]
            if claudeCodeAvailable { buttons.append(.claudeCode) }
            buttons.append(.insideApp)
            return SignInPrompt(title: "Not signed in", subtitle: signInMessage ?? "Your browser does the signing in", buttons: buttons)
        case .signingIn:
            return SignInPrompt(title: "Waiting for your browser...", subtitle: "Approve the sign-in in the tab that opened", buttons: [.cancel])
        case .sessionExpired(let source):
            let buttons: [SignInButton]
            switch source {
            case .ownToken: buttons = [.browser]
            case .claudeCode: buttons = [.claudeCode, .browser]
            case .webSession: buttons = [.insideApp, .browser]
            }
            return SignInPrompt(title: "Session expired", subtitle: "Sign in again to keep tracking usage", buttons: buttons)
        case .noChatOrg:
            return SignInPrompt(title: "No Claude plan on this account", subtitle: "This account only has API access", buttons: [.browser])
        }
    }

    private func makeSignInButton(_ kind: SignInButton) -> NSButton {
        let button = kind == .insideApp ? LinkButton() : NSButton()
        button.title = kind.title
        button.target = self
        button.action = action(for: kind)
        switch kind {
        case .insideApp:
            button.isBordered = false
            button.font = .systemFont(ofSize: 10)
            button.contentTintColor = .secondaryLabelColor
        case .browser, .claudeCode, .cancel:
            button.bezelStyle = .rounded
            button.controlSize = .small
            if kind == .browser { button.keyEquivalent = "\r" }
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func action(for kind: SignInButton) -> Selector {
        switch kind {
        case .browser: return #selector(browserTapped)
        case .claudeCode: return #selector(claudeCodeTapped)
        case .insideApp: return #selector(insideAppTapped)
        case .cancel: return #selector(cancelTapped)
        }
    }

    // MARK: - More menu

    func makeMoreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let shown = shownServices()

        menu.addItem(item("Refresh", #selector(refreshChosen)))

        menu.addItem(.separator())
        menu.addItem(heading("Menu Bar Shows"))
        // A pinned service that is hidden leaves the menu bar on the lowest limit, so the check follows it.
        var choice = currentMenuBarChoice()
        if case .service(let pinned) = choice, !shown.contains(pinned) { choice = .lowest }
        menu.addItem(item("Lowest Remaining", #selector(menuBarChosen(_:)), checked: choice == .lowest, value: Self.lowestValue))
        for service in shown {
            menu.addItem(item(service.displayName, #selector(menuBarChosen(_:)), checked: choice == .service(service), value: service.rawValue))
        }

        menu.addItem(.separator())
        menu.addItem(heading("Show"))
        for service in setUpServices() {
            let isShown = shown.contains(service)
            // The last shown service stays: an empty panel is a dead end.
            let isLast = isShown && shown.count == 1
            menu.addItem(item(service.displayName, #selector(serviceToggled(_:)), checked: isShown, enabled: !isLast, value: service.rawValue))
        }

        menu.addItem(.separator())
        menu.addItem(item("Open at Login", #selector(openAtLoginChosen), checked: isOpenAtLoginEnabled()))
        switch state {
        case .signedIn, .sessionExpired, .noChatOrg:
            menu.addItem(item("Sign Out of Claude", #selector(signOutChosen)))
        case .unknown, .unreachable, .signedOut, .signingIn:
            break
        }
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private static let lowestValue = "lowest"

    private func heading(_ title: String) -> NSMenuItem {
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        return heading
    }

    private func item(_ title: String, _ action: Selector, checked: Bool = false, enabled: Bool = true, value: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.isEnabled = enabled
        item.representedObject = value
        return item
    }

    // MARK: - Actions

    @objc private func moreTapped(_ sender: NSButton) {
        // The menu drops just below the dots, its right edge in line with theirs, so it stays under the popover.
        let menu = makeMoreMenu()
        let x = sender.bounds.maxX - Self.dotsOverhang - menu.size.width
        let y = sender.isFlipped ? sender.bounds.maxY + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: sender)
    }

    @objc private func refreshChosen() { onRefresh?() }

    @objc private func menuBarChosen(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String else { return }
        if value == Self.lowestValue {
            onChooseMenuBar?(.lowest)
        } else if let service = ServiceID(rawValue: value) {
            onChooseMenuBar?(.service(service))
        }
    }

    @objc private func serviceToggled(_ item: NSMenuItem) {
        guard let value = item.representedObject as? String, let service = ServiceID(rawValue: value) else { return }
        let shown = shownServices()
        if shown == [service] { return }   // the last shown service stays
        onToggleService?(service)
    }

    @objc private func openAtLoginChosen() { onToggleOpenAtLogin?() }
    @objc private func signOutChosen() { onSignOut?() }

    @objc private func browserTapped() { onSignInBrowser?() }
    @objc private func claudeCodeTapped() { onUseClaudeCode?() }
    @objc private func insideAppTapped() { onSignInInsideApp?() }
    @objc private func cancelTapped() { onCancelSignIn?() }

    // MARK: - Read-only state (for tests and diagnostics)

    private var sectionViews: [ServiceSectionView] { sectionsStack.arrangedSubviews.compactMap { $0 as? ServiceSectionView } }
    func sectionView(for service: ServiceID) -> ServiceSectionView? { sectionViews.first { $0.service == service } }

    var headerTitle: String { titleLabel.stringValue }
    var sectionServices: [ServiceID] { sectionViews.map(\.service) }
    func rows(for service: ServiceID) -> [[String]] { sectionView(for: service)?.rowTexts ?? [] }
    func rowToolTips(for service: ServiceID) -> [String?] { sectionView(for: service)?.rowToolTips ?? [] }
    func rowVoiceOverTexts(for service: ServiceID) -> [String?] { sectionView(for: service)?.rowVoiceOverTexts ?? [] }
    func rowPercentColors(for service: ServiceID) -> [NSColor] { sectionView(for: service)?.rowPercentColors ?? [] }
    func note(for service: ServiceID) -> String? { sectionView(for: service)?.noteText }
    func noteColor(for service: ServiceID) -> NSColor? { sectionView(for: service)?.noteColor }
    func iconToolTip(for service: ServiceID) -> String? { sectionView(for: service)?.iconToolTip }
    func iconImage(for service: ServiceID) -> NSImage? { sectionView(for: service)?.icon }
    func isDimmed(_ service: ServiceID) -> Bool { sectionView(for: service)?.isDimmed ?? false }
    func iconFrame(for service: ServiceID) -> NSRect? { sectionView(for: service)?.iconFrame(in: view) }
    func rowEdges(for service: ServiceID) -> [PanelRowEdges] { sectionView(for: service)?.rowEdges(in: view) ?? [] }
    var visibleSignInButtons: [String] { sectionView(for: .claude)?.signInButtonTitles ?? [] }
    var emptyTitle: String { sectionView(for: .claude)?.promptTitle ?? "" }
    var emptySubtitle: String { sectionView(for: .claude)?.promptSubtitle ?? "" }
    var statusText: String { statusLabel.stringValue }
    var isShowingSpinner: Bool { !spinner.isHidden }
    var footerFrames: (status: NSRect, version: NSRect) {
        func rect(_ field: NSTextField) -> NSRect { view.convert(field.alignmentRect(forFrame: field.frame), from: field.superview) }
        return (rect(statusLabel), rect(versionLabel))
    }
    var moreButtonFrame: NSRect { view.convert(moreButton.frame, from: moreButton.superview) }
}
