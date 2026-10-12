import Foundation

/// One entry of GET /api/organizations. Only the fields the widget uses.
struct Organization: Decodable, Equatable {
    let uuid: String
    let name: String?
    let capabilities: [String]
    let rateLimitTier: String?
    let planDisplayName: String?

    private enum CodingKeys: String, CodingKey {
        case uuid, name, capabilities
        case rateLimitTier = "rate_limit_tier"
        case planDisplayName = "plan_display_name"
    }

    init(uuid: String, name: String?, capabilities: [String], rateLimitTier: String? = nil, planDisplayName: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.capabilities = capabilities
        self.rateLimitTier = rateLimitTier
        self.planDisplayName = planDisplayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        capabilities = try c.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        rateLimitTier = try c.decodeIfPresent(String.self, forKey: .rateLimitTier)
        planDisplayName = try c.decodeIfPresent(String.self, forKey: .planDisplayName)
    }

    /// Consumer (claude.ai chat) orgs carry "chat"; console orgs carry "api" and always 403 on usage.
    var isChatOrg: Bool { capabilities.contains("chat") }

    var displayName: String { name ?? "Claude" }

    /// The org claude.ai last had active, if it can chat; else the first chat org; else nil.
    static func pickChatOrg(from orgs: [Organization], lastActiveOrgId: String?) -> Organization? {
        let chatOrgs = orgs.filter(\.isChatOrg)
        if let id = lastActiveOrgId, let active = chatOrgs.first(where: { $0.uuid == id }) {
            return active
        }
        return chatOrgs.first
    }

    static func decodeList(from data: Data) throws -> [Organization] {
        try JSONDecoder().decode([Organization].self, from: data)
    }
}
