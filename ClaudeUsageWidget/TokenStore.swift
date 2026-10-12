import Foundation
import Security

/// Where the widget's own OAuth tokens live. Implemented by the Keychain in the app and in memory in tests.
protocol TokenStoring: AnyObject {
    func load() throws -> TokenSet?
    func save(_ tokens: TokenSet) throws
    func clear() throws
}

final class KeychainTokenStore: TokenStoring {
    private let service: String
    private let account: String

    init(service: String = "io.rsla.ClaudeUsageWidget", account: String = "oauth") {
        self.service = service
        self.account = account
    }

    func load() throws -> TokenSet? {
        guard let data = try KeychainItem.read(service: service, account: account) else { return nil }
        do {
            return try JSONDecoder().decode(TokenSet.self, from: data)
        } catch {
            try? clear()   // unreadable item: drop it, the user signs in again
            return nil
        }
    }

    func save(_ tokens: TokenSet) throws {
        try KeychainItem.write(try JSONEncoder().encode(tokens), service: service, account: account)
    }

    func clear() throws {
        try KeychainItem.delete(service: service, account: account)
    }
}

/// Generic-password helpers. A missing item reads as nil; any other failure is ClaudeAPIError.keychain(status).
enum KeychainItem {
    static func read(service: String, account: String?) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ClaudeAPIError.keychain(status) }
        return item as? Data
    }

    static func write(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ClaudeAPIError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw ClaudeAPIError.keychain(status)
        }
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClaudeAPIError.keychain(status) }
    }
}
