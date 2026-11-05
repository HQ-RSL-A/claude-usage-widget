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

    /// Codex rewrites auth.json when it renews its token, and a poll can catch it half written. With Codex's own reader
    /// that is "Couldn't reach Codex", so the panel keeps the last numbers instead of asking for a sign-in; a file that
    /// is gone is a real sign-out. The folder is a temporary one: the real `~/.codex` is never read.
    func testCodexAuthFileCaughtHalfWrittenKeepsTheLastNumbers() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.rsla.ClaudeUsageWidget.tests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let authFile = directory.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"access_token":"at","account_id":"acc"}}"#.utf8).write(to: authFile)
        let usage = Data(#"{"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1794000000}}}"#.utf8)
        StubURLProtocol.handler = { _ in (status: 200, body: usage) }
        let readAt = Date(timeIntervalSince1970: 1_793_900_000)
        let codex = CodexReader(authFile: authFile, session: StubURLProtocol.session(), now: { readAt })
        let poller = makePoller([codex])
        let numbers = ServiceState.reading(
            limits: [ServiceLimit(label: "5hr Session", percentUsed: 0.12, resetsAt: Date(timeIntervalSince1970: 1_794_000_000))],
            readAt: readAt)

        await poller.refresh()
        XCTAssertEqual(poller.states[.codex], numbers)

        try Data(#"{"tokens":{"access_to"#.utf8).write(to: authFile)   // caught half written
        await poller.refresh()
        XCTAssertEqual(poller.states[.codex], numbers, "the numbers stay until a read gets the file whole")
        XCTAssertEqual(StubURLProtocol.requests.count, 1, "nothing was sent for the half-written file")

        try FileManager.default.removeItem(at: authFile)                 // signed out
        await poller.refresh()
        XCTAssertNil(poller.states[.codex], "the sign-in file is gone, so are the numbers")
    }

    // MARK: - Hidden services

    /// A hidden service is not read at all: reading Codex sends its token to ChatGPT, and nobody asked to see it.
    func testDisabledServiceIsNotRead() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        poller.isEnabled = { $0 != .codex }

        await poller.refresh()

        XCTAssertEqual(grok.reads, 1)
        XCTAssertEqual(codex.reads, 0, "a hidden service is never read")
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2)])
        XCTAssertEqual(poller.setUpServices(), [.grokBot, .codex], "still set up, so the Show menu can offer it back")

        // Shown again, it is read at the next refresh.
        poller.isEnabled = { _ in true }
        await poller.refresh()
        XCTAssertEqual(codex.reads, 1)
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2), .codex: reading(0.4)])
    }

    /// The timer reads through the same path, so a hidden service stays unread however it is refreshed.
    func testDisabledServiceIsNotReadByTheTimerEither() async throws {
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([codex], interval: 0.05)
        poller.isEnabled = { _ in false }

        poller.start()
        try await Task.sleep(nanoseconds: 300_000_000)   // six intervals
        poller.stop()

        XCTAssertEqual(codex.reads, 0)
        XCTAssertTrue(poller.states.isEmpty)
    }

    /// A service hidden after it was read leaves nothing behind, as one whose files are gone does.
    func testServiceHiddenAfterItWasReadKeepsNothingBehind() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        var changes = 0
        poller.onChange = { changes += 1 }
        await poller.refresh()
        XCTAssertEqual(poller.states.count, 2)

        poller.isEnabled = { $0 != .codex }
        await poller.refresh()

        XCTAssertEqual(codex.reads, 1, "not read again")
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2)])
        XCTAssertEqual(changes, 2, "dropping it is a change the app hears about")
    }

    /// The answer is asked for just before each read, not once at the start of a refresh: a service hidden
    /// while an earlier one is being read is still not read by the refresh already under way.
    func testEnabledIsAskedJustBeforeEachRead() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        grok.holdsReads = true

        let refresh = Task { await poller.refresh() }
        await waitUntil { grok.reads == 1 }
        poller.isEnabled = { $0 != .codex }   // hidden while Grok Bot is being read
        grok.release()
        await refresh.value

        XCTAssertEqual(codex.reads, 0)
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2)])
    }

    // MARK: - Overlapping refreshes

    /// A call that arrives while a pass is running does not read beside it, and it does not just join it either: the pass
    /// underway may already have read (or skipped) what the call is about, so one more pass follows. Each caller returns
    /// after the pass that started after its call.
    func testCallDuringAPassWaitsForOneMorePassThatNeverOverlaps() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        var changes = 0
        poller.onChange = { changes += 1 }
        grok.holdsReads = true

        let first = Task { await poller.refresh() }
        await waitUntil { grok.reads == 1 }
        XCTAssertEqual(grok.reads, 1, "the first pass is inside Grok Bot's read")

        // A second call arrives in the middle of it.
        let secondReturned = Flag()
        let second = Task {
            await poller.refresh()
            secondReturned.isSet = true
        }
        await settle()
        XCTAssertEqual(grok.reads, 1, "the second call does not read beside the pass underway")
        XCTAssertEqual(codex.reads, 0, "readers are read one after another")
        XCTAssertFalse(secondReturned.isSet)

        // The first pass ends, and the pass the second call is waiting for starts at once and stops inside Grok Bot's read.
        grok.release()
        grok.holdsReads = true
        await first.value
        await waitUntil { grok.reads == 2 }
        XCTAssertEqual(codex.reads, 1, "the first pass read Codex before it ended")
        XCTAssertFalse(secondReturned.isSet, "the second call waits for a pass that started after it, not for the one it found")

        grok.release()
        await second.value

        XCTAssertTrue(secondReturned.isSet)
        XCTAssertEqual(grok.reads, 2)
        XCTAssertEqual(codex.reads, 2)
        XCTAssertEqual(grok.mostReadsAtOnce, 1, "a reader is never read twice at once")
        XCTAssertEqual(codex.mostReadsAtOnce, 1)
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2), .codex: reading(0.4)])
        XCTAssertEqual(changes, 1, "the second pass found the same answers: nothing more to tell")
    }

    /// Calls that arrive while the follow-up pass is still waiting to start share it, however many there are.
    func testCallsDuringAPassShareOneMorePass() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok])
        grok.holdsReads = true

        let first = Task { await poller.refresh() }
        await waitUntil { grok.reads == 1 }
        let others = (0..<3).map { _ in Task { await poller.refresh() } }
        await settle()

        grok.release()
        await first.value
        for other in others { await other.value }

        XCTAssertEqual(grok.reads, 2, "the pass that was underway, and one more for the three calls that came in meanwhile")
        XCTAssertEqual(grok.mostReadsAtOnce, 1)
    }

    /// The follow-up pass answers only the calls that came before it started. One that arrives while it is already
    /// reading needs a pass of its own.
    func testCallDuringTheFollowUpPassGetsAPassOfItsOwn() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let poller = makePoller([grok])
        grok.holdsReads = true

        let first = Task { await poller.refresh() }
        await waitUntil { grok.reads == 1 }
        let second = Task { await poller.refresh() }
        await settle()

        // The first pass ends, and the second one starts and stops inside Grok Bot's read.
        grok.release()
        grok.holdsReads = true
        await first.value
        await waitUntil { grok.reads == 2 }

        // A third call arrives while that pass is reading.
        let thirdReturned = Flag()
        let third = Task {
            await poller.refresh()
            thirdReturned.isSet = true
        }
        await settle()

        // The second pass ends: the second call is answered, the third is not, and its pass starts.
        grok.release()
        grok.holdsReads = true
        await second.value
        await waitUntil { grok.reads == 3 }
        XCTAssertFalse(thirdReturned.isSet, "the pass that was reading when the third call came cannot answer it")

        grok.release()
        await third.value

        XCTAssertEqual(grok.reads, 3)
        XCTAssertEqual(grok.mostReadsAtOnce, 1)
    }

    /// The app shows a hidden service and asks for a refresh while a pass is underway. That pass already skipped the
    /// service, so a call that only joined it would leave the service unread; the pass that follows reads it.
    func testServiceShownDuringAPassIsReadByThePassThatFollows() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        poller.isEnabled = { $0 != .grokBot }   // Grok Bot is hidden
        codex.holdsReads = true

        let first = Task { await poller.refresh() }
        await waitUntil { codex.reads == 1 }   // Grok Bot was skipped, and the pass is inside Codex's read
        XCTAssertEqual(grok.reads, 0)

        poller.isEnabled = { _ in true }       // shown, and the app refreshes
        let second = Task { await poller.refresh() }
        await settle()
        codex.release()
        await first.value
        await second.value

        XCTAssertEqual(grok.reads, 1, "read by the second pass")
        XCTAssertEqual(codex.reads, 2)
        XCTAssertEqual(poller.states, [.grokBot: reading(0.2), .codex: reading(0.4)])
    }

    /// The same the other way: a service hidden after the pass underway has read it is dropped by the pass that follows.
    func testServiceHiddenDuringAPassIsDroppedByThePassThatFollows() async {
        let grok = FakeServiceReader(.grokBot, result: reading(0.2))
        let codex = FakeServiceReader(.codex, result: reading(0.4))
        let poller = makePoller([grok, codex])
        codex.holdsReads = true

        let first = Task { await poller.refresh() }
        await waitUntil { codex.reads == 1 }
        XCTAssertEqual(grok.reads, 1, "Grok Bot was read before the pass got to Codex")

        poller.isEnabled = { $0 != .grokBot }   // hidden, and the app refreshes
        let second = Task { await poller.refresh() }
        await settle()
        codex.release()
        await first.value
        await second.value

        XCTAssertEqual(grok.reads, 1, "not read again")
        XCTAssertEqual(poller.states, [.codex: reading(0.4)], "nothing of a hidden service stays behind")
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
    /// The most reads that were running at the same moment. A reader is only ever read one at a time.
    private(set) var mostReadsAtOnce = 0
    private var readsRunning = 0
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
        readsRunning += 1
        mostReadsAtOnce = max(mostReadsAtOnce, readsRunning)
        defer { readsRunning -= 1 }
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
