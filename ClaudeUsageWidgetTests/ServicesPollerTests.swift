import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class ServicesPollerTests: XCTestCase {

    private var pollers: [ServicesPoller] = []

    override func tearDown() {
        pollers.forEach { $0.stop() }
        pollers = []
        super.tearDown()
    }

    /// Every poller a test makes is stopped in `tearDown`, so a failed assertion never leaves a timer running.
    /// Without an interval it gets the one `init` defaults to.
    private func makePoller(_ readers: [ServiceReader], interval: TimeInterval? = nil) -> ServicesPoller {
        let poller = interval.map { ServicesPoller(readers: readers, interval: $0) } ?? ServicesPoller(readers: readers)
        pollers.append(poller)
        return poller
    }

    /// One weekly limit. `readAt` is part of the state, so two readings with different times are different states.
    private func reading(_ used: Double, readAt: TimeInterval = 1_000) -> ServiceState {
        .reading(limits: [ServiceLimit(label: "Weekly", percentUsed: used, resetsAt: nil)],
                 readAt: Date(timeIntervalSince1970: readAt))
    }

    /// Lets the main actor run until `condition` holds, or `timeout` seconds pass. The assertions after it say what failed.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Lets everything already queued on the main actor run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    // MARK: - What gets read

    func testRefreshReadsOnlySetUpReaders() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, setUp: false, result: reading(0.4))
        let poller = makePoller([grok, codex])

        await poller.refresh()

        XCTAssertEqual(grok.reads, 1)
        XCTAssertEqual(codex.reads, 0)
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2)])
    }

    func testSetUpServicesFollowServiceIDOrder() {
        let codex = FakeServiceReader(.codex)
        let grok = FakeServiceReader(.grokBot)
        let poller = makePoller([codex, grok])   // handed over in the wrong order on purpose

        XCTAssertEqual(poller.setUpServices(), [.grokBot, .codex])
        grok.setUp = false
        XCTAssertEqual(poller.setUpServices(), [.codex])
        codex.setUp = false
        XCTAssertEqual(poller.setUpServices(), [])
    }

    func testServiceThatIsNoLongerSetUpIsDropped() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        var changes = 0
        poller.onChange = { changes += 1 }
        await poller.refresh()
        XCTAssertEqual(poller.states.count, 2)

        // Codex's sign-in file is gone: its old numbers must not stay behind.
        codex.setUp = false
        await poller.refresh()

        XCTAssertEqual(codex.reads, 1)
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2)])
        XCTAssertEqual(changes, 2)
    }

    func testLastRefreshIsStampedByEveryRefresh() async throws {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok])
        XCTAssertNil(poller.lastRefresh)

        let beforeFirst = Date()
        await poller.refresh()
        let afterFirst = Date()
        let first = try XCTUnwrap(poller.lastRefresh)
        XCTAssertTrue((beforeFirst...afterFirst).contains(first), "\(first)")

        // Nothing changed this time, and the stamp still moves: the "older than a minute" check reads it.
        await poller.refresh()
        let second = try XCTUnwrap(poller.lastRefresh)
        XCTAssertGreaterThanOrEqual(second, afterFirst)
    }

    func testLastRefreshIsStampedWhenNothingIsSetUp() async {
        let poller = makePoller([FakeServiceReader(.codex, setUp: false)])
        var changes = 0
        poller.onChange = { changes += 1 }

        await poller.refresh()

        XCTAssertNotNil(poller.lastRefresh)
        XCTAssertTrue(poller.states.isEmpty)
        XCTAssertEqual(changes, 0)
    }

    // MARK: - Telling the app

    func testOnChangeFiresOncePerRefreshWhenSomethingChanged() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        var changes = 0
        poller.onChange = { changes += 1 }

        await poller.refresh()
        XCTAssertEqual(changes, 1, "both services changed in one refresh: one call, not two")
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2), .codex: reading(0.4)])

        await poller.refresh()
        XCTAssertEqual(changes, 1, "the same answers again: nothing to tell")

        codex.result = reading(0.5)
        await poller.refresh()
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(poller.states[.codex], reading(0.5))
    }

    func testOnChangeSeesTheNewStatesAndTheRefreshTime() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok])
        var statesSeen: [ServiceID: ServiceState] = [:]
        var stampSeen: Date?
        poller.onChange = { [unowned poller] in
            statesSeen = poller.states
            stampSeen = poller.lastRefresh
        }

        await poller.refresh()

        XCTAssertEqual(statesSeen, [.grokBot: reading(0.2)])
        XCTAssertNotNil(stampSeen)
    }

    // MARK: - Temporary outages and sign-outs

    func testUnavailableKeepsLastReading() async {
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([codex])
        var changes = 0
        poller.onChange = { changes += 1 }
        await poller.refresh()
        XCTAssertEqual(changes, 1)

        // A temporary outage, or a file caught half written: the panel keeps the old numbers and shows their age.
        codex.result = .unavailable(reason: "Couldn't reach Codex")
        await poller.refresh()
        await poller.refresh()

        XCTAssertEqual(codex.reads, 3, "it keeps reading, so the outage ends on its own")
        XCTAssertEqual(poller.states[.codex], reading(0.4))
        XCTAssertEqual(changes, 1, "the panel shows the same thing, so there is nothing to tell")

        // The first reading after the outage replaces it.
        codex.result = reading(0.5, readAt: 2_000)
        await poller.refresh()
        XCTAssertEqual(poller.states[.codex], reading(0.5, readAt: 2_000))
        XCTAssertEqual(changes, 2)
    }

    func testNotSignedInReplacesReading() async {
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([codex])
        var changes = 0
        poller.onChange = { changes += 1 }
        await poller.refresh()

        // Signed out is not an outage: the old numbers belong to an account that is gone.
        codex.result = .notSignedIn(hint: "Open Codex to refresh its sign-in")
        await poller.refresh()

        XCTAssertEqual(poller.states[.codex], .notSignedIn(hint: "Open Codex to refresh its sign-in"))
        XCTAssertEqual(changes, 2)
    }

    func testNewReadingReplacesReading() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2, readAt: 1_000))
        let poller = makePoller([grok])
        await poller.refresh()

        grok.result = reading(0.3, readAt: 2_000)
        await poller.refresh()

        XCTAssertEqual(poller.states[.grokBot], reading(0.3, readAt: 2_000))
    }

    func testUnavailableIsShownWhenThereIsNoReadingToKeep() async {
        let codex = FakeServiceReader(.codex, result: .unavailable(reason: "Couldn't reach Codex"))
        let poller = makePoller([codex])
        var changes = 0
        poller.onChange = { changes += 1 }

        await poller.refresh()
        XCTAssertEqual(poller.states[.codex], .unavailable(reason: "Couldn't reach Codex"))
        XCTAssertEqual(changes, 1)

        // Only a reading is kept. A newer reason replaces an older one.
        codex.result = .unavailable(reason: "Codex changed its usage format")
        await poller.refresh()
        XCTAssertEqual(poller.states[.codex], .unavailable(reason: "Codex changed its usage format"))
        XCTAssertEqual(changes, 2)

        // A sign-out hint gives way to a later outage message too.
        codex.result = .notSignedIn(hint: "Open Codex and sign in with ChatGPT")
        await poller.refresh()
        codex.result = .unavailable(reason: "Couldn't reach Codex")
        await poller.refresh()
        XCTAssertEqual(poller.states[.codex], .unavailable(reason: "Couldn't reach Codex"))
    }

    // MARK: - Overlapping refreshes

    func testConcurrentRefreshReadsEachReaderOnce() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        var changes = 0
        poller.onChange = { changes += 1 }
        grok.holdsReads = true

        let first = Task { await poller.refresh() }
        await waitUntil { grok.reads == 1 }
        XCTAssertEqual(grok.reads, 1, "the first refresh is inside Grok Bot's read")

        // A second call arrives in the middle of it.
        let secondReturned = Flag()
        let second = Task {
            await poller.refresh()
            secondReturned.isSet = true
        }
        await settle()
        XCTAssertEqual(grok.reads, 1, "the second call does not read it again")
        XCTAssertEqual(codex.reads, 0, "readers are read one after another")
        XCTAssertFalse(secondReturned.isSet, "the second call waits for the refresh already running, so its caller sees fresh states")

        grok.release()
        await first.value
        await second.value

        XCTAssertEqual(grok.reads, 1)
        XCTAssertEqual(codex.reads, 1)
        XCTAssertTrue(secondReturned.isSet)
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2), .codex: reading(0.4)])
        XCTAssertEqual(changes, 1)
    }

    func testRefreshAfterOneFinishedReadsAgain() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok])

        await poller.refresh()
        await poller.refresh()

        XCTAssertEqual(grok.reads, 2)
    }

    // MARK: - Starting and stopping

    func testStartReadsAtOnceAndStopCancels() async throws {
        // Starting reads at once. An hour-long interval leaves the timer no chance to be the one that read.
        let slow = FakeServiceReader(.grokBot, result: reading(0.2))
        let slowPoller = makePoller([slow], interval: 3_600)
        slowPoller.start()
        await waitUntil { slow.reads >= 1 }
        XCTAssertEqual(slow.reads, 1)
        XCTAssertEqual(slowPoller.states, [.grokBot: reading(0.2)])
        slowPoller.stop()

        // The timer reads again every interval, and stopping ends it.
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok], interval: 0.05)
        poller.start()
        await waitUntil { grok.reads >= 3 }
        XCTAssertGreaterThanOrEqual(grok.reads, 3, "the first read, then the timer's")

        poller.stop()
        await settle()   // a read already on its way may land here; none starts after it
        let readsAtStop = grok.reads
        try await Task.sleep(nanoseconds: 300_000_000)   // six intervals
        XCTAssertEqual(grok.reads, readsAtStop)
    }

    func testPollIsOneTimerOfFiveMinutesWithThirtySecondsOfTolerance() {
        let poller = makePoller([FakeServiceReader(.grokBot)])
        XCTAssertNil(poller.timer)

        poller.start()
        let running = poller.timer
        XCTAssertEqual(running?.isValid, true)
        XCTAssertEqual(running?.timeInterval, 300)
        XCTAssertEqual(running?.tolerance, 30)

        poller.stop()
        XCTAssertNil(poller.timer)
        XCTAssertEqual(running?.isValid, false, "stopping takes the timer off the run loop, it doesn't just forget it")
    }

    func testToleranceIsAtMostATenthOfAShortInterval() throws {
        let poller = makePoller([FakeServiceReader(.grokBot)], interval: 0.05)

        poller.start()

        let tolerance = try XCTUnwrap(poller.timer?.tolerance)
        XCTAssertEqual(tolerance, 0.005, accuracy: 1e-9)
    }

    func testStartAgainReplacesTheTimer() {
        let poller = makePoller([FakeServiceReader(.grokBot)])
        poller.start()
        let first = poller.timer

        poller.start()

        XCTAssertEqual(first?.isValid, false, "the old timer is gone, so the poll never runs twice as often")
        XCTAssertEqual(poller.timer?.isValid, true)
        XCTAssertFalse(first === poller.timer)
    }

    /// A menu or the popover tracking the mouse runs the main run loop in `.eventTracking` mode. The poll must keep going then.
    func testTimerKeepsFiringWhileTheRunLoopTracksEvents() {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok], interval: 0.05)
        poller.start()

        let deadline = Date().addingTimeInterval(2)
        while grok.reads < 3 && Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }

        XCTAssertGreaterThanOrEqual(grok.reads, 3, "the first read, then the timer's")
    }

    func testStopRightAfterStartSkipsTheFirstRead() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok], interval: 0.05)

        poller.start()
        poller.stop()
        await settle()

        XCTAssertEqual(grok.reads, 0)
        XCTAssertTrue(poller.states.isEmpty)
    }
}

// MARK: - Helpers

@MainActor
private final class Flag {
    var isSet = false
}

/// A reader whose answer and availability the test sets, and that counts its reads.
@MainActor
private final class FakeServiceReader: ServiceReader {
    let service: ServiceID
    var setUp: Bool
    var result: ServiceState
    private(set) var reads = 0
    /// While true, a read waits until `release()`, so a test can hold a refresh halfway.
    var holdsReads = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ service: ServiceID, setUp: Bool = true, result: ServiceState = .loading) {
        self.service = service
        self.setUp = setUp
        self.result = result
    }

    func isSetUp() -> Bool { setUp }

    func read() async -> ServiceState {
        reads += 1
        if holdsReads {
            await withCheckedContinuation { waiting.append($0) }
        }
        return result
    }

    func release() {
        holdsReads = false
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }
}
