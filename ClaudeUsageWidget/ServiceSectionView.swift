import AppKit

// MARK: - PanelMetrics

/// The panel's measurements, in points. Every section reads the same ones, so the columns line up.
enum PanelMetrics {
    static let width: CGFloat = 320
    static let margin: CGFloat = 14
    static let iconSide: CGFloat = 28
    static let iconGap: CGFloat = 12
    /// The two number columns have fixed widths and sit against the right margin: what's left, then when it resets.
    static let percentWidth: CGFloat = 38
    static let resetWidth: CGFloat = 64
    static let columnGap: CGFloat = 6
    static let rowSpacing: CGFloat = 6
    /// Between a section's last row and the note under it, and between a sign-in's title and its subtitle and buttons.
    static let noteGap: CGFloat = 4
    static let titleGap: CGFloat = 2
    static let buttonsGap: CGFloat = 10
    /// Out-of-date numbers are drawn this faint.
    static let dimmedAlpha: CGFloat = 0.5

    static var contentWidth: CGFloat { width - 2 * margin }
    /// What is left of the content once the icon and its gap are taken: the rows, notes and buttons.
    static var textWidth: CGFloat { contentWidth - iconSide - iconGap }
}

// MARK: - PanelColors

/// The colors of what's left in a row. The menu bar's amber (#F59E0B) and red (#EF4444) are right on a dark panel but
/// only about 2:1 against a light one, too faint for a number (Rahul's rule: colored digits must not get lost). So the
/// light panel gets a darker pair, picked while drawing, from the appearance the number is drawn in. The menu bar keeps
/// its own colors (`StatusIcon.color`).
enum PanelColors {
    /// Under 60% used the number is plain text; from 60% it is amber and from 85% red.
    static func percent(for state: RingColorState) -> NSColor {
        switch state {
        case .normal: return .labelColor
        case .amber: return amber
        case .critical: return red
        }
    }

    private static let amber = dynamic(light: (0xB4, 0x53, 0x09), dark: (0xF5, 0x9E, 0x0B))   // #B45309 and #F59E0B
    private static let red = dynamic(light: (0xDC, 0x26, 0x26), dark: (0xEF, 0x44, 0x44))     // #DC2626 and #EF4444

    private static func dynamic(light: (Int, Int, Int), dark: (Int, Int, Int)) -> NSColor {
        func color(_ rgb: (Int, Int, Int)) -> NSColor {
            NSColor(srgbRed: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255, blue: CGFloat(rgb.2) / 255, alpha: 1)
        }
        let (lightColor, darkColor) = (color(light), color(dark))
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}

// MARK: - What a section says

/// One limit as a row says it.
struct PanelRow: Equatable {
    var label: String
    /// What's left: "83%".
    var percent: String
    /// "11:10 PM", "Oct 16", or "" when no reset is ahead.
    var reset: String
    var toolTip: String?
    var colorState: RingColorState
}

/// The ways to sign in to Claude. Each is a button inside Claude's section.
enum SignInButton: Equatable {
    case browser
    case claudeCode
    case insideApp
    case cancel

    var title: String {
        switch self {
        case .browser: return "Sign in with your browser"
        case .claudeCode: return "Use Claude Code's sign-in"
        case .insideApp: return "Sign in inside the app"
        case .cancel: return "Cancel"
        }
    }
}

/// What Claude's section says instead of numbers: where the sign-in stands, and the buttons that move it on.
struct SignInPrompt: Equatable {
    var title: String
    var subtitle: String
    var buttons: [SignInButton]
}

/// Everything one section shows, apart from how it looks. The panel is rebuilt only when this changes.
struct PanelSection: Equatable {
    var service: ServiceID
    /// The icon's tooltip.
    var toolTip: String
    var rows: [PanelRow] = []
    /// A quiet line under the rows, or in their place when there are none.
    var note: String?
    var signIn: SignInPrompt?
    /// The numbers are out of date: they stay, dimmed, beside the note that says how old they are.
    var isDimmed = false
}

/// Where a row's columns sit, in the panel's own coordinates. For tests and diagnostics.
struct PanelRowEdges {
    var labelMinX: CGFloat
    var labelMaxX: CGFloat
    var percentMinX: CGFloat
    var percentMaxX: CGFloat
    var resetMinX: CGFloat
    var resetMaxX: CGFloat
    /// Some of the row's text is wider than the room it was given, so it is cut short.
    var isCut: Bool
}

// MARK: - LimitRowView

/// One limit: its name, what's left of it, and when it resets.
final class LimitRowView: NSView {

    private let labelField = NSTextField(labelWithString: "")
    private let percentField = NSTextField(labelWithString: "")
    private let resetField = NSTextField(labelWithString: "")

    init(row: PanelRow) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        labelField.stringValue = row.label
        labelField.font = .systemFont(ofSize: 12)
        labelField.textColor = .secondaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Digits of one width, so a number that changes never moves the ones beside it.
        percentField.stringValue = row.percent
        percentField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        percentField.textColor = PanelColors.percent(for: row.colorState)
        percentField.alignment = .right

        resetField.stringValue = row.reset
        resetField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        resetField.textColor = .secondaryLabelColor
        resetField.alignment = .right

        for (field, width) in [(percentField, PanelMetrics.percentWidth), (resetField, PanelMetrics.resetWidth)] {
            field.setContentCompressionResistancePriority(.required, for: .horizontal)
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }

        let stack = NSStackView(views: [labelField, percentField, resetField])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.distribution = .fill
        stack.spacing = PanelMetrics.columnGap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // The whole row answers to the tooltip, whichever of its words the pointer is over.
        for view in [self, labelField, percentField, resetField] { view.toolTip = row.toolTip }
        // One thing to read, not three: "5hr Session, 92% left, resets Mon Oct 12, 10:00 PM".
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityChildren([])
        setAccessibilityLabel([row.label + ", " + row.percent + " left", row.toolTip].compactMap { $0 }.joined(separator: ", "))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    var texts: [String] { [labelField.stringValue, percentField.stringValue, resetField.stringValue] }
    var voiceOverText: String? { accessibilityLabel() }
    var percentColor: NSColor { percentField.textColor ?? .labelColor }

    /// Text sits at the edge of a field's alignment rect, not of its frame, which is a little wider.
    func edges(in root: NSView) -> PanelRowEdges {
        func rect(_ field: NSTextField) -> NSRect { root.convert(field.alignmentRect(forFrame: field.frame), from: field.superview) }
        let (label, percent, reset) = (rect(labelField), rect(percentField), rect(resetField))
        return PanelRowEdges(labelMinX: label.minX, labelMaxX: label.maxX,
                             percentMinX: percent.minX, percentMaxX: percent.maxX,
                             resetMinX: reset.minX, resetMaxX: reset.maxX,
                             isCut: [labelField, percentField, resetField].contains { $0.intrinsicContentSize.width > $0.frame.width + 0.5 })
    }
}

// MARK: - ServiceSectionView

/// One service: its icon on the left, then its rows. Claude's section can hold the sign-in instead.
final class ServiceSectionView: NSView {

    let service: ServiceID
    let section: PanelSection

    private let iconView = NSImageView()
    private var rowViews: [LimitRowView] = []
    private var noteLabel: NSTextField?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var buttons: [NSButton] = []

    init(section: PanelSection, icon: NSImage, makeButton: (SignInButton) -> NSButton) {
        self.service = section.service
        self.section = section
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = icon
        iconView.isEditable = false   // an image view takes dropped images unless told not to
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.toolTip = section.toolTip
        iconView.setAccessibilityLabel(section.service.displayName)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let content = makeContent(for: section, makeButton: makeButton)

        // The icon stands level with the middle of the first two lines the section says. When those are shorter
        // than the icon the text moves down to meet it; when they are taller the icon moves down to meet them.
        let anchor = firstLinesHeight(of: section)
        let iconOffset = max(0, (anchor - PanelMetrics.iconSide) / 2)
        content.edgeInsets = NSEdgeInsets(top: max(0, (PanelMetrics.iconSide - anchor) / 2), left: 0, bottom: 0, right: 0)

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: holder.topAnchor, constant: iconOffset),
            iconView.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            iconView.widthAnchor.constraint(equalToConstant: PanelMetrics.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: PanelMetrics.iconSide),
            holder.widthAnchor.constraint(equalToConstant: PanelMetrics.iconSide),
            holder.heightAnchor.constraint(equalToConstant: iconOffset + PanelMetrics.iconSide),
        ])

        let layout = NSStackView(views: [holder, content])
        layout.orientation = .horizontal
        layout.alignment = .top
        layout.spacing = PanelMetrics.iconGap
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor),
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.widthAnchor.constraint(equalToConstant: PanelMetrics.textWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    // MARK: - Content

    private func makeContent(for section: PanelSection, makeButton: (SignInButton) -> NSButton) -> NSStackView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = PanelMetrics.rowSpacing
        content.translatesAutoresizingMaskIntoConstraints = false

        if !section.rows.isEmpty {
            let rows = NSStackView()
            rows.orientation = .vertical
            rows.alignment = .leading
            rows.spacing = PanelMetrics.rowSpacing
            rows.translatesAutoresizingMaskIntoConstraints = false
            for row in section.rows {
                let view = LimitRowView(row: row)
                rowViews.append(view)
                rows.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
            rows.alphaValue = section.isDimmed ? PanelMetrics.dimmedAlpha : 1
            content.addArrangedSubview(rows)
            content.setCustomSpacing(PanelMetrics.noteGap, after: rows)
            rows.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        if let note = section.note {
            // Under numbers it is a small aside; on its own it is all the section has to say. Either way it is the
            // secondary label color: the age note says the numbers cannot be trusted, and tertiary text measured
            // 1.9:1 against a light panel.
            let isAside = !section.rows.isEmpty
            let label = Self.wrappingLabel(note, size: isAside ? 10 : 11, color: .secondaryLabelColor)
            noteLabel = label
            content.addArrangedSubview(label)
        }

        if let prompt = section.signIn {
            let title = Self.wrappingLabel(prompt.title, size: 12, color: .labelColor)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            let subtitle = Self.wrappingLabel(prompt.subtitle, size: 11, color: .secondaryLabelColor)
            titleLabel = title
            subtitleLabel = subtitle
            content.addArrangedSubview(title)
            content.setCustomSpacing(PanelMetrics.titleGap, after: title)
            content.addArrangedSubview(subtitle)
            if !prompt.buttons.isEmpty { content.setCustomSpacing(PanelMetrics.buttonsGap, after: subtitle) }
            for kind in prompt.buttons {
                let button = makeButton(kind)
                buttons.append(button)
                content.addArrangedSubview(button)
                // The buttons that do the signing in fill the column; the quiet link stays as wide as its words.
                if button.isBordered { button.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
            }
        }

        return content
    }

    /// How tall the first two lines of the section are, with the space between them: its first two rows, or its
    /// row and the note under it, or its sign-in title and subtitle. A section of one line is just that line.
    private func firstLinesHeight(of section: PanelSection) -> CGFloat {
        let lines: [NSView]
        let gap: CGFloat
        if rowViews.count >= 2 {
            (lines, gap) = ([rowViews[0], rowViews[1]], PanelMetrics.rowSpacing)
        } else if let row = rowViews.first {
            (lines, gap) = ([row] + [noteLabel].compactMap { $0 }, PanelMetrics.noteGap)
        } else if let title = titleLabel {
            (lines, gap) = ([title] + [subtitleLabel].compactMap { $0 }, PanelMetrics.titleGap)
        } else {
            (lines, gap) = ([noteLabel].compactMap { $0 }, 0)
        }
        return lines.map { $0.fittingSize.height }.reduce(0, +) + gap * CGFloat(max(0, lines.count - 1))
    }

    private static func wrappingLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.maximumNumberOfLines = 2
        label.isSelectable = false
        label.preferredMaxLayoutWidth = PanelMetrics.textWidth
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - Read-only state (for tests and diagnostics)

    var rowTexts: [[String]] { rowViews.map(\.texts) }
    var rowToolTips: [String?] { rowViews.map(\.toolTip) }
    var rowVoiceOverTexts: [String?] { rowViews.map(\.voiceOverText) }
    var rowPercentColors: [NSColor] { rowViews.map(\.percentColor) }
    var noteText: String? { noteLabel?.stringValue }
    var noteColor: NSColor? { noteLabel?.textColor }
    var promptTitle: String { titleLabel?.stringValue ?? "" }
    var promptSubtitle: String { subtitleLabel?.stringValue ?? "" }
    var signInButtonTitles: [String] { buttons.map(\.title) }
    var iconToolTip: String? { iconView.toolTip }
    var icon: NSImage? { iconView.image }
    var isDimmed: Bool { section.isDimmed }
    func iconFrame(in root: NSView) -> NSRect { iconView.convert(iconView.bounds, to: root) }
    func rowEdges(in root: NSView) -> [PanelRowEdges] { rowViews.map { $0.edges(in: root) } }
}
