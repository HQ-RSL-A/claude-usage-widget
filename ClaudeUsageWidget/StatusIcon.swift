import AppKit

// MARK: - StatusIconModel

/// What the menu bar item shows: one or two rings, each filled by what's used, with what's left as the number inside.
struct StatusIconModel: Equatable {
    enum Ring: Equatable {
        case usage(left: Int, used: Double, color: RingColorState)
        case noData
    }

    var rings: [Ring]
    /// Signed out, no numbers yet, or numbers too old to trust.
    var isDimmed: Bool

    /// A template image is tinted by the system like every other menu bar icon; amber and red must keep their color.
    var isTemplate: Bool {
        !rings.contains { ring in
            if case .usage(_, _, let color) = ring { return color != .normal }
            return false
        }
    }
}

// MARK: - StatusIcon

/// Draws a StatusIconModel for the status item. Sizes are in points. The width depends only on how many
/// rings there are, never on the numbers, so the menu bar never shifts as usage changes.
enum StatusIcon {
    static let slot: CGFloat = 20
    static let gap: CGFloat = 3
    static let radius: CGFloat = 8.6
    static let stroke: CGFloat = 2.0
    static let trackAlpha: CGFloat = 0.25
    static let dimmedAlpha: CGFloat = 0.45

    static func size(for model: StatusIconModel) -> NSSize {
        let count = CGFloat(max(1, model.rings.count))
        return NSSize(width: count * slot + (count - 1) * gap, height: slot)
    }

    /// `darkMenuBar` picks the color of normal rings when the image cannot be a template (any ring amber or red).
    static func image(for model: StatusIconModel, darkMenuBar: Bool) -> NSImage {
        let foreground: NSColor = (model.isTemplate || !darkMenuBar) ? .black : .white
        let image = NSImage(size: size(for: model), flipped: false) { _ in
            for (index, ring) in model.rings.enumerated() {
                let center = CGPoint(x: slot / 2 + CGFloat(index) * (slot + gap), y: slot / 2)
                draw(ring, at: center, foreground: foreground, dimmed: model.isDimmed)
            }
            return true
        }
        image.isTemplate = model.isTemplate
        return image
    }

    // MARK: - Drawing

    private static func draw(_ ring: StatusIconModel.Ring, at center: CGPoint, foreground: NSColor, dimmed: Bool) {
        switch ring {
        case .noData:
            strokeCircle(at: center, color: foreground.withAlphaComponent(trackAlpha))
            let dash = NSBezierPath()
            dash.move(to: CGPoint(x: center.x - 2.5, y: center.y))
            dash.line(to: CGPoint(x: center.x + 2.5, y: center.y))
            dash.lineWidth = 1.6
            dash.lineCapStyle = .round
            foreground.withAlphaComponent(dimmedAlpha).setStroke()
            dash.stroke()

        case .usage(let left, let used, let state):
            let alpha: CGFloat = dimmed ? dimmedAlpha : 1
            let base = color(for: state, foreground: foreground)
            let ringColor = base.withAlphaComponent(alpha)
            strokeCircle(at: center, color: base.withAlphaComponent(alpha * trackAlpha))
            strokeArc(at: center, fraction: used, color: ringColor)
            drawNumber(left, at: center, color: ringColor)
        }
    }

    private static func strokeCircle(at center: CGPoint, color: NSColor) {
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360, clockwise: true)
        track.lineWidth = stroke
        color.setStroke()
        track.stroke()
    }

    /// Clockwise from 12 o'clock. NSBezierPath angles run counter-clockwise from 3 o'clock.
    private static func strokeArc(at center: CGPoint, fraction: Double, color: NSColor) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - clamped * 360, clockwise: true)
        arc.lineWidth = stroke
        arc.lineCapStyle = .round
        color.setStroke()
        arc.stroke()
    }

    private static func drawNumber(_ value: Int, at center: CGPoint, color: NSColor) {
        let digits = String(value)
        let font = numberFont(size: digits.count >= 3 ? 7.5 : 9)
        let text = NSAttributedString(string: digits, attributes: [.font: font, .foregroundColor: color])
        // Center the digits' cap height on the ring; draw(at:) takes the bottom of the line, below the baseline.
        let baseline = center.y - font.capHeight / 2
        text.draw(at: CGPoint(x: center.x - text.size().width / 2, y: baseline + font.descender))
    }

    private static func numberFont(size: CGFloat) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: size) ?? base
    }

    static func color(for state: RingColorState, foreground: NSColor) -> NSColor {
        switch state {
        case .normal: return foreground
        case .amber: return NSColor(red: 245/255, green: 158/255, blue: 11/255, alpha: 1)
        case .critical: return NSColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)
        }
    }
}
