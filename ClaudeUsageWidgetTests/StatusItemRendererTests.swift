import XCTest
@testable import ClaudeUsageWidget

/// Every image set on a status item makes macOS redraw it on every display. Setting the same
/// thing again must cost nothing (v0.5.1: a redraw loop held the widget at 87% CPU).
@MainActor
final class StatusItemRendererTests: XCTestCase {

    private final class FakeDisplay: StatusItemDisplay {
        var image: NSImage? { didSet { imageSets += 1 } }
        var toolTip: String? { didSet { toolTipSets += 1 } }
        private(set) var imageSets = 0
        private(set) var toolTipSets = 0
        private(set) var accessibilityValueSets = 0
        private(set) var accessibilityValue: String?

        func setAccessibilityValue(_ value: Any?) {
            accessibilityValueSets += 1
            accessibilityValue = value as? String
        }
    }

    private func presentation(left: Int = 50, toolTip: String = "Session: 50% left", value: String = "Session 50% left") -> StatusPresentation {
        StatusPresentation(
            icon: StatusIconModel(rings: [.usage(left: left, used: Double(100 - left) / 100, color: .normal)], isDimmed: false),
            toolTip: toolTip,
            accessibilityValue: value
        )
    }

    func test_firstRender_appliesEverything() {
        let display = FakeDisplay()
        StatusItemRenderer(display: display).render(presentation())
        XCTAssertEqual(display.imageSets, 1)
        XCTAssertNotNil(display.image)
        XCTAssertEqual(display.toolTip, "Session: 50% left")
        XCTAssertEqual(display.accessibilityValue, "Session 50% left")
    }

    func test_identicalRender_appliesNothing() {
        let display = FakeDisplay()
        let renderer = StatusItemRenderer(display: display)
        renderer.render(presentation())
        renderer.render(presentation())
        renderer.render(presentation())
        XCTAssertEqual(display.imageSets, 1)
        XCTAssertEqual(display.toolTipSets, 1)
        XCTAssertEqual(display.accessibilityValueSets, 1)
    }

    func test_onlyWhatChanged_isApplied() {
        let display = FakeDisplay()
        let renderer = StatusItemRenderer(display: display)
        renderer.render(presentation())
        renderer.render(presentation(toolTip: "Session: 50% left\nUpdated 1 min ago"))
        XCTAssertEqual(display.imageSets, 1, "same rings, no new image")
        XCTAssertEqual(display.toolTipSets, 2)
        XCTAssertEqual(display.accessibilityValueSets, 1)
        renderer.render(presentation(left: 49, toolTip: "Session: 50% left\nUpdated 1 min ago"))
        XCTAssertEqual(display.imageSets, 2, "new number, new image")
        XCTAssertEqual(display.toolTipSets, 2)
    }
}
