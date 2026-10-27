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

    // MARK: - Readable on any wallpaper (Rahul, 2026-10-26)

    private let amberOnly = StatusIconModel(rings: [.usage(left: 26, used: 0.74, color: .amber)], isDimmed: false)

    /// Amber or red digits get lost on a colored wallpaper: the number stays in the menu bar's own color,
    /// and only the ring's arc carries the warning color.
    func test_image_numbersUseTheMenuBarColor_onAColoredRing() {
        let onDark = render(StatusIcon.image(for: amberOnly, darkMenuBar: true))
        XCTAssertTrue(numberArea(onDark).contains { $0.alphaComponent > 0.8 && min($0.redComponent, $0.greenComponent, $0.blueComponent) > 0.85 },
                      "a white digit pixel on a dark menu bar")
        let onLight = render(StatusIcon.image(for: amberOnly, darkMenuBar: false))
        XCTAssertTrue(numberArea(onLight).contains { $0.alphaComponent > 0.8 && max($0.redComponent, $0.greenComponent, $0.blueComponent) < 0.15 },
                      "a black digit pixel on a light menu bar")
    }

    /// The faint track under a colored arc is neutral too; only the used part is amber.
    func test_image_trackIsNeutral_underAColoredArc() {
        let shortArc = StatusIconModel(rings: [.usage(left: 70, used: 0.3, color: .amber)], isDimmed: false)
        // 9 o'clock on the ring: track only, the arc stops near 4 o'clock.
        let track = render(StatusIcon.image(for: shortArc, darkMenuBar: true)).colorAt(x: 3, y: 20)!.usingColorSpace(.deviceRGB)!
        XCTAssertGreaterThan(track.alphaComponent, 0.05)
        XCTAssertGreaterThan(track.blueComponent, track.redComponent * 0.8, "white track, not amber")
    }

    // MARK: - Rendering helpers

    /// Renders at 2x on a transparent bitmap.
    private func render(_ image: NSImage) -> NSBitmapImageRep {
        let size = image.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The middle of the first ring, where its number sits (pixels, rows counted from the top).
    private func numberArea(_ rep: NSBitmapImageRep) -> [NSColor] {
        (12...28).flatMap { x in (14...26).map { y in rep.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)! } }
    }

    /// Reads the arc just right of 12 o'clock on the first ring (center 10,10, radius 8.6).
    private func pixelAtTopOfFirstRing(_ image: NSImage) -> NSColor {
        // colorAt counts rows from the top: 18.75 pt up is row 2.
        render(image).colorAt(x: 21, y: 2)!.usingColorSpace(.deviceRGB)!
    }
}
