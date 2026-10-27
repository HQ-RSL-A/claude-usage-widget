import AppKit
import ServiceManagement

/// The app's own login item. A protocol so tests never touch the real Login Items.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// "Open at Login" in the settings menu. Off until the user ticks it: the app never registers itself.
@MainActor
final class OpenAtLogin {
    private let service: LoginItemService
    private let openSettings: () -> Void
    private let beep: () -> Void

    init(
        service: LoginItemService = SMAppService.mainApp,
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() },
        beep: @escaping () -> Void = { NSSound.beep() }
    ) {
        self.service = service
        self.openSettings = openSettings
        self.beep = beep
    }

    var isEnabled: Bool { service.status == .enabled }

    func toggle() {
        do {
            if isEnabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { openSettings() }
            }
        } catch {
            // Switched off in System Settings: only the user can turn it back on there.
            if service.status == .requiresApproval { openSettings() } else { beep() }
        }
    }
}
