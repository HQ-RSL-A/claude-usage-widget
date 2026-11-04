import XCTest
import AppKit
@testable import ClaudeUsageWidget

final class ServiceIconTests: XCTestCase {

    private let menuBarSize = NSSize(width: 16, height: 16)
    private let panelSize = NSSize(width: 28, height: 28)

    // MARK: - Menu bar marks

    /// Every service has its mark in the asset catalog: 16 pt, and a template, so the system tints it like every
    /// other menu bar icon.
    func testMenuBarMarksExistAndAreTemplates() {
        for service in ServiceID.allCases {
            let mark = ServiceIcon.menuBarMark(for: service)
            XCTAssertFalse(mark.representations.isEmpty, "\(service) has an image in the asset catalog")
            XCTAssertEqual(mark.size, menuBarSize, "\(service) size")
            XCTAssertTrue(mark.isTemplate, "\(service) is a template")
        }
        // The catalog itself says so too (template-rendering-intent in each Contents.json).
        for name in ["MenuBarClaude", "MenuBarGrokBot", "MenuBarCodex"] {
            XCTAssertEqual(NSImage(named: name)?.isTemplate, true, "\(name) is a template in the asset catalog")
        }
    }

    /// What each mark looks like, in the 24 x 24 units its drawing uses: how much of the square is ink, and
    /// points where it has ink and where it is cut out (Grok Bot's eyes, Codex's prompt). A path the renderer
    /// misreads changes these: CoreSVG drew the original Codex logo at 49% instead of 70% because of its arcs.
    private let looks: [ServiceID: (coverage: Double, ink: [(Double, Double)], cutouts: [(Double, Double)])] = [
        .claude: (0.40, ink: [(12, 12), (7, 3.4)], cutouts: [(3, 3), (21, 21)]),
        .grokBot: (0.51, ink: [(12, 12), (12, 4)], cutouts: [(9.5, 11), (14.5, 11)]),
        .codex: (0.70, ink: [(12, 12), (12, 5)], cutouts: [(8, 12), (15.5, 15.4)]),
    ]

    func testMenuBarMarksDrawAsIntended() {
        var shapes: [[UInt8]] = []
        for service in ServiceID.allCases {
            let raster = Raster(ServiceIcon.menuBarMark(for: service))
            let look = looks[service]!
            XCTAssertEqual(raster.coverage, look.coverage, accuracy: 0.05, "\(service): how much of the square is ink")
            for (x, y) in look.ink {
                XCTAssertGreaterThan(raster.alpha(unitX: x, unitY: y), 240, "\(service): ink at (\(x), \(y))")
            }
            for (x, y) in look.cutouts {
                // Mostly clear, not exactly: a probe near the edge of a cutout reads a little ink from antialiasing
                // (Codex's chevron reads 11 here), and another Xcode's rasters read a little more. A real cutout that
                // had filled in would read 255, and the underscore probe proves the cutout on its own.
                XCTAssertLessThan(raster.alpha(unitX: x, unitY: y), 64, "\(service): clear at (\(x), \(y))")
            }
            shapes.append(raster.alphaBytes)
        }
        XCTAssertEqual(Set(shapes).count, ServiceID.allCases.count, "each service has its own mark")
    }

    // MARK: - Panel icon

    func testPanelIconUsesInstalledApp() {
        let calculator = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        var asked: [String] = []
        let icon = ServiceIcon.panelIcon(for: .grokBot) { bundleID in
            asked.append(bundleID)
            return calculator
        }
        XCTAssertEqual(asked, [ServiceID.grokBot.bundleIdentifier], "the app is found by the service's bundle id")
        XCTAssertEqual(icon.size, panelSize)
        XCTAssertFalse(icon.isTemplate)

        let expected = NSWorkspace.shared.icon(forFile: calculator.path)
        expected.size = panelSize
        XCTAssertNotNil(icon.tiffRepresentation)
        XCTAssertEqual(icon.tiffRepresentation, expected.tiffRepresentation, "the app's own icon, at 28 pt")
    }

    /// Without the app, the panel draws a tile: a rounded square in the service's color with its mark in white.
    func testPanelIconFallbackWhenAppMissing() {
        let background: [ServiceID: (r: UInt8, g: UInt8, b: UInt8)] = [
            .claude: (0xD9, 0x77, 0x57),
            .grokBot: (0x00, 0x00, 0x00),
            .codex: (0x00, 0x00, 0x00),
        ]
        for service in ServiceID.allCases {
            let icon = ServiceIcon.panelIcon(for: service) { _ in nil }
            XCTAssertEqual(icon.size, panelSize, "\(service) size")
            XCTAssertFalse(icon.isTemplate, "\(service): the tile keeps its own colors")

            let raster = Raster(icon)   // 56 x 56 px
            assertColor(raster.pixel(x: 28, y: 28), (0xFF, 0xFF, 0xFF), "\(service): the mark is white in the middle")
            // 12 px in from the corner is inside the rounded corner and clear of the mark.
            assertColor(raster.pixel(x: 12, y: 12), background[service]!, "\(service): the tile's color")
            assertColor(raster.pixel(x: 43, y: 43), background[service]!, "\(service): the tile's color, opposite corner")
            // The corner of the mark's own square is empty, so the tile shows there: the white is on the glyph only.
            assertColor(raster.pixel(x: 16, y: 16), background[service]!, "\(service): the tile's color inside the mark's square")
            XCTAssertEqual(raster.pixel(x: 0, y: 0).a, 0, "\(service): the canvas corner is clear")
        }
    }

    /// A real app icon keeps a margin inside its canvas (the body is 824 of 1024), so the tile does the same
    /// and sits at the same size as the real icons beside it in the panel.
    func testFallbackTileKeepsTheMarginOfARealAppIcon() {
        let raster = Raster(ServiceIcon.panelIcon(for: .codex) { _ in nil })
        XCTAssertEqual(raster.pixel(x: 28, y: 2).a, 0, "clear above the tile")
        XCTAssertEqual(raster.pixel(x: 2, y: 28).a, 0, "clear left of the tile")
        XCTAssertEqual(raster.pixel(x: 28, y: 8).a, 255, "the tile itself")
        XCTAssertEqual(raster.pixel(x: 8, y: 28).a, 255, "the tile itself")
    }

    /// The mark is 60% of the tile. Grok Bot's mark is a circle 20 of 24 across, so on the middle row its white
    /// runs from 0.2 + 0.6 * (2 / 24) to 0.8 - 0.6 * (2 / 24) of the way across the tile (the 22.5 pt body).
    func testFallbackMarkIsSixtyPercentOfTheTile() {
        let raster = Raster(ServiceIcon.panelIcon(for: .grokBot) { _ in nil })
        let white = (0..<raster.width).filter { raster.pixel(x: $0, y: raster.height / 2).r > 127 }
        let body = Double(raster.width) * 824 / 1024, origin = (Double(raster.width) - body) / 2
        let expectedLeft = origin + body * (0.2 + 0.6 * 2 / 24)
        let expectedRight = origin + body * (0.8 - 0.6 * 2 / 24)
        XCTAssertEqual(Double(white.first ?? -1), expectedLeft, accuracy: 1.5)
        XCTAssertEqual(Double(white.last ?? -1) + 1, expectedRight, accuracy: 1.5)
    }

    // MARK: - Panel icon cache

    /// `NSWorkspace` icons carry about 32 representations up to 2048 px, and the panel asks for each one every time
    /// it is redrawn. Each service is looked up once, and every later ask gets the same image.
    func testPanelIconsAreLookedUpOncePerService() {
        var asked: [ServiceID] = []
        let cache = PanelIconCache { service in
            asked.append(service)
            return NSImage(size: NSSize(width: 28, height: 28))
        }
        let claude = cache.icon(for: .claude)
        XCTAssertTrue(cache.icon(for: .claude) === claude, "the same image, not a new lookup")
        let grokBot = cache.icon(for: .grokBot)
        XCTAssertFalse(grokBot === claude, "one image per service")
        XCTAssertTrue(cache.icon(for: .grokBot) === grokBot)
        XCTAssertTrue(cache.icon(for: .claude) === claude)
        XCTAssertEqual(asked, [.claude, .grokBot])
    }

    /// The app's own cache looks icons up the way `panelIcon(for:)` does: through the Mac's installed apps.
    func testTheSharedCacheHandsOutTheSameIconEveryTime() {
        for service in ServiceID.allCases {
            let icon = ServiceIcon.panelIcons.icon(for: service)
            XCTAssertEqual(icon.size, panelSize, "\(service)")
            XCTAssertTrue(ServiceIcon.panelIcons.icon(for: service) === icon, "\(service)")
        }
    }

    // MARK: - Helpers

    private func assertColor(_ pixel: Raster.Pixel, _ expected: (r: UInt8, g: UInt8, b: UInt8), _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pixel.a, 255, "\(message): opaque", file: file, line: line)
        XCTAssertEqual(Int(pixel.r), Int(expected.r), accuracy: 1, "\(message): red", file: file, line: line)
        XCTAssertEqual(Int(pixel.g), Int(expected.g), accuracy: 1, "\(message): green", file: file, line: line)
        XCTAssertEqual(Int(pixel.b), Int(expected.b), accuracy: 1, "\(message): blue", file: file, line: line)
    }
}

/// An image drawn the way a Retina screen draws it (2x, sRGB), so a test can read real pixels. Rows count from the top.
private struct Raster {
    typealias Pixel = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    let width: Int
    let height: Int
    private let bytes: [UInt8]   // premultiplied RGBA, top row first

    init(_ image: NSImage) {
        width = Int(image.size.width) * 2
        height = Int(image.size.height) * 2
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        bytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }

    func pixel(x: Int, y: Int) -> Pixel {
        let i = (y * width + x) * 4
        return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
    }

    var alphaBytes: [UInt8] { stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } }

    /// The opacity at a point of a drawing that is 24 units across, such as the SVG marks.
    func alpha(unitX: Double, unitY: Double) -> UInt8 {
        pixel(x: Int(unitX / 24 * Double(width)), y: Int(unitY / 24 * Double(height))).a
    }

    /// The share of the image that is mostly opaque.
    var coverage: Double {
        Double(alphaBytes.filter { $0 > 127 }.count) / Double(width * height)
    }
}
