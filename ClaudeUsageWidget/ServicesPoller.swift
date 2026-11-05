import Foundation

/// Reads the services the app polls by itself (Grok Bot, Codex) every five minutes or on demand, and keeps the latest
/// state of each. Claude keeps its own sign-in and polling, so it is not here.
@MainActor
final class ServicesPoller {
    /// The latest state per service. A service has no entry until its first read finishes, and none while it isn't set up.
    private(set) var states: [ServiceID: ServiceState] = [:]
    /// When the last refresh finished, whether or not anything changed. Nil until the first one.
    private(set) var lastRefresh: Date?
    /// Called once at the end of a refresh that changed what `states` holds.
    var onChange: (() -> Void)?
    /// Asked just before each read. False means the service is hidden, so it is not read and, for Codex, its token is not
    /// sent anywhere: nobody asked to see it. Everything is enabled until the app says otherwise.
    var isEnabled: (ServiceID) -> Bool = { _ in true }

    /// How late the timer may fire, so the system can wake it together with other timers instead of on its own.
    /// Never more than a tenth of the interval: 30 s for the five-minute poll, and a short interval still fires on time.
    private static let timerTolerance: TimeInterval = 30

    private let readers: [ServiceReader]
    private let interval: TimeInterval
    /// The poll's timer while it runs; nil when stopped.
    private(set) var timer: Timer?
    /// The latest pass over the readers: reading now, or waiting for the one before it to end.
    private var latestPass: Task<Void, Never>?
    /// Whether `latestPass` has begun reading. One that has not begun will still see whatever a call that arrives now
    /// knows about (a service shown or hidden), so that call joins it instead of adding another.
    private var latestPassHasStarted = false

    init(readers: [ServiceReader], interval: TimeInterval = 300) {
        self.readers = readers
        self.interval = interval
    }

    /// The services whose files are on this Mac, in `ServiceID` order whatever order the readers came in.
    func setUpServices() -> [ServiceID] {
        ServiceID.allCases.filter { id in
            readers.contains { $0.service == id && $0.isSetUp() }
        }
    }

    // MARK: - Polling

    /// Reads at once, then every interval. Starting again starts over.
    func start() {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        timer.tolerance = min(Self.timerTolerance, interval / 10)
        // .common, so the poll still runs while a menu or the popover is tracking events.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { [self] in await tick() }
    }

    /// Ends the polling. A refresh already running finishes, and `refresh()` still works by hand.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The timer's read, and the first one after `start()`. One that was queued before `stop()` does nothing.
    private func tick() async {
        guard timer != nil else { return }
        await refresh()
    }

    // MARK: - Reading

    /// Reads every set-up service once, one after another, then calls `onChange` if any state changed. The caller
    /// returns when a pass that started after its call has finished, so it finds the states as they are now.
    ///
    /// A call that arrives while a pass is running does not read beside it, and it does not simply join it either: the
    /// pass underway may already have read or skipped the service the call is about (one just shown or hidden). The
    /// call waits for the pass underway, and one more pass runs right after it. Calls that arrive before that pass starts
    /// share it, so any number of calls during one pass cost one more pass, and passes never overlap, so no reader is
    /// read twice at once.
    func refresh() async {
        if let waiting = latestPass, !latestPassHasStarted {
            await waiting.value
            return
        }
        let before = latestPass
        latestPassHasStarted = false
        let pass = Task { [self] in
            await before?.value
            latestPassHasStarted = true
            await readAll()
        }
        latestPass = pass
        await pass.value
    }

    private func readAll() async {
        let before = states
        for reader in readers {
            let id = reader.service
            guard reader.isSetUp(), isEnabled(id) else {
                states[id] = nil   // its files are gone or it is hidden: nothing of it stays behind
                continue
            }
            let state = await reader.read()
            states[id] = Self.stateToShow(replacing: states[id], with: state)
        }
        lastRefresh = Date()
        if states != before { onChange?() }
    }

    /// What `states` holds after a read. A reading outlives a later `.unavailable` (a temporary outage, or a file caught
    /// half written), so the panel keeps showing the numbers with their age. A sign-out or a newer reading replaces it.
    private static func stateToShow(replacing old: ServiceState?, with new: ServiceState) -> ServiceState {
        guard case .unavailable = new, let old, case .reading = old else { return new }
        return old
    }
}
