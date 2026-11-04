import XCTest
@testable import ClaudeUsageWidget

final class ClaudeCodeCredentialsTests: XCTestCase {

    func test_parse_readsRealShape_millisecondsExpiry() throws {
        let token = try XCTUnwrap(ClaudeCodeToken.parse(Data(Fixtures.claudeCodeCredentialsJSON.utf8)))
        XCTAssertEqual(token.accessToken, "cc-access")
        XCTAssertEqual(token.subscriptionType, "max")
        XCTAssertEqual(token.expiresAt, Date(timeIntervalSince1970: 4_102_444_800))
        XCTAssertTrue(token.isValid)
    }

    func test_parse_expiredToken_isNotValid() throws {
        let token = try XCTUnwrap(ClaudeCodeToken.parse(Data(Fixtures.claudeCodeExpiredJSON.utf8)))
        XCTAssertFalse(token.isValid)
    }

    func test_parse_withoutOauthBlock_isNil() throws {
        XCTAssertNil(try ClaudeCodeToken.parse(Data(#"{"somethingElse":{}}"#.utf8)))
    }

    func test_parse_garbage_throws() {
        XCTAssertThrowsError(try ClaudeCodeToken.parse(Data("not json".utf8)))
    }

    func test_exists_isFalseForMissingItem_andTrueWithoutReadingTheSecret() throws {
        XCTAssertFalse(SecurityToolClaudeCodeCredentials(service: "io.rsla.ClaudeUsageWidget.tests.absent").exists())
        let service = "io.rsla.ClaudeUsageWidget.tests.exists"
        addTeardownBlock { try? KeychainItem.delete(service: service, account: "x") }
        try KeychainItem.write(Data("{}".utf8), service: service, account: "x")
        XCTAssertTrue(SecurityToolClaudeCodeCredentials(service: service).exists())
    }

    // MARK: - Reading through /usr/bin/security (v0.5.1)

    /// Claude Code writes its item with /usr/bin/security, so the item trusts that tool and nothing else
    /// for good: each token refresh resets "Always Allow" for any other app. Asking the tool never prompts.
    func test_reader_asksTheSecurityTool_forClaudeCodesItem() async throws {
        let runner = FakeProcessRunner(ProcessResult(ending: .exited(0), output: Data((Fixtures.claudeCodeCredentialsJSON + "\n").utf8)))
        let token = try await SecurityToolClaudeCodeCredentials(runner: runner).read()
        XCTAssertEqual(token?.accessToken, "cc-access")
        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.executable.path, "/usr/bin/security")
        XCTAssertEqual(runner.calls.first?.arguments, ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
        XCTAssertEqual(runner.calls.first?.timeout, 10)
    }

    func test_reader_unparseableOutput_isNil() async throws {
        let runner = FakeProcessRunner(ProcessResult(ending: .exited(0), output: Data("not json\n".utf8)))
        let token = try await SecurityToolClaudeCodeCredentials(runner: runner).read()
        XCTAssertNil(token)
    }

    /// errSecItemNotFound (-25300) leaves the tool as exit status 44.
    func test_reader_itemNotFound_isNil() async throws {
        let runner = FakeProcessRunner(ProcessResult(ending: .exited(44), output: Data()))
        let token = try await SecurityToolClaudeCodeCredentials(runner: runner).read()
        XCTAssertNil(token)
    }

    func test_reader_refused_throwsKeychain() async {
        let runner = FakeProcessRunner(ProcessResult(ending: .exited(51), output: Data()))
        await assertThrowsKeychain(SecurityToolClaudeCodeCredentials(runner: runner))
    }

    /// The tool only hangs if macOS shows it a password dialog after all: give up rather than wait forever.
    func test_reader_timeout_throwsKeychain() async {
        let runner = FakeProcessRunner(ProcessResult(ending: .timedOut, output: Data()))
        await assertThrowsKeychain(SecurityToolClaudeCodeCredentials(runner: runner))
    }

    func test_reader_launchFailure_throwsKeychain() async {
        let runner = FakeProcessRunner(ProcessResult(ending: .failedToLaunch, output: Data()))
        await assertThrowsKeychain(SecurityToolClaudeCodeCredentials(runner: runner))
    }

    // MARK: - The real tool, test services only

    func test_reader_roundTrip_withTheRealTool() async throws {
        let service = "io.rsla.ClaudeUsageWidget.tests.claudecode"
        try runSecurity(["add-generic-password", "-U", "-s", service, "-a", "test", "-w", Fixtures.claudeCodeCredentialsJSON])
        addTeardownBlock { [self] in try? runSecurity(["delete-generic-password", "-s", service, "-a", "test"]) }
        let token = try await SecurityToolClaudeCodeCredentials(service: service).read()
        XCTAssertEqual(token?.accessToken, "cc-access")
        XCTAssertEqual(token?.expiresAt, Date(timeIntervalSince1970: 4_102_444_800))
    }

    func test_reader_missingItem_withTheRealTool_isNil() async throws {
        let token = try await SecurityToolClaudeCodeCredentials(service: "io.rsla.ClaudeUsageWidget.tests.absent").read()
        XCTAssertNil(token)
    }

    func test_processRunner_returnsOutputAndExitStatus() async {
        let echo = await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["hello"], timeout: 5)
        XCTAssertEqual(echo.ending, .exited(0))
        XCTAssertEqual(String(data: echo.output, encoding: .utf8), "hello\n")
        let failing = await ProcessRunner().run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 5)
        XCTAssertEqual(failing.ending, .exited(1))
    }

    func test_processRunner_stopsTheProcessAtTheTimeout() async {
        let start = Date()
        let result = await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.3)
        XCTAssertEqual(result.ending, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func test_processRunner_missingExecutable_failsToLaunch() async {
        let result = await ProcessRunner().run(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [], timeout: 5)
        XCTAssertEqual(result.ending, .failedToLaunch)
    }

    // MARK: - Helpers

    private func assertThrowsKeychain(_ reader: SecurityToolClaudeCodeCredentials, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await reader.read()
            XCTFail("expected a throw", file: file, line: line)
        } catch ClaudeAPIError.keychain {
            // the denied handling in AuthManager takes it from here
        } catch {
            XCTFail("expected ClaudeAPIError.keychain, got \(error)", file: file, line: line)
        }
    }

    /// Runs /usr/bin/security for test setup. Output is discarded, never printed.
    private func runSecurity(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "security", code: Int(process.terminationStatus))
        }
    }
}

final class FakeProcessRunner: ProcessRunning {
    struct Call {
        let executable: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    var result: ProcessResult
    private(set) var calls: [Call] = []

    init(_ result: ProcessResult) { self.result = result }

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
        return result
    }
}
