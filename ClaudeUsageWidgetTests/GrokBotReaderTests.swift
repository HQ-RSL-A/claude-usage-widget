import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class GrokBotReaderTests: XCTestCase {

    private static let slotKey = "sand.client.slice.client-meta.account-slot"
    private static let slot = "google-oauth2%7Cuser_X"

    /// The weekly usage file as Grok Bot saves it (verified 2026-11-04).
    /// 7.04% used, read at 1793824425.618, resets at 1794345715.756.
    private static let usageJSON = #"""
    {"schemaVersion":2,"value":{"kind":"present","selectedTeamId":null,
     "reading":{"usage":{"percentUsed":7.04,"nextResetMs":1794345715756,
     "isSandTrial":false,"hasNonZeroIncludedLimit":true,"isTeamSeat":false,
     "onDemand":null,"grokPlanLabel":"Grok Bot Plan","unifiedPlanName":"Premium"},
     "readAtMs":1793824425618},"expiresAtMs":1793910825946}}
    """#

    private static let readAt = Date(timeIntervalSince1970: 1793824425.618)
    private static let resetsAt = Date(timeIntervalSince1970: 1794345715.756)
    private static let formatChanged = ServiceState.unavailable(reason: "Grok Bot changed how it saves usage")

    /// A fresh folder for every test, standing in for Grok Bot's. The real one under ~/Library is never read.
    private var directory: URL!
    private var reader: GrokBotReader!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.rsla.ClaudeUsageWidget.tests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reader = GrokBotReader(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        reader = nil
        directory = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Saves `json` the way Grok Bot does: in a file named after the base32 of its key.
    private func write(_ json: String, key: String) throws {
        try Data(json.utf8).write(to: directory.appendingPathComponent(GrokBotReader.blobName(forKey: key)))
    }

    private func writeSlot() throws {
        try write(#"{"schemaVersion":1,"value":"\#(Self.slot)"}"#, key: Self.slotKey)
    }

    /// The sample for the signed-in account, unless told otherwise.
    private func writeUsage(_ json: String? = nil, slot: String? = nil) throws {
        try write(json ?? Self.usageJSON, key: "sand.client.slice.account.\(slot ?? Self.slot).weekly-usage.cache")
    }

    /// The sample with one piece swapped. Fails the test when that piece is not in the sample, so a typo here cannot pass quietly.
    private func sample(replacing target: String, with replacement: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        XCTAssertTrue(Self.usageJSON.contains(target), "The sample has no \(target)", file: file, line: line)
        return Self.usageJSON.replacingOccurrences(of: target, with: replacement)
    }

    private func reading(_ state: ServiceState, file: StaticString = #filePath, line: UInt = #line) -> (limits: [ServiceLimit], readAt: Date)? {
        guard case .reading(let limits, let readAt) = state else {
            XCTFail("Expected a reading, got \(state)", file: file, line: line)
            return nil
        }
        return (limits, readAt)
    }

    // MARK: - File names

    func testBase32MatchesGrokBotFileNames() {
        // Both names were read off a real Grok Bot folder.
        XCTAssertEqual(Base32.lowercaseNoPadding(Data("sand.client.slice.ui-layout".utf8)),
                       "onqw4zbomnwgszlooqxhg3djmnss45ljfvwgc6lpov2a")
        XCTAssertEqual(Base32.lowercaseNoPadding(Data("sand.client.slice.client-meta.account-slot".utf8)),
                       "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a")
        XCTAssertEqual(GrokBotReader.blobName(forKey: "sand.client.slice.ui-layout"),
                       "onqw4zbomnwgszlooqxhg3djmnss45ljfvwgc6lpov2a.blob")
    }

    func testBase32MatchesTheRFC4648Vectors() {
        // RFC 4648 section 10, lowercased and without padding. The two real names above both leave two bytes over,
        // so these cover every other length, plus bytes with the top bit set.
        let vectors: [(Data, String)] = [
            (Data(), ""),
            (Data("f".utf8), "my"),
            (Data("fo".utf8), "mzxq"),
            (Data("foo".utf8), "mzxw6"),
            (Data("foob".utf8), "mzxw6yq"),
            (Data("fooba".utf8), "mzxw6ytb"),
            (Data("foobar".utf8), "mzxw6ytboi"),
            (Data([0x00]), "aa"),
            (Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF]), "77777777"),
        ]
        for (plain, encoded) in vectors {
            XCTAssertEqual(Base32.lowercaseNoPadding(plain), encoded, "for \([UInt8](plain))")
        }
    }

    func testDefaultDirectoryIsGrokBotsOwnFolder() {
        // Only the path is checked. Nothing in the real folder is opened.
        let url = GrokBotReader.defaultDirectory
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/Grok Bot/sand-client-persistence"), url.path)
    }

    func testServiceIsGrokBot() {
        XCTAssertEqual(reader.service, .grokBot)
    }

    // MARK: - Reading usage

    func testReadsWeeklyUsage() async throws {
        try writeSlot()
        try writeUsage()

        let state = await reader.read()

        let result = try XCTUnwrap(reading(state))
        XCTAssertEqual(result.readAt, Self.readAt)
        XCTAssertEqual(result.limits.count, 1)
        let weekly = try XCTUnwrap(result.limits.first)
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.percentUsed, 0.0704, accuracy: 1e-9, "Grok Bot says 7.04 out of 100")
        XCTAssertEqual(weekly.resetsAt, Self.resetsAt)
        XCTAssertFalse(weekly.isBudget)
    }

    func testExpiredReadingIsStillReported() async throws {
        // Grok Bot's own copy expires a day after it was read. Saying how old a reading is belongs to the panel;
        // this reader never drops one or stamps it with the current time.
        try writeSlot()
        try writeUsage(sample(replacing: #""expiresAtMs":1793910825946"#, with: #""expiresAtMs":1"#))

        let state = await reader.read()

        let result = try XCTUnwrap(reading(state))
        XCTAssertEqual(result.readAt, Self.readAt)
        XCTAssertEqual(try XCTUnwrap(result.limits.first).percentUsed, 0.0704, accuracy: 1e-9)
    }

    func testMissingResetTimeLeavesTheResetEmpty() async throws {
        try writeSlot()
        try writeUsage(sample(replacing: #""nextResetMs":1794345715756"#, with: #""nextResetMs":null"#))

        let state = await reader.read()

        let result = try XCTUnwrap(reading(state))
        XCTAssertEqual(result.readAt, Self.readAt)
        let weekly = try XCTUnwrap(result.limits.first)
        XCTAssertEqual(weekly.percentUsed, 0.0704, accuracy: 1e-9)
        XCTAssertNil(weekly.resetsAt)
    }

    // MARK: - The slot in the file name

    /// Found on the real Mac (2026-11-04): the account-slot blob holds the slot as typed, "google-oauth2|user_X", but
    /// Grok Bot names the usage file after it with every unsafe character escaped, "google-oauth2%7Cuser_X". Looking for
    /// the slot as saved found no file, and the panel told a person whose usage was there to open Grok Bot.
    func testSlotHoldingAnUnescapedCharacterFindsItsEscapedFileName() async throws {
        try write(#"{"schemaVersion":1,"value":"google-oauth2|user_X"}"#, key: Self.slotKey)
        try writeUsage(slot: "google-oauth2%7Cuser_X")

        let state = await reader.read()

        let result = try XCTUnwrap(reading(state))
        XCTAssertEqual(result.readAt, Self.readAt)
        XCTAssertEqual(try XCTUnwrap(result.limits.first).percentUsed, 0.0704, accuracy: 1e-9)
    }

    /// A slot saved already escaped (what the spec first assumed) is still found, as saved.
    func testSlotThatIsAlreadyEscapedIsFoundAsSaved() async throws {
        try writeSlot()   // "google-oauth2%7Cuser_X"
        try writeUsage()

        let state = await reader.read()

        XCTAssertEqual(try XCTUnwrap(reading(state)).readAt, Self.readAt)
    }

    /// A slot with nothing to escape is the same either way.
    func testSlotWithNothingToEscapeIsFound() async throws {
        try write(#"{"schemaVersion":1,"value":"user_X-1.2"}"#, key: Self.slotKey)
        try writeUsage(slot: "user_X-1.2")

        let state = await reader.read()

        XCTAssertEqual(try XCTUnwrap(reading(state)).readAt, Self.readAt)
    }

    /// Another account's usage in the folder is still not shown for the account signed in now, however the slot is spelled.
    func testAnotherAccountsUsageIsNotShownForAnUnescapedSlot() async throws {
        try write(#"{"schemaVersion":1,"value":"google-oauth2|user_X"}"#, key: Self.slotKey)
        try writeUsage(slot: "google-oauth2%7Cuser_Y")

        let state = await reader.read()

        XCTAssertEqual(state, .notSignedIn(hint: "Open Grok Bot to load its usage"))
    }

    /// The escaping is a browser's `encodeURIComponent`: everything but letters, digits and `- _ . ! ~ * ' ( )`, as UTF-8.
    func testFileNameSlotEscapesLikeEncodeURIComponent() {
        XCTAssertEqual(GrokBotReader.fileNameSlot(for: "google-oauth2|user_X"), "google-oauth2%7Cuser_X")
        XCTAssertEqual(GrokBotReader.fileNameSlot(for: "a b|c@d:e/f.g-h_i!j~k*l'm(n)o"), "a%20b%7Cc%40d%3Ae%2Ff.g-h_i!j~k*l'm(n)o")
        XCTAssertEqual(GrokBotReader.fileNameSlot(for: "caf\u{E9}|\u{1F600}"), "caf%C3%A9%7C%F0%9F%98%80")
        XCTAssertEqual(GrokBotReader.fileNameSlot(for: "100%"), "100%25", "a literal percent sign is escaped too")
        XCTAssertEqual(GrokBotReader.fileNameSlot(for: "plain"), "plain")
    }

    // MARK: - Nothing to show yet

    func testMissingSlotSaysSignIn() async throws {
        // The usage file is there, but with no account slot the reader cannot tell whose it is, so it never guesses.
        try writeUsage()

        let state = await reader.read()

        XCTAssertEqual(state, .notSignedIn(hint: "Open Grok Bot and sign in"))
    }

    func testSlotWithoutAnAccountSaysSignIn() async throws {
        try writeUsage()
        for json in [#"{"schemaVersion":1,"value":null}"#, #"{"schemaVersion":1}"#, #"{"schemaVersion":1,"value":""}"#] {
            try write(json, key: Self.slotKey)

            let state = await reader.read()

            XCTAssertEqual(state, .notSignedIn(hint: "Open Grok Bot and sign in"), "for \(json)")
        }
    }

    func testMissingUsageBlobSaysOpenGrokBot() async throws {
        // Another account's usage is in the folder. It must not be shown for the account that is signed in now.
        try writeSlot()
        try writeUsage(slot: "google-oauth2%7Cuser_Y")

        let state = await reader.read()

        XCTAssertEqual(state, .notSignedIn(hint: "Open Grok Bot to load its usage"))
    }

    func testUnknownKindSaysOpenGrokBot() async throws {
        try writeSlot()
        try writeUsage(#"{"schemaVersion":2,"value":{"kind":"absent"}}"#)
        let absent = await reader.read()
        XCTAssertEqual(absent, .notSignedIn(hint: "Open Grok Bot to load its usage"))

        // A kind this version has never seen counts the same, even with a reading beside it.
        try writeUsage(sample(replacing: #""kind":"present""#, with: #""kind":"stale""#))
        let unknown = await reader.read()
        XCTAssertEqual(unknown, .notSignedIn(hint: "Open Grok Bot to load its usage"))
    }

    // MARK: - Not shown

    func testNewSchemaSaysFormatChanged() async throws {
        try writeSlot()
        try writeUsage(sample(replacing: #""schemaVersion":2"#, with: #""schemaVersion":3"#))

        let state = await reader.read()

        XCTAssertEqual(state, Self.formatChanged)
    }

    func testBlobsThatCannotBeReadSayFormatChanged() async throws {
        // The usage blob: empty, not JSON, the wrong shape, and a number saved as text.
        try writeSlot()
        let brokenUsage = ["", "not json", "[]", sample(replacing: #""percentUsed":7.04"#, with: #""percentUsed":"7.04""#)]
        for json in brokenUsage {
            try writeUsage(json)

            let state = await reader.read()

            XCTAssertEqual(state, Self.formatChanged, "usage blob: \(json)")
        }

        // The account slot: the same, and a version this reader does not know.
        try writeUsage()
        let brokenSlot = ["", "not json", #"{"schemaVersion":1,"value":7}"#, #"{"schemaVersion":2,"value":"\#(Self.slot)"}"#]
        for json in brokenSlot {
            try write(json, key: Self.slotKey)

            let state = await reader.read()

            XCTAssertEqual(state, Self.formatChanged, "slot blob: \(json)")
        }
    }

    func testPresentUsageMissingWhatItNeedsSaysFormatChanged() async throws {
        try writeSlot()
        let shapes = [
            #"{"schemaVersion":2,"value":{"kind":"present"}}"#,                                                                   // no reading
            #"{"schemaVersion":2,"value":{"kind":"present","reading":{"readAtMs":1793824425618}}}"#,                               // no usage
            #"{"schemaVersion":2,"value":{"kind":"present","reading":{"usage":{"hasNonZeroIncludedLimit":true},"readAtMs":1}}}"#,  // no percent
            #"{"schemaVersion":2,"value":{"kind":"present","reading":{"usage":{"percentUsed":7.04}}}}"#,                           // no read time
        ]
        for json in shapes {
            try writeUsage(json)

            let state = await reader.read()

            XCTAssertEqual(state, Self.formatChanged, "usage blob: \(json)")
        }
    }

    func testNoIncludedLimit() async throws {
        try writeSlot()
        try writeUsage(sample(replacing: #""hasNonZeroIncludedLimit":true"#, with: #""hasNonZeroIncludedLimit":false"#))

        let state = await reader.read()

        XCTAssertEqual(state, .unavailable(reason: "No usage limit on this plan"))
    }

    // MARK: - Set up

    func testIsSetUpFollowsDirectory() throws {
        let folder = directory.appendingPathComponent("sand-client-persistence", isDirectory: true)
        let notYetThere = GrokBotReader(directory: folder)

        XCTAssertFalse(notYetThere.isSetUp(), "Grok Bot is not on this Mac: its folder is not there")

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(notYetThere.isSetUp(), "The same reader sees the folder once Grok Bot makes it, even with nothing saved in it yet")

        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        XCTAssertFalse(notYetThere.isSetUp(), "A file with the folder's name is not Grok Bot's folder")
    }
}
