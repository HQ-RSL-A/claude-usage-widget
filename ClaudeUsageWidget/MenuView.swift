import AppKit

// MARK: - ProgressBarView

/// Custom thin progress bar drawn with Core Graphics. 4pt tall, 2pt corner radius.
/// Color adapts based on usage threshold (normal/amber/critical).
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
        let fillColor: NSColor = {
            switch colorState {
            case .normal: return .labelColor
            case .amber: return NSColor(red: 245/255, green: 158/255, blue: 11/255, alpha: 1)
            case .critical: return NSColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)
            }
        }()

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
    private let resetLabel: NSTextField

    init(label: String) {
        nameLabel = NSTextField(labelWithString: label)
        progressBar = ProgressBarView()
        percentLabel = NSTextField(labelWithString: "—%")
        resetLabel = NSTextField(labelWithString: "—")
        super.init(frame: .zero)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupUI() {
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        percentLabel.textColor = .labelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        resetLabel.font = .systemFont(ofSize: 10, weight: .regular)
        resetLabel.textColor = .tertiaryLabelColor
        resetLabel.translatesAutoresizingMaskIntoConstraints = false

        // Top row: name + percent
        let topRow = NSStackView(views: [nameLabel, percentLabel])
        topRow.orientation = .horizontal
        topRow.alignment = .lastBaseline
        topRow.distribution = .fill
        topRow.translatesAutoresizingMaskIntoConstraints = false

        // Main stack: top row, progress bar, reset label
        let stack = NSStackView(views: [topRow, progressBar, resetLabel])
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

    func update(percent: Double, colorState: RingColorState, detail: String) {
        progressBar.progress = percent
        progressBar.colorState = colorState
        percentLabel.stringValue = String(format: "%.0f%%", percent * 100)
        resetLabel.stringValue = detail
    }

    func update(bucket: UsageBucket) {
        let detail = bucket.kind.isWeekly ? (bucket.resetsAtDisplay ?? "—") : bucket.resetsInDisplay
        update(percent: bucket.percentUsed, colorState: bucket.barColorState, detail: detail)
    }
}

// MARK: - MenuViewController

class MenuViewController: NSViewController {

    // Callbacks set by AppDelegate
    var onRefresh: (() -> Void)?
    var onSignOut: (() -> Void)?
    var onSignIn: (() -> Void)?
    var onToggleMode: ((RingMetricMode) -> Void)?

    // MARK: - State

    private var isSignedIn: Bool = true

    // MARK: - UI Elements

    private let titleLabel = NSTextField(labelWithString: "Claude Usage")
    private let refreshButton = RefreshButton(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    private let segmentedControl = NSSegmentedControl()
    private let rowsStack = NSStackView()
    private let lastUpdatedLabel = NSTextField(labelWithString: "Last updated: —")
    private let authButton = NSButton(title: "Sign Out", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    private let separator = NSBox()
    private let versionLabel = NSTextField(labelWithString: "v" + MenuViewController.appVersion)

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

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

    private func setupUI() {
        // Title
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        // Refresh button
        refreshButton.onRefresh = { [weak self] in self?.onRefresh?() }
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.setContentHuggingPriority(.required, for: .horizontal)

        // Header row
        let headerRow = NSStackView(views: [titleLabel, refreshButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        // Segmented control
        segmentedControl.segmentCount = 2
        segmentedControl.setLabel("Session", forSegment: 0)
        segmentedControl.setLabel("Weekly", forSegment: 1)
        segmentedControl.segmentStyle = .rounded
        segmentedControl.selectedSegment = (RingMetricMode.saved == .session) ? 0 : 1
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.controlSize = .small
        segmentedControl.font = .systemFont(ofSize: 11, weight: .medium)

        // Usage rows (rebuilt from data on every update)
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // Last updated
        lastUpdatedLabel.font = .systemFont(ofSize: 10, weight: .regular)
        lastUpdatedLabel.textColor = .tertiaryLabelColor
        lastUpdatedLabel.translatesAutoresizingMaskIntoConstraints = false

        // Usage stack (visible when signed in)
        usageStack = NSStackView(views: [
            segmentedControl,
            rowsStack,
            lastUpdatedLabel,
        ])
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

        // Auth button (Sign Out / Sign In)
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
        segmentedControl.widthAnchor.constraint(equalTo: usageStack.widthAnchor).isActive = true
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

        let titleLabel = NSTextField(labelWithString: "Not signed in")
        titleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let subtitleLabel = NSTextField(labelWithString: "Sign in to see your usage")
        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [ringSymbol, titleLabel, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        ])

        return container
    }

    // MARK: - Public Update Methods

    func update(with data: UsageData) {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for bucket in data.buckets {
            let row = UsageRowView(label: bucket.kind.label)
            row.update(bucket: bucket)
            addRow(row)
        }
        if let extra = data.extraUsage, extra.isEnabled, let percent = extra.percentUsed {
            let row = UsageRowView(label: "Extra usage")
            row.update(percent: percent, colorState: .from(percent: percent), detail: "monthly budget")
            addRow(row)
        }
        if rowsStack.arrangedSubviews.isEmpty {
            let label = NSTextField(labelWithString: "No usage limits reported for this plan")
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            rowsStack.addArrangedSubview(label)
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        lastUpdatedLabel.stringValue = "Updated " + formatter.localizedString(for: data.lastUpdated, relativeTo: Date())
        resizeToFit()
    }

    private func addRow(_ row: UsageRowView) {
        row.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
    }

    /// NSPopover tracks preferredContentSize, so two rows and five rows both fit.
    private func resizeToFit() {
        view.layoutSubtreeIfNeeded()
        preferredContentSize = NSSize(width: 300, height: view.fittingSize.height)
    }

    func updateAuthState(isSignedIn: Bool) {
        self.isSignedIn = isSignedIn
        // View may not be loaded yet (popover is lazy) — applyAuthState runs in viewDidLoad
        guard isViewLoaded else { return }
        applyAuthState()
    }

    private func applyAuthState() {
        usageStack.isHidden = !isSignedIn
        emptyStateView.isHidden = isSignedIn
        refreshButton.isEnabled = isSignedIn

        if isSignedIn {
            authButton.title = "Sign Out"
            authButton.contentTintColor = .secondaryLabelColor
            authButton.font = .systemFont(ofSize: 11, weight: .regular)
        } else {
            authButton.title = "Sign In"
            authButton.contentTintColor = .labelColor
            authButton.font = .systemFont(ofSize: 11, weight: .medium)
        }
        resizeToFit()
    }

    func showLoading() {
        lastUpdatedLabel.stringValue = "Fetching usage..."
    }

    func showError(_ message: String) {
        lastUpdatedLabel.stringValue = "Error: \(message)"
    }

    // MARK: - Actions

    @objc private func segmentChanged() {
        let mode: RingMetricMode = segmentedControl.selectedSegment == 0 ? .session : .weekly
        mode.save()
        onToggleMode?(mode)
    }

    @objc private func authTapped() {
        if isSignedIn {
            onSignOut?()
        } else {
            onSignIn?()
        }
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }
}
