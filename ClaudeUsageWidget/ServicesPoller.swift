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

    /// How late the timer may fire, so the system can wake it together with other timers instead of on its own.
    /// Never more than a tenth of the interval: 30 s for the five-minute poll, and a short interval still fires on time.
    private static let timerTolerance: TimeInterval = 30

    private let readers: [ServiceReader]
    private let interval: TimeInterval
    /// The poll's timer while it runs; nil when stopped.
    private(set) var timer: Timer?
    /// The refresh in progress. A call that arrives meanwhile joins it.
    private var refreshTask: Task<Void, Never>?

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

    /// Reads every set-up service once, one after another, then calls `onChange` if any state changed.
    /// A call that arrives while a refresh is running waits for it instead of reading again, so no reader is read twice
    /// at once and the caller finds fresh states either way.
    func refresh() async {
        if let running = refreshTask {
            await running.value
            return
        }
        let task = Task { [self] in
            await readAll()
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func readAll() async {
        let before = states
        for reader in readers {
            let id = reader.service
            guard reader.isSetUp() else {
                states[id] = nil   // its files are gone: nothing of it stays behind
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
