import XCTest
@testable import ClaudeUsageWidget

/// Every image set on a status item makes macOS redraw it on every display. Setting the same
/// thing again must cost nothing (v0.5.1: a redraw loop held the widget at 87% CPU).
@MainActor
final class StatusItemRendererTests: XCTestCase {

    private final class FakeDisplay: StatusItemDisplay {
        var image: NSImage? { didSet { imageSets += 1 } }
        var attributedTitle = NSAttributedString() { didSet { titleSets += 1 } }
        var appearsDisabled = false { didSet { dimmedSets += 1 } }
        var toolTip: String? { didSet { toolTipSets += 1 } }
        private(set) var imageSets = 0
        private(set) var titleSets = 0
        private(set) var dimmedSets = 0
        private(set) var toolTipSets = 0
        private(set) var accessibilityValueSets = 0
        private(set) var accessibilityValue: String?

        func setAccessibilityValue(_ value: Any?) {
            accessibilityValueSets += 1
            accessibilityValue = value as? String
        }
    }

    private func presentation(logo: ServiceID = .claude, title: String = "50% remain", badge: RingColorState = .normal, dimmed: Bool = false,
                              toolTip: String = "Claude Weekly: 50% left", value: String = "Claude Weekly, 50% remaining") -> StatusPresentation {
        StatusPresentation(
            content: StatusItemContent(logo: logo, title: title, badge: badge, isDimmed: dimmed),
            toolTip: toolTip,
            accessibilityValue: value
        )
    }

    func testFirstRenderAppliesEverything() throws {
        let display = FakeDisplay()
        StatusItemRenderer(display: display).render(presentation(dimmed: true))
        XCTAssertEqual(display.imageSets, 1)
        XCTAssertNotNil(display.image)
        XCTAssertEqual(display.attributedTitle, StatusIcon.attributedTitle("50% remain"))
        XCTAssertTrue(display.appearsDisabled)
        XCTAssertEqual(display.toolTip, "Claude Weekly: 50% left")
        XCTAssertEqual(display.accessibilityValue, "Claude Weekly, 50% remaining")
    }

    /// The title is the menu bar's own text in our font, padded so it is always as wide as the widest.
    func testTitleIsThePaddedMenuBarText() {
        let display = FakeDisplay()
        let renderer = StatusItemRenderer(display: display)
        renderer.render(presentation(title: "9% remain"))
        XCTAssertEqual(display.attributedTitle, StatusIcon.attributedTitle("9% remain"))
        XCTAssertNotEqual(display.attributedTitle.string, "9% remain", "padded on the right")
        renderer.render(presentation(title: "Sign in"))
        XCTAssertEqual(display.attributedTitle, StatusIcon.attributedTitle("Sign in"))
    }

    func testIdenticalRenderAppliesNothing() {
        let display = FakeDisplay()
        let renderer = StatusItemRenderer(display: display)
        renderer.render(presentation())
        renderer.render(presentation())
        renderer.render(presentation())
        XCTAssertEqual(display.imageSets, 1)
        XCTAssertEqual(display.titleSets, 1)
        XCTAssertEqual(display.dimmedSets, 1)
        XCTAssertEqual(display.toolTipSets, 1)
        XCTAssertEqual(display.accessibilityValueSets, 1)
    }

    func testTitleAndDimmedAppliedOnlyOnChange() {
        let display = FakeDisplay()
        let renderer = StatusItemRenderer(display: display)
        renderer.render(presentation())

        renderer.render(presentation(title: "49% remain"))
        XCTAssertEqual(display.titleSets, 2, "new title")
        XCTAssertEqual(display.dimmedSets, 1)
        XCTAssertEqual(display.attributedTitle, StatusIcon.attributedTitle("49% remain"))

        renderer.render(presentation(title: "49% remain", dimmed: true))
        XCTAssertEqual(display.titleSets, 2, "same title")
        XCTAssertEqual(display.dimmedSets, 2, "newly dimmed")
        XCTAssertTrue(display.appearsDisabled)

        renderer.render(presentation(title: "49% remain", dimmed: true))
        XCTAssertEqual(display.titleSets, 2)
        XCTAssertEqual(display.dimmedSets, 2)

        renderer.render(presentation(title: "49% remain", dimmed: false))
        XCTAssertEqual(display.dimmedSets, 3, "current again")
        XCTAssertFalse(display.appearsDisabled)
    }

    /// The image is the logo with its badge. A new number, a dimmed item or a new tooltip is not a new picture.
    func testImageReappliedOnlyWhenLogoOrBadgeChanges() {
        let display = FakeDisplay()
        let renderer = StatusItemRenderer(display: display)
        renderer.render(presentation())
        XCTAssertEqual(display.image?.isTemplate, true, "no badge: the system tints it")

        renderer.render(presentation(title: "49% remain"))
        renderer.render(presentation(title: "49% remain", dimmed: true))
        renderer.render(presentation(title: "49% remain", dimmed: true, toolTip: "Claude Weekly: 51% left"))
        XCTAssertEqual(display.imageSets, 1, "title, dimming and tooltip alone never touch the image")

        renderer.render(presentation(title: "35% remain", badge: .amber, dimmed: true))
        XCTAssertEqual(display.imageSets, 2, "the badge turned amber")
        XCTAssertEqual(display.image?.isTemplate, false, "a colored badge cannot be tinted by the system")

        renderer.render(presentation(title: "34% remain", badge: .amber, dimmed: true))
        XCTAssertEqual(display.imageSets, 2, "same logo, same badge")

        renderer.render(presentation(logo: .grokBot, title: "34% remain", badge: .amber, dimmed: true))
        XCTAssertEqual(display.imageSets, 3, "another service's logo")

        renderer.render(presentation(logo: .grokBot, title: "9% remain", badge: .critical, dimmed: true))
        XCTAssertEqual(display.imageSets, 4, "the badge turned red")
    }

    func testToolTipAndVoiceOverValueAppliedOnlyOnChange() {
        let display = FakeDisplay()
        let renderer = StatusItemRenderer(display: display)
        renderer.render(presentation())
        renderer.render(presentation(toolTip: "Claude Weekly: 50% left\nClaude updated 20 min ago"))
        XCTAssertEqual(display.toolTipSets, 2)
        XCTAssertEqual(display.accessibilityValueSets, 1)
        XCTAssertEqual(display.imageSets, 1)
        renderer.render(presentation(toolTip: "Claude Weekly: 50% left\nClaude updated 20 min ago", value: "Claude Weekly, 50% remaining, updated 20 min ago"))
        XCTAssertEqual(display.toolTipSets, 2)
        XCTAssertEqual(display.accessibilityValueSets, 2)
    }
}
