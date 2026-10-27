import XCTest
import ServiceManagement
@testable import ClaudeUsageWidget

@MainActor
final class OpenAtLoginTests: XCTestCase {

    private final class FakeLoginItemService: LoginItemService {
        var status: SMAppService.Status = .notRegistered
        var statusAfterRegister: SMAppService.Status = .enabled
        var registerError: Error?
        private(set) var registers = 0
        private(set) var unregisters = 0

        func register() throws {
            registers += 1
            if let registerError { throw registerError }
            status = statusAfterRegister
        }

        func unregister() throws {
            unregisters += 1
            status = .notRegistered
        }
    }

    private var service: FakeLoginItemService!
    private var settingsOpened = 0
    private var beeps = 0
    private var openAtLogin: OpenAtLogin!

    override func setUp() {
        super.setUp()
        service = FakeLoginItemService()
        settingsOpened = 0
        beeps = 0
        openAtLogin = OpenAtLogin(
            service: service,
            openSettings: { [unowned self] in self.settingsOpened += 1 },
            beep: { [unowned self] in self.beeps += 1 }
        )
    }

    func test_isEnabled_followsStatus() {
        XCTAssertFalse(openAtLogin.isEnabled)
        service.status = .enabled
        XCTAssertTrue(openAtLogin.isEnabled)
        service.status = .requiresApproval
        XCTAssertFalse(openAtLogin.isEnabled)
    }

    func test_toggle_whenOff_registers() {
        openAtLogin.toggle()
        XCTAssertEqual(service.registers, 1)
        XCTAssertTrue(openAtLogin.isEnabled)
        XCTAssertEqual(beeps, 0)
    }

    func test_toggle_whenOn_unregisters() {
        service.status = .enabled
        openAtLogin.toggle()
        XCTAssertEqual(service.unregisters, 1)
        XCTAssertFalse(openAtLogin.isEnabled)
    }

    func test_toggle_needingApproval_opensSettings() {
        service.statusAfterRegister = .requiresApproval
        openAtLogin.toggle()
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertFalse(openAtLogin.isEnabled)
    }

    /// macOS refuses the registration when the user switched the item off in System Settings.
    func test_toggle_refusedButNeedingApproval_opensSettings() {
        service.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        service.status = .requiresApproval
        openAtLogin.toggle()
        XCTAssertEqual(settingsOpened, 1)
        XCTAssertEqual(beeps, 0)
    }

    func test_toggle_failure_beeps() {
        service.registerError = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        openAtLogin.toggle()
        XCTAssertEqual(beeps, 1)
        XCTAssertEqual(settingsOpened, 0)
        XCTAssertFalse(openAtLogin.isEnabled)
    }
}
