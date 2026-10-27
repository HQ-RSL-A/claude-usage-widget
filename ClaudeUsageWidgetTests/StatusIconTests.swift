import XCTest
@testable import ClaudeUsageWidget

final class StatusIconTests: XCTestCase {

    private let normalAndAmber = StatusIconModel(
        rings: [.usage(left: 50, used: 0.5, color: .normal), .usage(left: 30, used: 0.7, color: .amber)],
        isDimmed: false
    )

    func test_size_dependsOnlyOnRingCount() {
        let extremes = StatusIconModel(rings: [.usage(left: 100, used: 0, color: .normal), .usage(left: 0, used: 1, color: .critical)], isDimmed: false)
        let other = StatusIconModel(rings: [.usage(left: 7, used: 0.93, color: .critical), .noData], isDimmed: true)
        XCTAssertEqual(StatusIcon.size(for: extremes), NSSize(width: 43, height: 20))
        XCTAssertEqual(StatusIcon.size(for: other), StatusIcon.size(for: extremes))
        XCTAssertEqual(StatusIcon.size(for: StatusIconModel(rings: [.noData], isDimmed: true)), NSSize(width: 20, height: 20))
        XCTAssertEqual(StatusIcon.image(for: extremes, darkMenuBar: true).size, NSSize(width: 43, height: 20))
    }

    func test_image_templateOnlyWhenNoRingIsColored() {
        let quiet = StatusIconModel(rings: [.usage(left: 50, used: 0.5, color: .normal), .noData], isDimmed: false)
        XCTAssertTrue(quiet.isTemplate)
        XCTAssertTrue(StatusIcon.image(for: quiet, darkMenuBar: true).isTemplate)
        XCTAssertFalse(normalAndAmber.isTemplate)
        XCTAssertFalse(StatusIcon.image(for: normalAndAmber, darkMenuBar: true).isTemplate)
    }

    /// Not a template once a ring is amber, so the system no longer tints the normal ring: it has to be
    /// drawn in the menu bar's own color, white on a dark menu bar and black on a light one.
    func test_image_mixedColors_drawsNormalRingInMenuBarForeground() {
        let onDark = pixelAtTopOfFirstRing(StatusIcon.image(for: normalAndAmber, darkMenuBar: true))
        XCTAssertGreaterThan(onDark.alphaComponent, 0.8)
        XCTAssertGreaterThan(onDark.brightnessComponent, 0.8)
        let onLight = pixelAtTopOfFirstRing(StatusIcon.image(for: normalAndAmber, darkMenuBar: false))
        XCTAssertGreaterThan(onLight.alphaComponent, 0.8)
        XCTAssertLessThan(onLight.brightnessComponent, 0.2)
    }

    /// Renders at 2x and reads the arc just right of 12 o'clock on the first ring (center 10,10, radius 8.6).
    private func pixelAtTopOfFirstRing(_ image: NSImage) -> NSColor {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 86, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 43, height: 20)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 43, height: 20))
        NSGraphicsContext.restoreGraphicsState()
        // colorAt counts rows from the top: 18.75 pt up is row 2.
        return rep.colorAt(x: 21, y: 2)!.usingColorSpace(.deviceRGB)!
    }
}
