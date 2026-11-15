import Foundation

/// Parses Fastmail/Gmail-style search syntax into a JMAP Email/query FilterCondition.
///
///     from:alice to:bob subject:"q3 plan" has:attachment is:unread is:flagged
///     in:archive after:2026-01-01 before:2026-02-01 older_than:30d newer_than:7d  free text
public struct SearchQuery: Equatable {
    public var text: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    public var cc: [String] = []
    public var subject: [String] = []
    public var body: [String] = []
    public var hasAttachment: Bool?
    public var unread: Bool?
    public var flagged: Bool?
    public var mailbox: String?
    public var after: Date?
    public var before: Date?

    public init() {}

    public var isEmpty: Bool { self == SearchQuery() }

    public static func parse(_ input: String, now: Date = Date()) -> SearchQuery {
        var q = SearchQuery()
        for token in tokenize(input) {
            guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                q.text.append(token); continue
            }
            let key = token[..<colon].lowercased()
            let value = String(token[token.index(after: colon)...])
            guard !value.isEmpty else { q.text.append(token); continue }
            switch key {
            case "from": q.from.append(value)
            case "to": q.to.append(value)
            case "cc": q.cc.append(value)
            case "subject": q.subject.append(value)
            case "body": q.body.append(value)
            case "in", "folder", "mailbox": q.mailbox = value
            case "has" where ["attachment", "attachments", "file"].contains(value.lowercased()):
                q.hasAttachment = true
            case "is":
                switch value.lowercased() {
                case "unread": q.unread = true
                case "read", "seen": q.unread = false
                case "flagged", "starred", "pinned": q.flagged = true
                case "unflagged": q.flagged = false
                default: q.text.append(token)
                }
            case "after", "since": q.after = parseDate(value) ?? q.after
            case "before", "until": q.before = parseDate(value) ?? q.before
            case "newer_than", "newer": q.after = relative(value, now: now) ?? q.after
            case "older_than", "older": q.before = relative(value, now: now) ?? q.before
            default: q.text.append(token)
            }
        }
        return q
    }

    /// Builds the JMAP filter. `resolveMailbox` maps a name or role ("archive") to a mailbox id.
    public func filter(defaultMailboxId: String?, excludedMailboxIds: [String] = [],
                       resolveMailbox: (String) -> String?) -> [String: Any] {
        var conditions: [[String: Any]] = []
        func add(_ key: String, _ values: [String]) {
            for v in values { conditions.append([key: v]) }
        }
        add("text", text.isEmpty ? [] : [text.joined(separator: " ")])
        add("from", from)
        add("to", to)
        add("cc", cc)
        add("subject", subject)
        add("body", body)
        if let hasAttachment { conditions.append(["hasAttachment": hasAttachment]) }
        if let unread { conditions.append([unread ? "notKeyword" : "hasKeyword": "$seen"]) }
        if let flagged { conditions.append([flagged ? "hasKeyword" : "notKeyword": "$flagged"]) }
        if let after { conditions.append(["after": JMAPDate.string(after)]) }
        if let before { conditions.append(["before": JMAPDate.string(before)]) }

        if let name = mailbox, let id = resolveMailbox(name) {
            conditions.append(["inMailbox": id])
        } else if let defaultMailboxId {
            conditions.append(["inMailbox": defaultMailboxId])
        } else if !excludedMailboxIds.isEmpty {
            conditions.append(["inMailboxOtherThan": excludedMailboxIds])
        }

        switch conditions.count {
        case 0: return [:]
        case 1: return conditions[0]
        default: return ["operator": "AND", "conditions": conditions]
        }
    }

    // MARK: Helpers

    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); continue }
            if ch.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    static func relative(_ s: String, now: Date) -> Date? {
        guard let unit = s.last, let n = Int(s.dropLast()) else { return nil }
        let day: TimeInterval = 86_400
        switch unit {
        case "d": return now.addingTimeInterval(-Double(n) * day)
        case "w": return now.addingTimeInterval(-Double(n) * 7 * day)
        case "m": return Calendar.current.date(byAdding: .month, value: -n, to: now)
        case "y": return Calendar.current.date(byAdding: .year, value: -n, to: now)
        default: return nil
        }
    }
}
