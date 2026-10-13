import AppKit

/// Something that reports mouse-downs happening outside this app.
@MainActor
protocol OutsideClickMonitoring: AnyObject {
    var isMonitoring: Bool { get }
    /// Replaces any earlier handler; never stacks.
    func start(onClick: @escaping @MainActor () -> Void)
    func stop()
}

/// A global NSEvent monitor. It sees mouse-downs delivered to other apps (their windows, the desktop, the
/// menu bar) and never this app's own, so clicks inside the popover and on the status item are not reported.
/// Mouse monitors need no Accessibility permission.
@MainActor
final class GlobalClickMonitor: OutsideClickMonitoring {
    private var token: Any?

    var isMonitoring: Bool { token != nil }

    func start(onClick: @escaping @MainActor () -> Void) {
        stop()
        token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            Task { @MainActor in onClick() }
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Closes the popover when the user clicks anywhere outside it.
/// `.transient` alone does not do this for a menu bar app: the app is never active, so AppKit does not
/// see the click that should dismiss the popover.
@MainActor
final class OutsideClickDismisser {
    private let monitor: OutsideClickMonitoring
    private let isShown: () -> Bool
    private let close: () -> Void

    init(monitor: OutsideClickMonitoring? = nil, isShown: @escaping () -> Bool, close: @escaping () -> Void) {
        self.monitor = monitor ?? GlobalClickMonitor()
        self.isShown = isShown
        self.close = close
    }

    /// Call from NSPopoverDelegate.popoverDidShow.
    func popoverDidShow() {
        monitor.start { [weak self] in self?.handleOutsideClick() }
    }

    /// Call from NSPopoverDelegate.popoverDidClose, however the popover was closed.
    func popoverDidClose() {
        monitor.stop()
    }

    private func handleOutsideClick() {
        guard isShown() else {
            monitor.stop()
            return
        }
        close()
    }
}
