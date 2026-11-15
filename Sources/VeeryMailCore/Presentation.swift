import Foundation

// MARK: - Sender cleanup

/// A sender as a person would describe it. Undoes the rewriting done by mail relays
/// such as SimpleLogin, which turn `Jane Doe <jane@example.com>` into
/// `"Jane Doe - jane at example.com" <random@relay.example>`.
public struct CleanSender: Hashable, Sendable {
    public let name: String
    /// The real sender's domain, when known.
    public let domain: String?
    /// The real sender's address (reconstructed when relayed).
    public let address: String
    public let isRelayed: Bool

    public init(_ a: EmailAddress) {
        let raw = (a.name ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if let at = raw.range(of: " at ", options: .backwards) {
            let domain = String(raw[at.upperBound...])
            var display = ""
            var local = String(raw[..<at.lowerBound])
            if let dash = local.range(of: " - ", options: .backwards) {
                display = String(local[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
                local = String(local[dash.upperBound...])
            }
            if domain.contains("."), !domain.contains(" "), !local.isEmpty, !local.contains(" ") {
                let original = "\(local)@\(domain)"
                self.name = display.isEmpty ? original : display
                self.domain = domain.lowercased()
                self.address = original
                self.isRelayed = true
                return
            }
        }
        self.name = raw.isEmpty ? a.email : raw
        self.domain = a.email.split(separator: "@").last.map { $0.lowercased() }
        self.address = a.email
        self.isRelayed = false
    }
}

extension EmailAddress {
    public var cleaned: CleanSender { CleanSender(self) }
}

// MARK: - HTML heuristics

public enum HTMLHeuristics {
    /// Pass lowercased HTML. True when the message would load anything from the network.
    public static func hasRemoteContent(_ lower: String) -> Bool {
        lower.contains("src=\"http") || lower.contains("src='http")
            || lower.contains("url(http") || lower.contains("background=\"http")
    }

    /// Pass lowercased HTML. True for person-to-person style mail with no layout of its own,
    /// which can safely be shown as light text on a dark background.
    public static func isSimple(_ lower: String) -> Bool {
        for marker in ["<table", "<img", "<style", "bgcolor", "background"] where lower.contains(marker) {
            return false
        }
        return true
    }
}

// MARK: - Day grouping for the message list

public enum DayBucket: Int, CaseIterable, Sendable {
    case today, yesterday, week, month, older

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .week: return "Previous 7 Days"
        case .month: return "Previous 30 Days"
        case .older: return "Older"
        }
    }

    public static func bucket(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> DayBucket {
        let startToday = calendar.startOfDay(for: now)
        if date >= startToday { return .today }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: startToday).day ?? 0
        if days <= 1 { return .yesterday }
        if days < 7 { return .week }
        if days < 30 { return .month }
        return .older
    }
}
