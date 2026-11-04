import AppKit

// MARK: - ServiceIcon

/// The logo of each service: a small mark for the menu bar and the Mac app's own icon for the panel.
enum ServiceIcon {
    static let menuBarSize = NSSize(width: 16, height: 16)
    static let panelSize = NSSize(width: 28, height: 28)

    /// The service's mark for the menu bar, from the asset catalog. A template image, so the system tints it
    /// like every other menu bar icon.
    static func menuBarMark(for service: ServiceID) -> NSImage {
        let mark = NSImage(named: service.markAssetName)?.copy() as? NSImage ?? NSImage()
        mark.size = menuBarSize
        mark.isTemplate = true
        return mark
    }

    /// The icon of the service's Mac app, found by its bundle id. Without the app, a tile in the service's color
    /// with its mark in white.
    static func panelIcon(for service: ServiceID,
                          appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> NSImage {
        guard let url = appURL(service.bundleIdentifier) else { return tile(for: service) }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = panelSize
        return icon
    }

    // MARK: - Tile

    /// The macOS icon grid: an app icon's rounded square is 824 of its 1024 canvas. The tile keeps that margin
    /// so it sits at the same size as the real icons beside it.
    private static let tileScale: CGFloat = 824.0 / 1024.0
    private static let tileCornerRadius: CGFloat = 0.22   // of the tile's side
    private static let tileMarkScale: CGFloat = 0.6       // of the tile's side

    private static func tile(for service: ServiceID) -> NSImage {
        let mark = menuBarMark(for: service)
        return NSImage(size: panelSize, flipped: false) { canvas in
            let side = canvas.width * tileScale
            let tile = NSRect(x: canvas.midX - side / 2, y: canvas.midY - side / 2, width: side, height: side)
            service.tileColor.setFill()
            continuousRoundedSquare(in: tile, cornerRadius: side * tileCornerRadius).fill()
            drawInWhite(mark, in: tile.insetBy(dx: side * (1 - tileMarkScale) / 2, dy: side * (1 - tileMarkScale) / 2))
            return true
        }
    }

    /// A template image drawn white. It is composed in a layer of its own, so the white lands only on the glyph
    /// and never on the tile behind it.
    private static func drawInWhite(_ template: NSImage, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        template.draw(in: rect)
        NSColor.white.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
    }

    /// A rounded square with continuous corners, the shape of a macOS app icon. A plain rounded corner jumps from
    /// the straight edge to a circular arc; this one eases into the arc and out of it again (Figma's corner
    /// smoothing at 60%, figma.com/blog/desperately-seeking-squircles), so a corner starts 1.6 radii from its
    /// corner point instead of 1.
    private static func continuousRoundedSquare(in rect: NSRect, cornerRadius r: CGFloat) -> NSBezierPath {
        let smoothing: CGFloat = 0.6
        let reach = (1 + smoothing) * r                        // from the corner point to where the corner starts
        let arcAngle = (.pi / 2) * (1 - smoothing)             // only the middle of the corner is a true circular arc
        let arcRun = r * 2.0.squareRoot() * sin(arcAngle / 2)  // the arc's run along each axis
        let lean = (.pi / 4) * smoothing                       // how far the edge has turned where the arc starts
        let c = r * tan(lean / 2) * cos(lean)                  // the end of the opening curve: c along, d across
        let d = c * tan(lean)
        let b = (reach - arcRun - c - d) / 3                   // what is left of the reach, shared by its control points
        let a = 2 * b
        let arcHandle = (4.0 / 3.0) * tan(arcAngle / 4) * r    // one cubic stands in for the arc

        // The top right corner, with the square's center as the origin. `u` runs along the top edge toward the
        // corner point, `v` runs down from the top edge.
        let half = rect.width / 2
        func topRight(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: half - reach + u, y: half - v) }
        let arcStart = topRight(a + b + c, d)
        let arcEnd = topRight(a + b + c + arcRun, d + arcRun)
        let closingU = a + b + c + arcRun + d                  // the closing curve mirrors the opening one
        let curves: [(control1: CGPoint, control2: CGPoint, end: CGPoint)] = [
            (topRight(a, 0), topRight(a + b, 0), arcStart),
            (CGPoint(x: arcStart.x + arcHandle * cos(lean), y: arcStart.y - arcHandle * sin(lean)),
             CGPoint(x: arcEnd.x - arcHandle * sin(lean), y: arcEnd.y + arcHandle * cos(lean)),
             arcEnd),
            (topRight(closingU, d + arcRun + c), topRight(closingU, d + arcRun + b + c), topRight(reach, reach)),
        ]

        // The other corners are this one turned a quarter at a time.
        func place(_ point: CGPoint, quarterTurns: Int) -> CGPoint {
            var p = point
            for _ in 0..<quarterTurns { p = CGPoint(x: p.y, y: -p.x) }
            return CGPoint(x: p.x + rect.midX, y: p.y + rect.midY)
        }
        let path = NSBezierPath()
        for turns in 0..<4 {
            let start = place(topRight(0, 0), quarterTurns: turns)
            if turns == 0 { path.move(to: start) } else { path.line(to: start) }
            for curve in curves {
                path.curve(to: place(curve.end, quarterTurns: turns),
                           controlPoint1: place(curve.control1, quarterTurns: turns),
                           controlPoint2: place(curve.control2, quarterTurns: turns))
            }
        }
        path.close()
        return path
    }
}

// MARK: - Per-service look

private extension ServiceID {
    /// The image set in the asset catalog that holds the service's menu bar mark.
    var markAssetName: String {
        switch self {
        case .claude: return "MenuBarClaude"
        case .grokBot: return "MenuBarGrokBot"
        case .codex: return "MenuBarCodex"
        }
    }

    /// The color behind the mark when the service's app isn't installed.
    var tileColor: NSColor {
        switch self {
        case .claude: return NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        case .grokBot, .codex: return .black
        }
    }
}
