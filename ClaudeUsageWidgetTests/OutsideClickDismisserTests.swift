import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class OutsideClickDismisserTests: XCTestCase {

    @MainActor
    private final class FakeMonitor: OutsideClickMonitoring {
        private(set) var starts = 0
        private var handler: (@MainActor () -> Void)?
        var isMonitoring: Bool { handler != nil }
        func start(onClick: @escaping @MainActor () -> Void) { starts += 1; handler = onClick }
        func stop() { handler = nil }
        func simulateOutsideClick() { handler?() }
    }

    private var monitor: FakeMonitor!
    private var shown = false
    private var closes = 0
    private var dismisser: OutsideClickDismisser!

    override func setUp() {
        super.setUp()
        monitor = FakeMonitor()
        shown = false
        closes = 0
        dismisser = OutsideClickDismisser(
            monitor: monitor,
            isShown: { [unowned self] in self.shown },
            close: { [unowned self] in self.closes += 1; self.shown = false; self.dismisser.popoverDidClose() }
        )
    }

    func test_nothingIsWatched_untilThePopoverShows() {
        XCTAssertFalse(monitor.isMonitoring)
    }

    func test_showing_startsWatchingForOutsideClicks() {
        shown = true
        dismisser.popoverDidShow()
        XCTAssertTrue(monitor.isMonitoring)
    }

    func test_outsideClick_closesThePopover_andStopsWatching() {
        shown = true
        dismisser.popoverDidShow()
        monitor.simulateOutsideClick()
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(monitor.isMonitoring)
    }

    func test_closingAnotherWay_stopsWatching() {
        shown = true
        dismisser.popoverDidShow()
        shown = false
        dismisser.popoverDidClose()        // closed from the status item or the Quit button
        XCTAssertFalse(monitor.isMonitoring)
        monitor.simulateOutsideClick()
        XCTAssertEqual(closes, 0)
    }

    func test_clickWhilePopoverAlreadyHidden_doesNotCloseAgain() {
        shown = true
        dismisser.popoverDidShow()
        shown = false                       // hidden without the delegate hearing about it
        monitor.simulateOutsideClick()
        XCTAssertEqual(closes, 0)
        XCTAssertFalse(monitor.isMonitoring)
    }

    func test_showingTwice_keepsOneWatcher() {
        shown = true
        dismisser.popoverDidShow()
        dismisser.popoverDidShow()
        monitor.simulateOutsideClick()
        XCTAssertEqual(closes, 1)
    }

    // MARK: - GlobalClickMonitor (the real NSEvent monitor)

    func test_globalMonitor_startAndStop() {
        let real = GlobalClickMonitor()
        XCTAssertFalse(real.isMonitoring)
        real.start { }
        XCTAssertTrue(real.isMonitoring)
        real.start { }                      // replaces, does not stack
        XCTAssertTrue(real.isMonitoring)
        real.stop()
        XCTAssertFalse(real.isMonitoring)
        real.stop()                         // twice is fine
    }
}
