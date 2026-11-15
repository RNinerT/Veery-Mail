import CryptoKit
import Foundation
import Security

/// Per-account folders under Application Support. The folder name is a hash of the account
/// identity, so one account's cached mail is never shown for another.
public enum AccountStorage {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veery Mail", isDirectory: true)
    }

    public static func namespace(for accountKey: String) -> String {
        "account-" + SHA256.hash(data: Data(accountKey.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// Durable records (outbox, snoozes) that must survive clearing the cache.
    public static func recordsDirectory(for accountKey: String) -> URL {
        root.appendingPathComponent(namespace(for: accountKey) + "-records", isDirectory: true)
    }
}

/// Tiny on-disk cache so the app paints the last-known mailbox list and
/// message headers instantly at launch, before the network answers.
/// Only headers/previews are cached; message bodies stay in memory.
public final class DiskCache: @unchecked Sendable {
    private let dir: URL
    private let queue = DispatchQueue(label: "veerymail.cache", qos: .utility)

    public init(namespace: String) {
        dir = AccountStorage.root.appendingPathComponent(namespace, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func url(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("\(safe).json")
    }

    public func load<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(T.self, from: data)
    }

    public func save<T: Encodable & Sendable>(_ value: T, _ key: String) {
        let target = url(key)
        queue.async {
            let e = JSONEncoder()
            e.dateEncodingStrategy = .secondsSince1970
            if let data = try? e.encode(value) { try? data.write(to: target, options: .atomic) }
        }
    }

    public func clear() {
        // Serialized with pending saves; the directory is recreated so caching keeps working
        // after signing out and back in.
        queue.sync {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Secrets in the login Keychain: the developer API token, OAuth tokens, AI provider keys.
public enum Keychain {
    public static func save(data: Data, account: String) throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    public static func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private static let service = "app.veerymail.fastmail"

    public static func save(token: String, account: String = "default") throws {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(token.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public static func token(account: String = "default") -> String? {
        read(service: service, account: account)
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String = "default") {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A snoozed conversation: moved to the Snoozed mailbox and returned to
/// `returnMailboxId` (marked unread) at `until`.
public struct SnoozeEntry: Codable, Hashable, Sendable {
    public let emailIds: [String]
    public let threadId: String
    public let until: Date
    public let returnMailboxId: String

    public init(emailIds: [String], threadId: String, until: Date, returnMailboxId: String) {
        self.emailIds = emailIds; self.threadId = threadId
        self.until = until; self.returnMailboxId = returnMailboxId
    }
}

public struct SnoozeOption: Hashable, Sendable {
    public let name: String
    public let date: Date
}

public enum SnoozePresets {
    /// "Later today" (+3h), "Tomorrow" 8am, "This weekend" Sat 8am, "Next week" Mon 8am.
    public static func options(now: Date = Date(), calendar: Calendar = .current) -> [SnoozeOption] {
        func at8(_ d: Date) -> Date {
            calendar.date(bySettingHour: 8, minute: 0, second: 0, of: d) ?? d
        }
        let tomorrow = at8(calendar.date(byAdding: .day, value: 1, to: now)!)
        let saturday = at8(calendar.nextDate(after: now, matching: DateComponents(weekday: 7),
                                             matchingPolicy: .nextTime) ?? tomorrow)
        let monday = at8(calendar.nextDate(after: now, matching: DateComponents(weekday: 2),
                                           matchingPolicy: .nextTime) ?? tomorrow)
        return [
            SnoozeOption(name: "Later Today", date: now.addingTimeInterval(3 * 3600)),
            SnoozeOption(name: "Tomorrow", date: tomorrow),
            SnoozeOption(name: "This Weekend", date: saturday),
            SnoozeOption(name: "Next Week", date: monday),
        ]
    }
}

/// OAuth tokens in the Keychain (one device-only item).
public struct KeychainTokenStore: TokenStore {
    public static let account = "oauth.fastmail"
    public init() {}
    public func load() -> OAuthTokens? {
        Keychain.data(account: Self.account).flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: $0) }
    }
    public func save(_ tokens: OAuthTokens) throws {
        try Keychain.save(data: JSONEncoder().encode(tokens), account: Self.account)
    }
    public func clear() { Keychain.delete(account: Self.account) }
}
