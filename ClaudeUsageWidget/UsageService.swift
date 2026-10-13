import Foundation

@MainActor
protocol UsageServiceDelegate: AnyObject {
    func usageService(_ service: UsageService, didUpdate data: UsageData)
    func usageService(_ service: UsageService, didFailWith error: ClaudeAPIError)
    func usageServiceDidDetectSessionExpiry(_ service: UsageService)
}

/// Polls the current identity's usage every five minutes. Stops itself and reports when the session is gone.
@MainActor
final class UsageService {
    weak var delegate: UsageServiceDelegate?

    var pollInterval: TimeInterval = 300
    private(set) var lastData: UsageData?
    private(set) var isPolling = false
    var identity: IdentitySource { source.identity }

    private let source: UsageSource
    private var timer: Timer?

    init(source: UsageSource) {
        self.source = source
    }

    func start() {
        stop()
        isPolling = true
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetch() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isPolling = false
    }

    /// Manual refresh trigger
    func fetch() {
        Task { await fetchNow() }
    }

    func fetchNow() async {
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
}
