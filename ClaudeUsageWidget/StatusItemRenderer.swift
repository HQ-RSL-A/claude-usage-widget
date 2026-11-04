import AppKit

/// What the renderer writes to: the status item's button in the app, a fake in tests.
@MainActor
protocol StatusItemDisplay: AnyObject {
    var image: NSImage? { get set }
    var attributedTitle: NSAttributedString { get set }
    var appearsDisabled: Bool { get set }
    var toolTip: String? { get set }
    func setAccessibilityValue(_ value: Any?)
}

extension NSStatusBarButton: StatusItemDisplay {}

/// Applies a StatusPresentation to the menu bar item, touching only what changed. Every new image makes
/// macOS redraw the item on every display, so re-applying the same picture must cost nothing.
@MainActor
final class StatusItemRenderer {
    /// What the image is made of: a new number, a dimmed item or a new tooltip does not make a new picture.
    private struct Picture: Equatable {
        var logo: ServiceID
        var badge: RingColorState
    }

    private let display: StatusItemDisplay
    private var appliedPicture: Picture?
    private var appliedTitle: String?
    private var appliedDimmed: Bool?
    private var appliedToolTip: String?
    private var appliedAccessibilityValue: String?

    init(display: StatusItemDisplay) {
        self.display = display
    }

    func render(_ presentation: StatusPresentation) {
        let content = presentation.content
        let picture = Picture(logo: content.logo, badge: content.badge)
        if picture != appliedPicture {
            display.image = StatusIcon.image(for: content)
            appliedPicture = picture
        }
        if content.title != appliedTitle {
            display.attributedTitle = StatusIcon.attributedTitle(content.title)
            appliedTitle = content.title
        }
        if content.isDimmed != appliedDimmed {
            display.appearsDisabled = content.isDimmed
            appliedDimmed = content.isDimmed
        }
        if presentation.toolTip != appliedToolTip {
            display.toolTip = presentation.toolTip
            appliedToolTip = presentation.toolTip
        }
        if presentation.accessibilityValue != appliedAccessibilityValue {
            display.setAccessibilityValue(presentation.accessibilityValue)
            appliedAccessibilityValue = presentation.accessibilityValue
        }
    }
}
