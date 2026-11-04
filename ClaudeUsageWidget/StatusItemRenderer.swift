import AppKit

/// What the renderer writes to: the status item's button in the app, a fake in tests.
@MainActor
protocol StatusItemDisplay: AnyObject {
    var image: NSImage? { get set }
    var toolTip: String? { get set }
    func setAccessibilityValue(_ value: Any?)
}

extension NSStatusBarButton: StatusItemDisplay {}

/// Applies a StatusPresentation to the menu bar item, touching only what changed. Every new image makes
/// macOS redraw the item on every display, so re-applying the same picture must cost nothing.
@MainActor
final class StatusItemRenderer {
    private let display: StatusItemDisplay
    private var appliedIcon: StatusIconModel?
    private var appliedToolTip: String?
    private var appliedAccessibilityValue: String?

    init(display: StatusItemDisplay) {
        self.display = display
    }

    func render(_ presentation: StatusPresentation) {
        if presentation.icon != appliedIcon {
            display.image = StatusIcon.image(for: presentation.icon)
            appliedIcon = presentation.icon
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
