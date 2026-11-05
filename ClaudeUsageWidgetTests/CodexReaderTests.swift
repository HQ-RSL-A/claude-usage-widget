import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class CodexReaderTests: XCTestCase {

    private static let now = Date(timeIntervalSince1970: 1_793_900_000)

    private static let signInHint = ServiceState.notSignedIn(hint: "Open Codex and sign in with ChatGPT")
    private static let chatGPTHint = ServiceState.notSignedIn(hint: "Sign in to Codex with ChatGPT")
    private static let refreshHint = ServiceState.notSignedIn(hint: "Open Codex to refresh its sign-in")
    private static let unreachable = ServiceState.unavailable(reason: "Couldn't reach Codex")
    private static let formatChanged = ServiceState.unavailable(reason: "Codex changed its usage format")

    /// Codex's sign-in file, with only the two fields the reader uses.
    private static let authJSON = #"{"tokens":{"access_token":"at","account_id":"acc"}}"#

    /// ChatGPT's usage answer: 12% of the 5 hour window used, 40% of the weekly one.
    private static let usageJSON = #"""
    {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1794000000},
     "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1794500000}}}
    """#

    /// A fresh folder for every test, standing in for Codex's. The real `~/.codex` is never read.
    private var directory: URL!
    private var authFile: URL!
    private var reader: CodexReader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        StubURLProtocol.reset()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.rsla.ClaudeUsageWidget.tests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        authFile = directory.appendingPathComponent("auth.json")
        reader = makeReader()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        reader = nil
        authFile = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeReader(session: URLSession = StubURLProtocol.session()) -> CodexReader {
        CodexReader(authFile: authFile, session: session, now: { CodexReaderTests.now })
    }

    private func writeAuth(_ json: String) throws {
        try Data(json.utf8).write(to: authFile)
    }

    /// Makes ChatGPT answer every usage request with `status` and `body`, the sample answer unless told otherwise.
    private func stubUsage(status: Int = 200, _ body: String? = nil) {
        let answer = Data((body ?? Self.usageJSON).utf8)
        StubURLProtocol.handler = { _ in (status: status, body: answer) }
    }

    /// A usage answer with only a primary window, made of `fields`.
    private func primaryOnly(_ fields: String) -> String {
        #"{"rate_limit":{"primary_window":{\#(fields)}}}"#
    }

    private func limits(of state: ServiceState, file: StaticString = #filePath, line: UInt = #line) -> [ServiceLimit]? {
        guard case .reading(let limits, _) = state else {
            XCTFail("Expected a reading, got \(state)", file: file, line: line)
            return nil
        }
        return limits
    }

    private func modificationDate(of url: URL) throws -> Date {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
    }

    // MARK: - What the reader is

    func testServiceIsCodex() {
        XCTAssertEqual(reader.service, .codex)
    }

    func testUsageURLIsChatGPTs() {
        XCTAssertEqual(CodexReader.usageURL.absoluteString, "https://chatgpt.com/backend-api/wham/usage")
    }

    func testAuthFileIsInCodexHomeWhenSetElseInTheHomeFolder() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

        XCTAssertEqual(CodexReader.authFileURL(codexHome: "/elsewhere/codex", home: home).path, "/elsewhere/codex/auth.json")
        XCTAssertEqual(CodexReader.authFileURL(codexHome: nil, home: home).path, "/Users/someone/.codex/auth.json")
        // Codex reads an empty CODEX_HOME as not set, so this does too.
        XCTAssertEqual(CodexReader.authFileURL(codexHome: "", home: home).path, "/Users/someone/.codex/auth.json")
    }

    func testDefaultAuthFileIsNamedAuthJson() {
        // Only the path is checked. Nothing in the real folder is opened.
        let url = CodexReader.defaultAuthFile
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(url.lastPathComponent, "auth.json")
    }

    // MARK: - The request

    func testSendsTokenAndAccountHeaders() async throws {
        try writeAuth(Self.authJSON)
        stubUsage()

        _ = await reader.read()

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url, CodexReader.usageURL)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), OAuthConfig.userAgent)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, "A cached answer would show old numbers as current")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store", "Nothing that carries the token is kept")
    }

    func testDefaultSessionIsTheSharedOneThatKeepsNothingOnDisk() {
        // A reader made without a session of its own must not fall back to URLSession.shared: its disk cache keeps every
        // request's headers, the token included, in the app's Cache.db. Nothing is sent here, the reader is only made.
        let codex = CodexReader(authFile: authFile)

        XCTAssertTrue(codex.session === HTTP.session)
        XCTAssertNil(codex.session.configuration.urlCache, "No cache at all, so no Cache.db")
        // The poller reads one service after another, so a request that never ends would hold up the rest.
        XCTAssertEqual(codex.session.configuration.timeoutIntervalForResource, 30)
    }

    func testAccountHeaderIsLeftOutWithoutAnAccountId() async throws {
        let auths = [
            #"{"tokens":{"access_token":"at"}}"#,
            #"{"tokens":{"access_token":"at","account_id":null}}"#,
            #"{"tokens":{"access_token":"at","account_id":""}}"#,
        ]
        for auth in auths {
            StubURLProtocol.reset()
            stubUsage()
            try writeAuth(auth)

            _ = await reader.read()

            let request = try XCTUnwrap(StubURLProtocol.requests.first, "for \(auth)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer at", "for \(auth)")
            XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "for \(auth)")
        }
    }

    func testReadsTheAuthFileFreshEveryTime() async throws {
        stubUsage()
        try writeAuth(#"{"tokens":{"access_token":"first","account_id":"one"}}"#)
        _ = await reader.read()

        // Codex rewrites auth.json when it refreshes its token. The next read must send the new one.
        try writeAuth(#"{"tokens":{"access_token":"second","account_id":"two"}}"#)
        _ = await reader.read()

        XCTAssertEqual(StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer first", "Bearer second"])
        XCTAssertEqual(StubURLProtocol.requests.map { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") }, ["one", "two"])

        // Signing out of Codex removes the file, and the reader sees that at once.
        try FileManager.default.removeItem(at: authFile)
        let state = await reader.read()
        XCTAssertEqual(state, Self.signInHint)
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "Nothing is sent without a token")
    }

    // MARK: - Reading usage

    func testMapsWindows() async throws {
        try writeAuth(Self.authJSON)
        stubUsage()

        let state = await reader.read()

        XCTAssertEqual(state, .reading(limits: [
            ServiceLimit(label: "5hr Session", percentUsed: 0.12, resetsAt: Date(timeIntervalSince1970: 1794000000)),
            ServiceLimit(label: "Weekly", percentUsed: 0.40, resetsAt: Date(timeIntervalSince1970: 1794500000)),
        ], readAt: Self.now))
    }

    func testWindowLabelByLength() async throws {
        try writeAuth(Self.authJSON)
        // Six hours or less is the session, anything longer is the week. The label follows the length and not the slot:
        // a plan with only a weekly limit may send it as the primary window.
        let cases: [(seconds: Int, label: String)] = [
            (60, "5hr Session"), (18000, "5hr Session"), (21600, "5hr Session"),
            (21601, "Weekly"), (86400, "Weekly"), (604800, "Weekly"),
        ]
        for (seconds, label) in cases {
            stubUsage(primaryOnly(#""used_percent":50,"limit_window_seconds":\#(seconds),"reset_at":1794000000"#))

            let state = await reader.read()

            XCTAssertEqual(limits(of: state)?.map(\.label), [label], "for a window of \(seconds) s")
        }
    }

    func testMissingResetAtUsesResetAfterSeconds() async throws {
        try writeAuth(Self.authJSON)
        stubUsage(primaryOnly(#""used_percent":12,"limit_window_seconds":18000,"reset_after_seconds":600"#))

        let state = await reader.read()

        let limit = try XCTUnwrap(limits(of: state)?.first)
        XCTAssertEqual(limit.resetsAt, Self.now.addingTimeInterval(600))
        XCTAssertEqual(limit.percentUsed, 0.12, accuracy: 1e-9)
    }

    func testResetAtWinsWhenBothAreSent() async throws {
        try writeAuth(Self.authJSON)
        stubUsage(primaryOnly(#""used_percent":12,"limit_window_seconds":18000,"reset_at":1794000000,"reset_after_seconds":600"#))

        let state = await reader.read()

        XCTAssertEqual(limits(of: state)?.first?.resetsAt, Date(timeIntervalSince1970: 1794000000))
    }

    func testNoResetTimeLeavesTheResetEmpty() async throws {
        try writeAuth(Self.authJSON)
        stubUsage(primaryOnly(#""used_percent":12,"limit_window_seconds":18000"#))

        let state = await reader.read()

        let limit = try XCTUnwrap(limits(of: state)?.first)
        XCTAssertEqual(limit.percentUsed, 0.12, accuracy: 1e-9)
        XCTAssertNil(limit.resetsAt)
    }

    func testWindowWithoutWhatItNeedsIsLeftOut() async throws {
        try writeAuth(Self.authJSON)
        // The weekly window has no length, so it cannot be labeled. The session window still shows.
        stubUsage(#"""
        {"rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":1794000000},
         "secondary_window":{"used_percent":40,"reset_at":1794500000}}}
        """#)
        let noLength = await reader.read()
        XCTAssertEqual(limits(of: noLength)?.map(\.label), ["5hr Session"])

        // The same when the session window is the one with no number.
        stubUsage(#"""
        {"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_at":1794000000},
         "secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":1794500000}}}
        """#)
        let noPercent = await reader.read()
        XCTAssertEqual(limits(of: noPercent)?.map(\.label), ["Weekly"])
    }

    // MARK: - Nothing to show yet

    func testUnauthorizedSaysOpenCodex() async throws {
        try writeAuth(Self.authJSON)
        let bytes = try Data(contentsOf: authFile)
        let modified = try modificationDate(of: authFile)

        for status in [401, 403] {
            StubURLProtocol.requests = []
            stubUsage(status: status, #"{"detail":"Unauthorized"}"#)

            let state = await reader.read()

            XCTAssertEqual(state, Self.refreshHint, "for \(status)")
            // One request, to the usage endpoint. A refresh would be a second one, to OpenAI's sign-in service.
            XCTAssertEqual(StubURLProtocol.requests.map(\.url), [CodexReader.usageURL], "for \(status)")
        }

        // Codex owns auth.json. The reader never rewrites it, not even with the same bytes, and leaves nothing beside it.
        XCTAssertEqual(try Data(contentsOf: authFile), bytes)
        XCTAssertEqual(try modificationDate(of: authFile), modified)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["auth.json"])
    }

    func testEmptyOrJsonForbiddenKeepsTheRefreshHint() async throws {
        try writeAuth(Self.authJSON)
        // ChatGPT refusing a token answers with JSON, or with nothing. Whatever parses as JSON counts, however it is laid out.
        let bodies = ["", #"{"detail":"Forbidden"}"#, "\n  {\"detail\": \"Forbidden\"}\n", "[]"]
        for body in bodies {
            stubUsage(status: 403, body)

            let state = await reader.read()

            XCTAssertEqual(state, Self.refreshHint, "for a 403 with \(body.isEmpty ? "no body" : body)")
        }

        // The rule is about 403, the status Cloudflare blocks with. A 401 keeps its hint whatever it carries.
        stubUsage(status: 401, "<html><body>Unauthorized</body></html>")
        let unauthorized = await reader.read()
        XCTAssertEqual(unauthorized, Self.refreshHint)
    }

    func testApiKeyOnlyAuth() async throws {
        stubUsage()
        let auths = [
            #"{"OPENAI_API_KEY":"sk-x","tokens":null}"#,
            #"{"OPENAI_API_KEY":"sk-x"}"#,
            #"{"OPENAI_API_KEY":"sk-x","tokens":{}}"#,
            #"{"OPENAI_API_KEY":"sk-x","tokens":{"access_token":"","account_id":"acc"}}"#,
            "{}",
        ]
        for auth in auths {
            try writeAuth(auth)

            let state = await reader.read()

            XCTAssertEqual(state, Self.chatGPTHint, "for \(auth)")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty, "An API key is not a ChatGPT sign-in, so nothing is sent")
    }

    func testNoAuthFile() async {
        stubUsage()

        XCTAssertFalse(reader.isSetUp())
        let state = await reader.read()

        XCTAssertEqual(state, Self.signInHint)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// Codex rewrites auth.json whenever it renews its token, so a read can catch it half written, and a later Codex can
    /// save it in another shape. Either way the file is there: the sign-in is not gone, this read just cannot use it.
    /// "Couldn't reach Codex" is what lets the poller keep the last numbers until a later read gets the file whole;
    /// a sign-in hint would replace them. Only a missing file is a sign-out.
    func testAuthFileThatCannotBeReadSaysCouldntReach() async throws {
        stubUsage()
        // Empty, cut short, not JSON, the wrong shape, and a token of the wrong type.
        let auths = ["", #"{"tokens":{"access_to"#, "not json", "[]", #"{"tokens":"at"}"#, #"{"tokens":{"access_token":5}}"#]
        for auth in auths {
            try writeAuth(auth)

            let state = await reader.read()

            XCTAssertEqual(state, Self.unreachable, "for \(auth)")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// The same for a file that is there and cannot be opened at all.
    func testAuthFileThatCannotBeOpenedSaysCouldntReach() async throws {
        try XCTSkipIf(getuid() == 0, "root opens a file whatever its permissions")
        stubUsage()
        try writeAuth(Self.authJSON)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: authFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFile.path) }
        XCTAssertTrue(reader.isSetUp(), "the setup: the file is there")

        let state = await reader.read()

        XCTAssertEqual(state, Self.unreachable)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    /// A folder with the file's name is not Codex's sign-in (`isSetUp` says so too): no file, so no sign-in.
    func testFolderWithTheAuthFilesNameIsNoSignIn() async throws {
        stubUsage()
        try FileManager.default.createDirectory(at: authFile, withIntermediateDirectories: true)

        let state = await reader.read()

        XCTAssertEqual(state, Self.signInHint)
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    // MARK: - Not shown

    func testServerErrorAndBadBody() async throws {
        try writeAuth(Self.authJSON)

        stubUsage(status: 500, "")
        let serverError = await reader.read()
        XCTAssertEqual(serverError, Self.unreachable)

        stubUsage(status: 200, "{}")
        let empty = await reader.read()
        XCTAssertEqual(empty, Self.formatChanged)
    }

    func testOtherFailureStatusesSayCouldntReach() async throws {
        try writeAuth(Self.authJSON)
        for status in [404, 429, 502, 503] {
            stubUsage(status: status, #"{"detail":"nope"}"#)

            let state = await reader.read()

            XCTAssertEqual(state, Self.unreachable, "for \(status)")
        }
    }

    func testHtml403SaysCouldntReach() async throws {
        // Cloudflare answers a client it blocks or challenges with a 403 and a web page. That is not ChatGPT refusing the
        // token, so there is nothing for Codex to refresh, and "Open Codex to refresh its sign-in" would never go away.
        try writeAuth(Self.authJSON)
        let pages = [
            "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body></body></html>",
            "<html><body>Access denied</body></html>",
            "\r\n  <!DOCTYPE html><html></html>",   // a page that starts with blank space is still a page
        ]
        for page in pages {
            StubURLProtocol.requests = []
            stubUsage(status: 403, page)

            let state = await reader.read()

            XCTAssertEqual(state, Self.unreachable, "for \(page)")
            XCTAssertEqual(StubURLProtocol.requests.map(\.url), [CodexReader.usageURL], "one request, no retry, for \(page)")
        }
    }

    func testPlainText403SaysCouldntReach() async throws {
        // Cloudflare's 1010 block is a line of plain text, not a page. It is no more ChatGPT refusing the token than a page is,
        // so any 403 with something in it that does not parse as JSON says the same.
        try writeAuth(Self.authJSON)
        for body in ["error code: 1010", "Forbidden"] {
            StubURLProtocol.requests = []
            stubUsage(status: 403, body)

            let state = await reader.read()

            XCTAssertEqual(state, Self.unreachable, "for \(body)")
            XCTAssertEqual(StubURLProtocol.requests.map(\.url), [CodexReader.usageURL], "one request, no retry, for \(body)")
        }
    }

    func testTransportErrorSaysCouldntReach() async throws {
        try writeAuth(Self.authJSON)

        let state = await makeReader(session: FailingURLProtocol.session()).read()

        XCTAssertEqual(state, Self.unreachable)
    }

    func testAnswerWithNoUsableWindowSaysFormatChanged() async throws {
        try writeAuth(Self.authJSON)
        let bodies = [
            "",
            "not json",
            "[]",
            #"{"rate_limit":null}"#,
            #"{"rate_limit":{}}"#,
            #"{"rate_limit":{"primary_window":null,"secondary_window":null}}"#,
            #"{"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_at":1794000000}}}"#,   // no percent
            #"{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1794000000}}}"#,              // no length
            #"{"rate_limit":{"primary_window":{"used_percent":"12","limit_window_seconds":18000}}}"#,     // a number saved as text
        ]
        for body in bodies {
            stubUsage(body)

            let state = await reader.read()

            XCTAssertEqual(state, Self.formatChanged, "for \(body)")
        }
    }

    // MARK: - Set up

    func testIsSetUpFollowsAuthFile() throws {
        XCTAssertFalse(reader.isSetUp(), "Codex is not on this Mac: there is no sign-in file")

        try writeAuth(Self.authJSON)
        XCTAssertTrue(reader.isSetUp())

        // A file with only an API key still counts, so the panel can say how to sign in with ChatGPT.
        try writeAuth(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#)
        XCTAssertTrue(reader.isSetUp())

        try FileManager.default.removeItem(at: authFile)
        try FileManager.default.createDirectory(at: authFile, withIntermediateDirectories: true)
        XCTAssertFalse(reader.isSetUp(), "A folder with the file's name is not Codex's sign-in")
    }
}
