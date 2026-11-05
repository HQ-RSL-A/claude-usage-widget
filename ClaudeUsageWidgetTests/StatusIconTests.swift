import XCTest
import AppKit
@testable import ClaudeUsageWidget

final class StatusIconTests: XCTestCase {

    private func content(_ logo: ServiceID = .claude, badge: RingColorState = .normal, title: String = "40% remain", dimmed: Bool = false) -> StatusItemContent {
        StatusItemContent(logo: logo, title: title, badge: badge, isDimmed: dimmed)
    }

    /// The badge dot: 6 pt across, centered at (13, 13) of the 16 pt mark (counted from the bottom left),
    /// with a 1.5 pt ring cut clear around it.
    private let badgeCenter = CGPoint(x: 13, y: 13)
    private let amberOnDark = (r: 245, g: 158, b: 11)   // #F59E0B
    private let amberOnLight = (r: 180, g: 83, b: 9)     // #B45309, darker: #F59E0B is only 2:1 against a light menu bar
    private static let wallpaper = CGColor(srgbRed: 128 / 255, green: 100 / 255, blue: 60 / 255, alpha: 1)   // brown, opaque
    private static func isWallpaper(_ pixel: Bitmap.Pixel) -> Bool {
        pixel.a == 255 && abs(pixel.r - 128) <= 1 && abs(pixel.g - 100) <= 1 && abs(pixel.b - 60) <= 1
    }
    private let red = (r: 239, g: 68, b: 68)      // #EF4444

    // MARK: - The item's button

    /// The logo leads the title, the text starts at the left so the logo and the number never slide as the title
    /// changes, and the font is the menu bar's own. VoiceOver reads the item as "Usage Remaining": it shows
    /// whichever service is lowest now, so it is not named after Claude.
    func testButtonIsSetUpForAFixedLogoAndTitle() {
        let button = NSButton()
        StatusIcon.configure(button)
        XCTAssertEqual(button.imagePosition, .imageLeading)
        XCTAssertEqual(button.imageScaling, .scaleProportionallyDown)
        XCTAssertEqual(button.alignment, .left)
        XCTAssertEqual(button.font, StatusIcon.titleFont())
        XCTAssertEqual(button.accessibilityLabel(), "Usage Remaining")
    }

    // MARK: - Template or not

    /// Without a badge the image is the bare mark, a template the system tints like every other menu bar icon.
    func testTemplateWhenNoBadge() {
        for service in ServiceID.allCases {
            let image = StatusIcon.image(for: content(service))
            XCTAssertTrue(image.isTemplate, "\(service)")
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16), "\(service)")
        }
    }

    /// A colored dot cannot be tinted by the system, so the image stops being a template.
    func testNotATemplateWhenThereIsABadge() {
        for badge in [RingColorState.amber, .critical] {
            let image = StatusIcon.image(for: content(.claude, badge: badge))
            XCTAssertFalse(image.isTemplate, "\(badge)")
            XCTAssertEqual(image.size, NSSize(width: 16, height: 16), "\(badge)")
        }
    }

    // MARK: - One image for every menu bar (v0.5.1)

    /// macOS draws the status item once per display, each time in that menu bar's own appearance. The mark's
    /// color is picked while drawing, so one image is right on every display and the app never has to watch the
    /// appearance (watching it and re-setting the image was an endless redraw loop).
    func testBadgeIsColoredAndMarkFollowsAppearance() {
        for service in ServiceID.allCases {
            let bare = Bitmap(ServiceIcon.menuBarMark(for: service))   // where the mark has ink
            let image = StatusIcon.image(for: content(service, badge: .amber))   // ONE image, drawn twice
            let onDark = Bitmap(image, in: .darkAqua)
            let onLight = Bitmap(image, in: .aqua)

            assertColor(onDark.pixel(at: badgeCenter), amberOnDark, "\(service) badge on a dark menu bar")
            assertColor(onLight.pixel(at: badgeCenter), amberOnLight, "\(service) badge on a light menu bar, from the same image")

            var inked = 0, notWhiteOnDark = 0, notBlackOnLight = 0
            bare.forEachPixel { point, pixel in
                guard pixel.a >= 250, point.distance(to: badgeCenter) > 6 else { return }
                inked += 1
                let dark = onDark.pixel(at: point), light = onLight.pixel(at: point)
                if dark.a < 250 || min(dark.r, dark.g, dark.b) < 250 { notWhiteOnDark += 1 }
                if light.a < 250 || max(light.r, light.g, light.b) > 5 { notBlackOnLight += 1 }
            }
            XCTAssertGreaterThan(inked, 20, "\(service): the mark has ink to look at")
            XCTAssertEqual(notWhiteOnDark, 0, "\(service): the mark is white on a dark menu bar")
            XCTAssertEqual(notBlackOnLight, 0, "\(service): the mark is black on a light menu bar, from the same image")
        }
    }

    /// A cached drawing would carry one menu bar's color onto the other display.
    func testColoredImageIsRedrawnEveryTime() {
        for badge in [RingColorState.amber, .critical] {
            XCTAssertEqual(StatusIcon.image(for: content(badge: badge)).cacheMode, .never, "\(badge)")
        }
    }

    // MARK: - The badge

    func testCriticalBadgeIsRed() {
        let image = StatusIcon.image(for: content(.grokBot, badge: .critical))
        assertColor(Bitmap(image, in: .darkAqua).pixel(at: badgeCenter), red, "badge on a dark menu bar")
        assertColor(Bitmap(image, in: .aqua).pixel(at: badgeCenter), red, "badge on a light menu bar")
    }

    /// 6 pt across, centered at (13, 13): it spans 10 to 16 both ways, so it sits in the top right corner of the mark.
    func testBadgeDotIsSixPointsAcrossInTheTopRightCorner() {
        let bitmap = Bitmap(StatusIcon.image(for: content(.claude, badge: .amber)), in: .darkAqua)
        var x = (min: CGFloat.infinity, max: -CGFloat.infinity), y = x
        bitmap.forEachPixel { point, pixel in
            guard pixel.a > 127, pixel.r > 200, pixel.b < 80 else { return }   // amber; the white mark never is
            x = (min(x.min, point.x), max(x.max, point.x))
            y = (min(y.min, point.y), max(y.max, point.y))
        }
        // Pixel centers, half a pixel (0.25 pt) in from the dot's edge.
        XCTAssertEqual(x.min, 10.25, accuracy: 0.3)
        XCTAssertEqual(x.max, 15.75, accuracy: 0.3)
        XCTAssertEqual(y.min, 10.25, accuracy: 0.3)
        XCTAssertEqual(y.max, 15.75, accuracy: 0.3)
    }

    /// The dot is cut out of the mark with a 1.5 pt ring, so it never merges into the logo.
    func testBadgeCutsAClearRingOutOfTheMark() {
        var inkInTheRing = 0, ringNotClear = 0, markDisturbed = 0
        for service in ServiceID.allCases {
            let bare = Bitmap(ServiceIcon.menuBarMark(for: service))
            let badged = Bitmap(StatusIcon.image(for: content(service, badge: .amber)), in: .darkAqua)
            bare.forEachPixel { point, pixel in
                let distance = point.distance(to: badgeCenter)
                if distance > 3.3 && distance < 4.2 {   // between the dot (3.0) and the ring's outer edge (4.5)
                    if pixel.a > 200 { inkInTheRing += 1 }
                    if badged.pixel(at: point).a > 10 { ringNotClear += 1 }
                } else if distance > 5 {                // beyond the ring the mark is as it was
                    if abs(badged.pixel(at: point).a - pixel.a) > 6 { markDisturbed += 1 }
                }
            }
        }
        XCTAssertGreaterThan(inkInTheRing, 0, "at least one mark reaches the badge, so the cut is really tested")
        XCTAssertEqual(ringNotClear, 0, "the ring around the dot is clear")
        XCTAssertEqual(markDisturbed, 0, "the rest of the mark is untouched")
    }

    /// AppKit draws a drawing-handler image as a group of its own, so what the handler does cannot reach what is
    /// behind the item. The image does not lean on that: its color and its cut stay inside a transparency layer, so
    /// even drawn straight onto a menu bar (the handler called by hand here, over a wallpaper), only the mark is
    /// colored and only the mark is cut.
    func testNothingBehindTheItemIsPaintedOrCut() throws {
        for service in ServiceID.allCases {
            let bare = Bitmap(ServiceIcon.menuBarMark(for: service))
            let image = StatusIcon.image(for: content(service, badge: .amber))
            for appearance in [NSAppearance.Name.darkAqua, .aqua] {
                let straightOnto = try Bitmap.drawnStraightOnto(Self.wallpaper, image: image, in: appearance)
                var behindTouched = 0, cutMissed = 0, inRing = 0
                bare.forEachPixel { point, pixel in
                    let distance = point.distance(to: badgeCenter)
                    guard distance > 3.4 else { return }   // the dot itself is drawn here
                    let isRing = distance < 4.2
                    if pixel.a == 0, !Self.isWallpaper(straightOnto.pixel(at: point)) { behindTouched += 1 }
                    if isRing, pixel.a > 200 {             // the cut takes the mark, and the wallpaper shows through
                        inRing += 1
                        if !Self.isWallpaper(straightOnto.pixel(at: point)) { cutMissed += 1 }
                    }
                }
                XCTAssertEqual(behindTouched, 0, "\(service) in \(appearance.rawValue): only the mark is colored")
                XCTAssertEqual(cutMissed, 0, "\(service) in \(appearance.rawValue): the ring shows the wallpaper, not a hole")
                if service == .claude { XCTAssertGreaterThan(inRing, 0, "the mark reaches the badge, so the cut is really tested") }
            }
        }
    }

    /// The colors in each menu bar appearance. A dot is small, so it has to stand out from the menu bar behind it:
    /// amber #F59E0B does on a dark one but is only 2:1 against a light one, so there it is the darker #B45309. Red
    /// holds on both, and the mark itself is white on a dark menu bar and black on a light one.
    func testBadgeColorsPerAppearance() {
        func components(_ color: NSColor) -> [Int] {
            let c = color.usingColorSpace(.sRGB)!
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        let expected: [(NSAppearance.Name, RingColorState, [Int])] = [
            (.darkAqua, .amber, [245, 158, 11]),
            (.aqua, .amber, [180, 83, 9]),
            (.darkAqua, .critical, [239, 68, 68]),
            (.aqua, .critical, [239, 68, 68]),
            (.darkAqua, .normal, [255, 255, 255]),
            (.aqua, .normal, [0, 0, 0]),
        ]
        for (name, state, rgb) in expected {
            XCTAssertEqual(components(StatusIcon.color(for: state, in: NSAppearance(named: name)!)), rgb, "\(state) in \(name.rawValue)")
        }
    }

    // MARK: - The item

    /// The item has one width for every title, sized for the widest ("100% remain"), so the menu bar never shifts
    /// as the number changes.
    func testItemLengthFitsWidestTitle() {
        let widest = NSAttributedString(string: "100% remain", attributes: [.font: StatusIcon.titleFont()]).size().width
        let needed = 16 + 4 + widest + 12   // the mark, the gap after it, the title, the room around them
        let length = StatusIcon.itemLength()
        XCTAssertGreaterThanOrEqual(length, needed)
        XCTAssertLessThan(length, needed + 1, "no more room than a rounding up")
    }

    func testTitleFontIsTheMenuBarFontWithEvenDigits() {
        let font = StatusIcon.titleFont()
        XCTAssertEqual(font.pointSize, NSFont.menuBarFont(ofSize: 0).pointSize)
        func width(_ string: String) -> CGFloat { NSAttributedString(string: string, attributes: [.font: font]).size().width }
        XCTAssertEqual(width("11"), width("88"), accuracy: 0.001, "every digit is as wide as the next, so numbers do not jiggle")
    }

    // MARK: - The title

    /// The status button centers what it holds, so every title is padded on the right to the width of the widest:
    /// the logo and the number then start in the same place whatever is shown.
    func testEveryTitleIsAsWideAsTheWidest() {
        let font = StatusIcon.titleFont()
        func width(_ text: NSAttributedString) -> CGFloat { text.size().width }
        let widest = width(NSAttributedString(string: "100% remain", attributes: [.font: font]))
        let digit = width(NSAttributedString(string: "0", attributes: [.font: font]))
        // A number is a whole number of digits narrower than the widest, so it comes out exactly as wide.
        for title in ["100% remain", "99% remain", "40% remain", "9% remain", "0% remain"] {
            XCTAssertEqual(width(StatusIcon.attributedTitle(title)), widest, accuracy: 0.01, title)
        }
        // A word is not, so it comes out within half a digit.
        for title in ["Sign in", "Updating", "Offline", "No data"] {
            XCTAssertEqual(width(StatusIcon.attributedTitle(title)), widest, accuracy: digit / 2 + 0.01, title)
        }
    }

    func testPaddingIsOnlyDigitWideSpacesAfterTheTitle() {
        let padded = StatusIcon.attributedTitle("9% remain")
        XCTAssertTrue(padded.string.hasPrefix("9% remain"))
        let padding = padded.string.dropFirst("9% remain".count)
        XCTAssertEqual(String(padding), String(repeating: "\u{2007}", count: 2), "two digits narrower than the widest: two figure spaces")
        XCTAssertEqual(StatusIcon.attributedTitle("100% remain").string, "100% remain", "the widest needs none")
        // The menu bar font and nothing else: no color, because the menu bar colors its own text.
        var range = NSRange()
        let attributes = padded.attributes(at: 0, effectiveRange: &range)
        XCTAssertEqual(range.length, padded.length, "one set of attributes all the way along")
        XCTAssertEqual(Set(attributes.keys), [.font])
        XCTAssertEqual(attributes[.font] as? NSFont, StatusIcon.titleFont())
    }

    // MARK: - Helpers

    private func assertColor(_ pixel: Bitmap.Pixel, _ expected: (r: Int, g: Int, b: Int), _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pixel.a, 255, "\(message): opaque", file: file, line: line)
        XCTAssertEqual(pixel.r, expected.r, accuracy: 2, "\(message): red", file: file, line: line)
        XCTAssertEqual(pixel.g, expected.g, accuracy: 2, "\(message): green", file: file, line: line)
        XCTAssertEqual(pixel.b, expected.b, accuracy: 2, "\(message): blue", file: file, line: line)
    }
}

// MARK: - Reading pixels

/// An image drawn the way a Retina menu bar draws it (2x, sRGB) in a chosen appearance, so a test can read
/// real pixels. Positions are in points counted from the bottom left, like the drawing itself.
private struct Bitmap {
    typealias Pixel = (r: Int, g: Int, b: Int, a: Int)   // 0 to 255, color not premultiplied

    private let width: Int
    private let height: Int
    private let bytes: [UInt8]   // premultiplied RGBA, top row first

    init(_ image: NSImage, in appearance: NSAppearance.Name = .aqua) {
        self.init(width: Int(image.size.width) * 2, height: Int(image.size.height) * 2, wallpaper: nil, appearance: appearance) { _, size in
            image.draw(in: NSRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        }
    }

    /// The image's own drawing handler, called by hand over an opaque wallpaper: nothing isolates what it draws.
    static func drawnStraightOnto(_ wallpaper: CGColor, image: NSImage, in appearance: NSAppearance.Name) throws -> Bitmap {
        let handler = try XCTUnwrap((image.representations.first as? NSCustomImageRep)?.drawingHandler, "the image is drawn by a handler")
        return Bitmap(width: Int(image.size.width) * 2, height: Int(image.size.height) * 2, wallpaper: wallpaper, appearance: appearance) { context, size in
            context.scaleBy(x: 2, y: 2)
            _ = handler(NSRect(origin: .zero, size: size))
        }
    }

    private init(width w: Int, height h: Int, wallpaper: CGColor?, appearance: NSAppearance.Name, draw: (CGContext, NSSize) -> Void) {
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let wallpaper {
            context.setFillColor(wallpaper)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            draw(context, NSSize(width: w / 2, height: h / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        width = w
        height = h
        bytes = Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
    }

    /// The pixel under a point.
    func pixel(at point: CGPoint) -> Pixel {
        pixel(column: Int(point.x * 2), row: height - 1 - Int(point.y * 2))
    }

    /// Every pixel with the point at its center.
    func forEachPixel(_ body: (_ point: CGPoint, _ pixel: Pixel) -> Void) {
        for row in 0..<height {
            for column in 0..<width {
                body(CGPoint(x: (CGFloat(column) + 0.5) / 2, y: (CGFloat(height - 1 - row) + 0.5) / 2), pixel(column: column, row: row))
            }
        }
    }

    private func pixel(column: Int, row: Int) -> Pixel {
        guard (0..<width).contains(column), (0..<height).contains(row) else { return (0, 0, 0, 0) }
        let i = (row * width + column) * 4
        let alpha = Int(bytes[i + 3])
        guard alpha > 0 else { return (0, 0, 0, 0) }
        func straight(_ value: UInt8) -> Int { min(255, (Int(value) * 255 + alpha / 2) / alpha) }
        return (straight(bytes[i]), straight(bytes[i + 1]), straight(bytes[i + 2]), alpha)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot() }
}
