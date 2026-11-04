import Foundation

/// Reads Grok Bot's weekly usage from the file its Mac app saves, so it needs no token and no Keychain.
/// The reading is only as fresh as Grok Bot's last refresh: the app rewrites the file when its own window
/// refreshes, not on a timer. `ServiceID.staleAfter` and the panel deal with how old it is.
///
/// Only two of Grok Bot's files are ever opened: the account slot (which account is signed in) and that
/// account's weekly usage. `sand-secrets.json` and the "Grok Bot Safe Storage" Keychain item hold its sign-in
/// and are never touched.
@MainActor
final class GrokBotReader: ServiceReader {
    let service = ServiceID.grokBot

    /// Where Grok Bot keeps its saved state.
    nonisolated static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence", isDirectory: true)
    }

    /// Grok Bot saves every value in a file named after the base32 of its key.
    nonisolated static func blobName(forKey key: String) -> String {
        Base32.lowercaseNoPadding(Data(key.utf8)) + ".blob"
    }

    /// How Grok Bot spells an account slot inside a file name: every character but letters, digits and `- _ . ! ~ * ' ( )`
    /// escaped as UTF-8, a browser's `encodeURIComponent`. The account-slot blob holds the slot as typed
    /// ("google-oauth2|user"), the usage file's name has it escaped ("google-oauth2%7Cuser").
    nonisolated static func fileNameSlot(for slot: String) -> String {
        let unescaped = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return slot.addingPercentEncoding(withAllowedCharacters: unescaped) ?? slot
    }

    private static let slotKey = "sand.client.slice.client-meta.account-slot"
    private static let slotSchemaVersion = 1
    private static let usageSchemaVersion = 2

    private static let signInHint = "Open Grok Bot and sign in"
    private static let loadUsageHint = "Open Grok Bot to load its usage"
    private static let formatChangedReason = "Grok Bot changed how it saves usage"
    private static let noLimitReason = "No usage limit on this plan"

    private let directory: URL

    init(directory: URL = GrokBotReader.defaultDirectory) {
        self.directory = directory
    }

    /// True when Grok Bot's folder is on this Mac. Grok Bot signed out still counts: the panel then says how to sign in.
    func isSetUp() -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func read() async -> ServiceState {
        // Whose usage to look for.
        guard let slotData = blob(forKey: Self.slotKey) else { return .notSignedIn(hint: Self.signInHint) }
        guard let slotBlob = try? JSONDecoder().decode(RawSlotBlob.self, from: slotData),
              slotBlob.schemaVersion == Self.slotSchemaVersion else {
            return .unavailable(reason: Self.formatChangedReason)
        }
        guard let slot = slotBlob.value, !slot.isEmpty else { return .notSignedIn(hint: Self.signInHint) }

        // That account's weekly usage.
        guard let usageData = usageBlob(forSlot: slot) else { return .notSignedIn(hint: Self.loadUsageHint) }
        guard let usageBlob = try? JSONDecoder().decode(RawUsageBlob.self, from: usageData),
              usageBlob.schemaVersion == Self.usageSchemaVersion else {
            return .unavailable(reason: Self.formatChangedReason)
        }
        guard let value = usageBlob.value, value.kind == "present" else { return .notSignedIn(hint: Self.loadUsageHint) }
        guard let usage = value.reading?.usage else { return .unavailable(reason: Self.formatChangedReason) }
        if usage.hasNonZeroIncludedLimit == false { return .unavailable(reason: Self.noLimitReason) }
        guard let percentUsed = usage.percentUsed, let readAtMs = value.reading?.readAtMs else {
            return .unavailable(reason: Self.formatChangedReason)
        }

        // Grok Bot counts percent from 0 to 100 and time in milliseconds.
        let weekly = ServiceLimit(label: "Weekly", percentUsed: percentUsed / 100,
                                  resetsAt: usage.nextResetMs.map(Self.date(milliseconds:)))
        return .reading(limits: [weekly], readAt: Self.date(milliseconds: readAtMs))
    }

    /// The weekly usage saved for `slot`, or nil when there is none. The key spells the slot escaped, as Grok Bot does.
    /// A slot that was saved already escaped is tried as saved when the escaped spelling finds nothing: escaping it a
    /// second time would look for a file that is not there. The slot of another account is never tried.
    private func usageBlob(forSlot slot: String) -> Data? {
        let escaped = Self.fileNameSlot(for: slot)
        for spelling in (escaped == slot ? [slot] : [escaped, slot]) {
            if let data = blob(forKey: "sand.client.slice.account.\(spelling).weekly-usage.cache") { return data }
        }
        return nil
    }

    /// What Grok Bot saved under `key`, or nil when there is no such file or it cannot be read.
    private func blob(forKey key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(Self.blobName(forKey: key)))
    }

    private static func date(milliseconds: Double) -> Date {
        Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

// MARK: - What Grok Bot saves

// Every field is optional, so a key that is missing never throws, and keys that are not listed are ignored.
// A value of the wrong type still throws, and the reader treats that like a new schema version.

private struct RawSlotBlob: Decodable {
    let schemaVersion: Int?
    let value: String?
}

private struct RawUsageBlob: Decodable {
    struct Value: Decodable {
        struct Reading: Decodable {
            struct Usage: Decodable {
                let percentUsed: Double?
                let nextResetMs: Double?
                let hasNonZeroIncludedLimit: Bool?
            }
            let usage: Usage?
            let readAtMs: Double?
        }
        let kind: String?
        let reading: Reading?
    }
    let schemaVersion: Int?
    let value: Value?
}
