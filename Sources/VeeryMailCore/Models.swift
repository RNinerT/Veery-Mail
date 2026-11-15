import Foundation

// MARK: - JMAP capability URNs

public enum JMAPCapability {
    public static let core = "urn:ietf:params:jmap:core"
    public static let mail = "urn:ietf:params:jmap:mail"
    public static let submission = "urn:ietf:params:jmap:submission"
    public static let contacts = "urn:ietf:params:jmap:contacts"
    /// Fastmail's vendor extension for Masked Email.
    public static let maskedEmail = "https://www.fastmail.com/dev/maskedemail"
}

// MARK: - Session (RFC 8620 §2)

public struct JMAPSession: Codable, Sendable {
    public struct Account: Codable, Sendable {
        public let name: String
        public let isPersonal: Bool?
        public let isReadOnly: Bool?
        public let accountCapabilities: [String: JSONValue]?
    }

    public let username: String
    public let apiUrl: URL
    public let downloadUrl: String
    public let uploadUrl: String
    public let eventSourceUrl: String
    public let state: String
    public let accounts: [String: Account]
    public let primaryAccounts: [String: String]
    public let capabilities: [String: JSONValue]

    public var mailAccountId: String? { primaryAccounts[JMAPCapability.mail] }

    public var supportsMaskedEmail: Bool {
        capabilities[JMAPCapability.maskedEmail] != nil
            || primaryAccounts[JMAPCapability.maskedEmail] != nil
    }

    /// Seconds the server will hold a submission (0 = scheduled send unsupported).
    public var maxDelayedSend: Int {
        guard let id = mailAccountId,
              case .object(let sub)? = accounts[id]?.accountCapabilities?[JMAPCapability.submission],
              case .number(let n)? = sub["maxDelayedSend"] else { return 0 }
        return Int(n)
    }
}

// MARK: - Mail objects (RFC 8621)

public struct Mailbox: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var parentId: String?
    public var role: String?
    public var sortOrder: Int
    public var totalEmails: Int
    public var unreadEmails: Int
    public var totalThreads: Int
    public var unreadThreads: Int

    public static let properties = ["id", "name", "parentId", "role", "sortOrder",
                                    "totalEmails", "unreadEmails", "totalThreads", "unreadThreads"]

    /// Display order for system mailboxes, mirroring Fastmail's web UI.
    public var roleRank: Int {
        switch role {
        case "inbox": return 0
        case "snoozed": return 1
        case "drafts": return 2
        case "sent": return 3
        case "archive": return 4
        case "junk": return 5
        case "trash": return 6
        case .some: return 7
        case .none: return 100
        }
    }

    public var systemImage: String {
        switch role {
        case "inbox": return "tray"
        case "snoozed": return "clock"
        case "drafts": return "doc"
        case "sent": return "paperplane"
        case "archive": return "archivebox"
        case "junk": return "xmark.bin"
        case "trash": return "trash"
        default: return "folder"
        }
    }
}

public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return email
    }

    public var formatted: String {
        if let name, !name.isEmpty { return "\(name) <\(email)>" }
        return email
    }

    /// Valid addresses in a compose field. Invalid entries are skipped here; use
    /// `RecipientParser.parse` to report them.
    public static func parseList(_ text: String) -> [EmailAddress] {
        RecipientParser.parse(text).compactMap(\.address)
    }
}

/// Lightweight row model: only what the message list needs.
public struct EmailSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let threadId: String
    public var mailboxIds: [String: Bool]
    public var keywords: [String: Bool]
    public var from: [EmailAddress]?
    public var to: [EmailAddress]?
    public var subject: String?
    public var receivedAt: Date
    public var preview: String?
    public var hasAttachment: Bool
    public var size: Int?

    public static let properties = ["id", "threadId", "mailboxIds", "keywords", "from", "to",
                                    "subject", "receivedAt", "preview", "hasAttachment", "size"]

    public init(id: String, threadId: String, mailboxIds: [String: Bool] = [:], keywords: [String: Bool] = [:],
                from: [EmailAddress]? = nil, to: [EmailAddress]? = nil, subject: String? = nil,
                receivedAt: Date = Date(), preview: String? = nil, hasAttachment: Bool = false, size: Int? = nil) {
        self.id = id; self.threadId = threadId; self.mailboxIds = mailboxIds; self.keywords = keywords
        self.from = from; self.to = to; self.subject = subject; self.receivedAt = receivedAt
        self.preview = preview; self.hasAttachment = hasAttachment; self.size = size
    }

    public var isUnread: Bool { keywords["$seen"] != true }
    public var isFlagged: Bool { keywords["$flagged"] == true }
    public var isDraft: Bool { keywords["$draft"] == true }
    public var isAnswered: Bool { keywords["$answered"] == true }
    public var sender: String { from?.first?.displayName ?? "(no sender)" }
    public var displaySubject: String {
        let s = subject?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? "(no subject)" : s
    }
}

public struct EmailBodyPart: Codable, Hashable, Sendable {
    public var partId: String?
    public var blobId: String?
    public var size: Int?
    public var name: String?
    public var type: String
    public var charset: String?
    public var disposition: String?
    public var cid: String?
}

public struct EmailBodyValue: Codable, Hashable, Sendable {
    public var value: String
    public var isTruncated: Bool?
}

/// Full message used by the reader.
public struct EmailDetail: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let threadId: String
    public var mailboxIds: [String: Bool]
    public var keywords: [String: Bool]
    public var from: [EmailAddress]?
    public var to: [EmailAddress]?
    public var cc: [EmailAddress]?
    public var bcc: [EmailAddress]?
    public var replyTo: [EmailAddress]?
    public var subject: String?
    public var receivedAt: Date
    public var sentAt: Date?
    public var messageId: [String]?
    public var inReplyTo: [String]?
    public var references: [String]?
    public var preview: String?
    public var htmlBody: [EmailBodyPart]?
    public var textBody: [EmailBodyPart]?
    public var attachments: [EmailBodyPart]?
    public var bodyValues: [String: EmailBodyValue]?
    public var listUnsubscribe: [String]?
    public var listUnsubscribePost: String?
    /// Every Authentication-Results header, top (most recently added) first.
    public var authenticationResults: [String]?
    /// Every DKIM-Signature header, raw.
    public var dkimSignatures: [String]?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, threadId, mailboxIds, keywords, from, to, cc, bcc, replyTo, subject,
             receivedAt, sentAt, messageId, inReplyTo, references, preview,
             htmlBody, textBody, attachments, bodyValues
        case listUnsubscribe = "header:List-Unsubscribe:asURLs"
        case listUnsubscribePost = "header:List-Unsubscribe-Post:asText"
        case authenticationResults = "header:Authentication-Results:asText:all"
        case dkimSignatures = "header:DKIM-Signature:asRaw:all"
    }

    public static let properties = CodingKeys.allCases.map(\.rawValue)

    public var isUnread: Bool { keywords["$seen"] != true }
    public var isFlagged: Bool { keywords["$flagged"] == true }

    /// Joined HTML parts, or nil if the message has no HTML representation.
    public var html: String? {
        guard let parts = htmlBody, parts.contains(where: { $0.type == "text/html" }) else { return nil }
        let joined = parts.compactMap { part -> String? in
            guard let pid = part.partId, let value = bodyValues?[pid]?.value else { return nil }
            if part.type == "text/html" { return value }
            if part.type == "text/plain" { return "<pre>\(value.htmlEscaped)</pre>" }
            return nil
        }.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    public var plainText: String {
        (textBody ?? []).compactMap { part in
            part.partId.flatMap { bodyValues?[$0]?.value }
        }.joined(separator: "\n")
    }

    /// Visible attachments (inline images referenced by cid are hidden).
    public var visibleAttachments: [EmailBodyPart] {
        (attachments ?? []).filter { !($0.disposition == "inline" && $0.cid != nil) }
    }

    public var inlineParts: [String: String] {
        var map: [String: String] = [:]
        for part in attachments ?? [] {
            if let cid = part.cid, let blob = part.blobId {
                map[cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))] = blob
            }
        }
        return map
    }

    /// First usable https or mailto unsubscribe target.
    public var unsubscribeURL: URL? {
        let urls = (listUnsubscribe ?? []).compactMap(URL.init(string:))
        return urls.first { $0.scheme == "https" } ?? urls.first { $0.scheme == "mailto" }
    }

    /// RFC 8058 one-click unsubscribe is available.
    public var supportsOneClickUnsubscribe: Bool {
        guard let post = listUnsubscribePost else { return false }
        return post.lowercased().contains("list-unsubscribe=one-click") && unsubscribeURL?.scheme == "https"
    }
}

public struct Identity: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var email: String
    public var mayDelete: Bool?

    public var address: EmailAddress { EmailAddress(name: name.isEmpty ? nil : name, email: email) }
}

public struct MaskedEmail: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var email: String
    public var state: String
    public var forDomain: String?
    public var description: String?
    public var createdAt: Date?
    public var lastMessageAt: Date?
}

public struct UploadResult: Codable, Sendable {
    public let accountId: String
    public let blobId: String
    public let type: String
    public let size: Int
}

// MARK: - Generic JSON value (for capability blobs and patches)

public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Helpers

extension String {
    public var htmlEscaped: String {
        var out = ""
        out.reserveCapacity(count)
        for ch in self {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }
}

public enum JMAPDate {
    /// Shared decoder: building date formatters for every response was measurable overhead.
    public static let shared: JSONDecoder = decoder()

    /// JMAP UTCDate: "2026-11-14T09:30:00Z" (fractional seconds optional).
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            if let date = plain.date(from: s) ?? fractional.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad date \(s)"))
        }
        return d
    }

    public static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
