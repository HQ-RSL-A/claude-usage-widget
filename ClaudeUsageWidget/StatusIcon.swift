import AppKit

/// Draws the menu bar item's picture and fixes its size. The picture is the service's mark; a badge dot on it
/// turns amber or red when that limit is running low. The title beside it is the menu bar's own text.
enum StatusIcon {
    /// The room the item keeps: between the mark and the title, and around the two of them.
    private static let titleGap: CGFloat = 4
    private static let sidePadding: CGFloat = 12
    /// The longest title there is, so the item is wide enough for every number.
    private static let widestTitle = "100% remain"

    private static let badgeDiameter: CGFloat = 6
    private static let badgeCenter = CGPoint(x: 13, y: 13)   // in the 16 pt mark, counted from the bottom left
    private static let badgeClearance: CGFloat = 1.5         // the ring cut clear around the dot

    // MARK: - Button

    /// VoiceOver reads the item as "Usage Remaining", its value being the limit it shows. It is not named after Claude:
    /// the item shows whichever service is lowest.
    static let accessibilityLabel = "Usage Remaining"

    /// How the status item's button lays out its mark and title. The logo leads the title, and the text starts at the
    /// left: with the padded title (`attributedTitle`), the logo and the number then stay put whatever is shown.
    static func configure(_ button: NSButton) {
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = titleFont()
        button.setAccessibilityLabel(accessibilityLabel)
    }

    // MARK: - Size and font

    /// The menu bar's own size, with every digit the same width so the number never jiggles as it changes.
    static func titleFont() -> NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// One width for every title, so the menu bar never shifts as the numbers change.
    static func itemLength() -> CGFloat {
        ceil(ServiceIcon.menuBarSize.width + titleGap + widestTitleWidth() + sidePadding)
    }

    /// The title in the menu bar's font, and no color: the menu bar colors its own text. The status button centers
    /// what it holds, so a shorter title would slide the logo and the number along with it. Digit wide spaces after
    /// the title make every title as wide as the widest; with the button's text aligned left, the logo and the
    /// number then start in the same place whatever is shown.
    static func attributedTitle(_ title: String) -> NSAttributedString {
        let font = titleFont()
        let shortfall = widestTitleWidth() - NSAttributedString(string: title, attributes: [.font: font]).size().width
        let digitWidth = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        let padding = String(repeating: "\u{2007}", count: max(0, Int((shortfall / digitWidth).rounded())))   // figure space
        return NSAttributedString(string: title + padding, attributes: [.font: font])
    }

    private static func widestTitleWidth() -> CGFloat {
        NSAttributedString(string: widestTitle, attributes: [.font: titleFont()]).size().width
    }

    // MARK: - Image

    /// The service's mark. With no badge it is the plain template, tinted by the system like every other menu bar
    /// icon. A colored dot cannot be tinted, so with a badge the image is not a template: its mark takes the menu
    /// bar's color, picked while drawing. macOS draws the item once per display, each in that menu bar's
    /// appearance, so one image is right everywhere and nothing has to watch the appearance.
    static func image(for content: StatusItemContent) -> NSImage {
        let mark = ServiceIcon.menuBarMark(for: content.logo)
        guard content.badge != .normal else { return mark }

        let image = NSImage(size: ServiceIcon.menuBarSize, flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let foreground = foregroundColor(for: NSAppearance.currentDrawing())
            let dot = CGRect(x: badgeCenter.x - badgeDiameter / 2, y: badgeCenter.y - badgeDiameter / 2, width: badgeDiameter, height: badgeDiameter)

            // The mark in the menu bar's color, with the ring around the dot cut out of it. Done in a layer of its
            // own, so the color lands on the glyph only and the cut takes nothing but the glyph.
            context.beginTransparencyLayer(in: bounds, auxiliaryInfo: nil)
            mark.draw(in: bounds)
            foreground.setFill()
            bounds.fill(using: .sourceAtop)
            context.saveGState()
            context.setBlendMode(.clear)
            context.fillEllipse(in: dot.insetBy(dx: -badgeClearance, dy: -badgeClearance))
            context.restoreGState()
            context.endTransparencyLayer()

            color(for: content.badge, foreground: foreground).setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.cacheMode = .never   // a cached drawing would carry one display's color onto the other
        return image
    }

    /// White on a dark menu bar, black on a light one.
    private static func foregroundColor(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .black
    }

    static func color(for state: RingColorState, foreground: NSColor) -> NSColor {
        switch state {
        case .normal: return foreground
        case .amber: return NSColor(red: 245/255, green: 158/255, blue: 11/255, alpha: 1)
        case .critical: return NSColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)
        }
    }
}
