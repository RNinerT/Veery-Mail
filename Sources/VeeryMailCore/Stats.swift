import Foundation

/// Just enough of a message for statistics: when it arrived and where it is filed.
public struct MailMeta: Codable, Hashable, Sendable {
    public let id: String
    public let threadId: String
    public let receivedAt: Date
    public let mailboxIds: [String: Bool]

    public init(id: String, threadId: String, receivedAt: Date, mailboxIds: [String: Bool]) {
        self.id = id; self.threadId = threadId; self.receivedAt = receivedAt; self.mailboxIds = mailboxIds
    }

    public static let properties = ["id", "threadId", "receivedAt", "mailboxIds"]
}

/// Pure calculations behind the sidebar card's optional stats. No networking, so they can be tested.
public enum MailStats {
    public static func median(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The two consecutive hours (local time) in which the most mail arrives. Nil with too little data.
    public static func busiestWindow(_ dates: [Date], calendar: Calendar = .current) -> (startHour: Int, share: Double)? {
        guard dates.count >= 20 else { return nil }
        var hours = Array(repeating: 0, count: 24)
        for d in dates { hours[calendar.component(.hour, from: d)] += 1 }
        // Ties go to the window that starts with the busier hour (9–11 rather than 8–10).
        func rank(_ h: Int) -> (Int, Int) { (hours[h] + hours[(h + 1) % 24], hours[h]) }
        let best = (0..<24).max { rank($0) < rank($1) } ?? 9
        let share = Double(hours[best] + hours[(best + 1) % 24]) / Double(dates.count)
        return (best, share)
    }

    /// Consecutive days, ending today or yesterday, whose lowest Inbox count was at or below `target`.
    /// `dailyMinimum` is keyed by "yyyy-MM-dd". Today only counts once it has reached the target,
    /// so an unfinished day never breaks the streak.
    public static func streak(dailyMinimum: [String: Int], target: Int, today: Date = Date(),
                              calendar: Calendar = .current) -> Int {
        var day = today
        if (dailyMinimum[dayKey(today, calendar)] ?? Int.max) > target {
            day = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        }
        var count = 0
        while let value = dailyMinimum[dayKey(day, calendar)], value <= target {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    public static func dayKey(_ date: Date, _ calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Conversations where your latest sent message is at least `olderThan` old and nobody has replied since.
    public static func waitingThreads(sent: [EmailSummary], threadMail: [EmailSummary], sentMailboxId: String,
                                      myAddresses: Set<String>, olderThan: TimeInterval, now: Date = Date()) -> Int {
        let byThread = Dictionary(grouping: threadMail, by: \.threadId)
        var latestSent: [String: Date] = [:]
        for s in sent where !s.isDraft {
            latestSent[s.threadId] = max(latestSent[s.threadId] ?? .distantPast, s.receivedAt)
        }
        return latestSent.filter { threadId, sentAt in
            guard now.timeIntervalSince(sentAt) >= olderThan else { return false }
            let replied = (byThread[threadId] ?? []).contains { mail in
                mail.receivedAt > sentAt && !isMine(mail, sentMailboxId: sentMailboxId, myAddresses: myAddresses)
            }
            return !replied
        }.count
    }

    /// How long each of your replies took: from the latest message by someone else before it.
    public static func replyDelays(sent: [EmailSummary], threadMail: [EmailSummary], sentMailboxId: String,
                                   myAddresses: Set<String>) -> [(sentAt: Date, delay: TimeInterval)] {
        let byThread = Dictionary(grouping: threadMail, by: \.threadId)
        return sent.compactMap { s -> (sentAt: Date, delay: TimeInterval)? in
            guard !s.isDraft else { return nil }
            let prior = (byThread[s.threadId] ?? []).filter {
                $0.receivedAt < s.receivedAt && !isMine($0, sentMailboxId: sentMailboxId, myAddresses: myAddresses)
            }
            guard let latest = prior.max(by: { $0.receivedAt < $1.receivedAt }) else { return nil }
            let delay = s.receivedAt.timeIntervalSince(latest.receivedAt)
            // Ignore replies to mail older than two weeks: those are revived threads, not response times.
            return delay < 14 * 86_400 ? (sentAt: s.receivedAt, delay: delay) : nil
        }
    }

    static func isMine(_ mail: EmailSummary, sentMailboxId: String, myAddresses: Set<String>) -> Bool {
        if mail.mailboxIds[sentMailboxId] == true || mail.isDraft { return true }
        guard let from = mail.from?.first?.email.lowercased() else { return false }
        return myAddresses.contains(from)
    }

    /// Where recent mail is filed now, largest first. A message in several mailboxes counts once,
    /// for the first in `preferredOrder` that holds it (Inbox before labels).
    public static func folderLoad(_ mail: [MailMeta], preferredOrder: [String]) -> [(mailboxId: String, count: Int)] {
        var counts: [String: Int] = [:]
        for m in mail {
            let boxes = m.mailboxIds.filter(\.value).map(\.key)
            guard let box = preferredOrder.first(where: boxes.contains) ?? boxes.sorted().first else { continue }
            counts[box, default: 0] += 1
        }
        return counts.map { (mailboxId: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
    }

    /// The senders who sent the most of these messages, with their messages.
    public static func topSenders(_ mail: [EmailSummary], limit: Int = 3) -> [(sender: CleanSender, mail: [EmailSummary])] {
        let groups = Dictionary(grouping: mail.filter { $0.from?.first != nil }) {
            $0.from!.first!.cleaned.address.lowercased()
        }
        let ranked = groups.values
            .map { (sender: $0[0].from!.first!.cleaned, mail: $0) }
            .sorted { $0.mail.count != $1.mail.count ? $0.mail.count > $1.mail.count : $0.sender.name < $1.sender.name }
        return Array(ranked.prefix(limit))
    }
}
