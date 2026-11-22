import Foundation

/// How much new mail arrived each day over the last two weeks, for the sidebar summary card.
///
/// Bars use calendar days (today is partial). The headline comparison uses rolling windows,
/// the last 7×24 hours against the 7×24 hours before, so a half-finished day never makes this
/// week look quieter than it is.
public struct MailVolume: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public let start: Date
        public let count: Int
    }

    /// 14 calendar days, oldest first. The last entry is today.
    public let days: [Day]
    /// New mail in the last 7×24 hours.
    public let thisWeek: Int
    /// New mail in the 7×24 hours before that.
    public let lastWeek: Int

    public init(days: [Day], thisWeek: Int, lastWeek: Int) {
        self.days = days; self.thisWeek = thisWeek; self.lastWeek = lastWeek
    }

    /// One column of the chart: a day this week and the same weekday a week earlier.
    public struct Pair: Equatable, Sendable {
        public let day: Date
        public let count: Int
        public let previousDay: Date
        public let previousCount: Int
        public let isToday: Bool
    }

    public var pairs: [Pair] {
        guard days.count == 14 else { return [] }
        var out: [Pair] = []
        for i in 0..<7 {
            let current: Day = days[7 + i]
            let previous: Day = days[i]
            out.append(Pair(day: current.start, count: current.count,
                            previousDay: previous.start, previousCount: previous.count, isToday: i == 6))
        }
        return out
    }

    /// The tallest bar, so both weeks share one scale.
    public var peak: Int { max(days.map(\.count).max() ?? 0, 1) }

    public enum Trend: Equatable, Sendable { case up(Int), down(Int), same, noHistory }

    /// Percentage change, rounded. Within ±5% counts as "about the same".
    public var trend: Trend {
        guard lastWeek > 0 else { return thisWeek > 0 ? .noHistory : .same }
        let change = Double(thisWeek - lastWeek) / Double(lastWeek) * 100
        if abs(change) < 5 { return .same }
        let rounded = Int(change.magnitude.rounded())
        return change > 0 ? .up(rounded) : .down(rounded)
    }

    /// The 16 time windows to count: 14 calendar days (oldest first), then the rolling
    /// "this week" and "last week" windows.
    public static func windows(now: Date, calendar: Calendar = .current) -> [DateInterval] {
        let today = calendar.startOfDay(for: now)
        var out: [DateInterval] = (0..<14).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .day, value: -back, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: min(end, now))
        }
        let week: TimeInterval = 7 * 24 * 3600
        out.append(DateInterval(start: now.addingTimeInterval(-week), end: now))
        out.append(DateInterval(start: now.addingTimeInterval(-2 * week), end: now.addingTimeInterval(-week)))
        return out
    }

    /// Builds the model from counts for `windows(now:)`, in the same order.
    public static func from(counts: [Int], windows: [DateInterval]) -> MailVolume? {
        guard counts.count == 16, windows.count == 16 else { return nil }
        let days = (0..<14).map { Day(start: windows[$0].start, count: counts[$0]) }
        return MailVolume(days: days, thisWeek: counts[14], lastWeek: counts[15])
    }
}

extension JMAPClient {
    /// Counts new mail in each window with one request: Email/query with limit 0 and
    /// calculateTotal, so no messages are downloaded. Mail only in Sent, Drafts, Spam or
    /// Trash isn't counted.
    public func mailVolume(now: Date = Date(), excluding mailboxIds: [String],
                           calendar: Calendar = .current) async throws -> MailVolume? {
        guard let account = session?.mailAccountId else { throw JMAPError.notConnected }
        let windows = MailVolume.windows(now: now, calendar: calendar)
        let calls = windows.enumerated().map { i, w -> Invocation in
            var conditions: [[String: Any]] = [["after": JMAPDate.string(w.start), "before": JMAPDate.string(w.end)]]
            if !mailboxIds.isEmpty { conditions.append(["inMailboxOtherThan": mailboxIds]) }
            return Invocation("Email/query", [
                "accountId": account,
                "filter": ["operator": "AND", "conditions": conditions] as [String: Any],
                "collapseThreads": false, "limit": 0, "calculateTotal": true,
            ], id: "c\(i)")
        }
        let responses = try await call(calls)
        let counts = windows.indices.map { i in responses.first { $0.id == "c\(i)" }?.int("total") ?? 0 }
        return MailVolume.from(counts: counts, windows: windows)
    }
}
