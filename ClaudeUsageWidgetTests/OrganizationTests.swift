import XCTest
@testable import ClaudeUsageWidget

final class OrganizationTests: XCTestCase {

    private func orgs(_ json: String) throws -> [Organization] {
        try Organization.decodeList(from: Data(json.utf8))
    }

    func test_decodeList_readsRealShape() throws {
        let list = try orgs(Fixtures.twoOrgsJSON)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[1].uuid, "chat-org")
        XCTAssertEqual(list[1].name, "Personal")
        XCTAssertEqual(list[1].rateLimitTier, "default_claude_max_20x")
        XCTAssertNil(list[1].planDisplayName)
        XCTAssertTrue(list[1].isChatOrg)
        XCTAssertFalse(list[0].isChatOrg)
    }

    func test_decodeList_toleratesMissingOptionalFields() throws {
        let list = try orgs(#"[{"uuid":"x","capabilities":["chat"]}]"#)
        XCTAssertEqual(list.first?.displayName, "Claude")
        XCTAssertEqual(list.first?.isChatOrg, true)
    }

    func test_pick_consoleFirst_picksChatOrg() throws {
        let picked = Organization.pickChatOrg(from: try orgs(Fixtures.twoOrgsJSON), lastActiveOrgId: nil)
        XCTAssertEqual(picked?.uuid, "chat-org")
    }

    func test_pick_lastActivePointsAtConsoleOrg_fallsBackToFirstChatOrg() throws {
        let picked = Organization.pickChatOrg(from: try orgs(Fixtures.twoOrgsJSON), lastActiveOrgId: "console-org")
        XCTAssertEqual(picked?.uuid, "chat-org")
    }

    func test_pick_twoChatOrgs_lastActiveWins() throws {
        let picked = Organization.pickChatOrg(from: try orgs(Fixtures.twoChatOrgsJSON), lastActiveOrgId: "chat-b")
        XCTAssertEqual(picked?.uuid, "chat-b")
    }

    func test_pick_twoChatOrgs_noLastActive_firstWins() throws {
        let picked = Organization.pickChatOrg(from: try orgs(Fixtures.twoChatOrgsJSON), lastActiveOrgId: nil)
        XCTAssertEqual(picked?.uuid, "chat-a")
    }

    func test_pick_consoleOnly_isNil() throws {
        XCTAssertNil(Organization.pickChatOrg(from: try orgs(Fixtures.consoleOnlyJSON), lastActiveOrgId: "console-org"))
    }

    func test_pick_empty_isNil() throws {
        XCTAssertNil(Organization.pickChatOrg(from: try orgs(Fixtures.emptyOrgsJSON), lastActiveOrgId: nil))
    }
}
