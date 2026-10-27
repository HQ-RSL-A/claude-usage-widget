import Foundation

@MainActor
protocol UsageServiceDelegate: AnyObject {
    func usageServiceDidStartFetching(_ service: UsageService)
    func usageService(_ service: UsageService, didUpdate data: UsageData)
    func usageService(_ service: UsageService, didFailWith error: ClaudeAPIError)
    func usageServiceDidDetectSessionExpiry(_ service: UsageService)
}

extension UsageServiceDelegate {
    func usageServiceDidStartFetching(_ service: UsageService) {}
}

/// Polls the current identity's usage every five minutes, and once more just after a limit resets.
/// Stops itself and reports when the session is gone.
@MainActor
final class UsageService {
    weak var delegate: UsageServiceDelegate?

    var pollInterval: TimeInterval = 300
    var now: () -> Date = Date.init
    private(set) var lastData: UsageData?
    private(set) var isPolling = false
    private(set) var isFetching = false
    /// When the extra fetch after the next reset will run; nil when none is scheduled.
    private(set) var resetRefreshDate: Date?
    var identity: IdentitySource { source.identity }

    /// The server can take a moment to start the new window.
    static let resetRefreshDelay: TimeInterval = 10

    private let source: UsageSource
    private var timer: Timer?
    private var resetTimer: Timer?
    private var isStopped = false

    init(source: UsageSource) {
        self.source = source
    }

    func start() {
        stop()
        isStopped = false
        isPolling = true
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        cancelResetRefresh()
        isStopped = true
        isPolling = false
    }

    /// Manual refresh trigger
    func fetch() {
        Task { await fetchNow() }
    }

    /// One fetch at a time: a call while one is running returns at once.
    func fetchNow() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        delegate?.usageServiceDidStartFetching(self)
        do {
            let response = try await source.fetchUsage()
            if let error = ClaudeAPIError.classify(response) {
                if error == .sessionExpired {
                    stop()
                    delegate?.usageServiceDidDetectSessionExpiry(self)
                } else {
                    delegate?.usageService(self, didFailWith: error)
                }
                return
            }
            let data = try UsageData.decode(from: response.body)
            lastData = data
            scheduleResetRefresh(for: data)
            delegate?.usageService(self, didUpdate: data)
        } catch ClaudeAPIError.sessionExpired {
            stop()
            delegate?.usageServiceDidDetectSessionExpiry(self)
        } catch let error as ClaudeAPIError {
            delegate?.usageService(self, didFailWith: error)
        } catch {
            delegate?.usageService(self, didFailWith: .decode(error.localizedDescription))
        }
    }

    // MARK: - Refresh when a limit resets

    private func scheduleResetRefresh(for data: UsageData) {
        cancelResetRefresh()
        // A fetch that finishes after sign-out must not schedule another request.
        guard !isStopped, let reset = data.nextReset(after: now()) else { return }
        let date = reset.addingTimeInterval(Self.resetRefreshDelay)
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resetTimer = timer
        resetRefreshDate = date
    }

    private func cancelResetRefresh() {
        resetTimer?.invalidate()
        resetTimer = nil
        resetRefreshDate = nil
    }
}
