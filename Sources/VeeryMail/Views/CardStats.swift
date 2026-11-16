import SwiftUI
import VeeryMailCore

// MARK: - The optional stats

/// Extra lines for the sidebar's Inbox summary card. At most three are ever shown.
enum CardStat: String, CaseIterable, Identifiable {
    case oldestUnread, streak, waiting, replyDebt, responseTime
    case trackers, busiestHours, scheduled, topSenders, folderLoad

    static let maxShown = 3
    static let storageKey = "card.stats"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oldestUnread: return "Oldest unread"
        case .streak: return "Streak"
        case .waiting: return "Waiting on replies"
        case .replyDebt: return "Reply debt"
        case .responseTime: return "Typical response time"
        case .trackers: return "Trackers blocked this week"
        case .busiestHours: return "Busiest hours"
        case .scheduled: return "Scheduled and snoozed"
        case .topSenders: return "Top senders today"
        case .folderLoad: return "Mail load by folder"
        }
    }

    var explanation: String {
        switch self {
        case .oldestUnread: return "How long the oldest unread message has been waiting in the Inbox."
        case .streak: return "Days in a row the Inbox got down to your target. Counted while Veery Mail is running."
        case .waiting: return "Conversations where you wrote last and nobody has answered for a few days."
        case .replyDebt: return "Inbox mail from the last 14 days that you've read but not answered. Mailing lists are left out."
        case .responseTime: return "Your median time to reply this week, compared with last week."
        case .trackers: return "Messages you opened this week whose remote images and trackers stayed blocked."
        case .busiestHours: return "The two-hour window when most of your mail arrives, from the last four weeks."
        case .scheduled: return "Snoozed conversations, when the next one returns, and messages scheduled to send."
        case .topSenders: return "Who filled your Inbox today, with one-click Archive and Unsubscribe."
        case .folderLoad: return "Where the last seven days of mail is filed now."
        }
    }

    var symbol: String {
        switch self {
        case .oldestUnread: return "hourglass"
        case .streak: return "flame"
        case .waiting: return "paperplane"
        case .replyDebt: return "arrowshape.turn.up.left"
        case .responseTime: return "stopwatch"
        case .trackers: return "eye.slash"
        case .busiestHours: return "clock"
        case .scheduled: return "calendar.badge.clock"
        case .topSenders: return "person.2"
        case .folderLoad: return "chart.bar.xaxis"
        }
    }

    /// Chosen stats in the order they were turned on. Never more than three, whatever is stored.
    static func parse(_ raw: String) -> [CardStat] {
        var seen = Set<CardStat>()
        let list = raw.split(separator: ",").compactMap { CardStat(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return Array(list.prefix(maxShown))
    }

    static func selected() -> [CardStat] {
        parse(UserDefaults.standard.string(forKey: storageKey) ?? "")
    }
}

/// Fetched values. Local stats (streak, trackers, snoozes) are read straight from their ledgers.
struct CardStatValues {
    var oldestUnread: EmailSummary?
    var oldestUnreadLoaded = false
    var waiting: Int?
    var replyDebt: Int?
    var replyThisWeek: TimeInterval?
    var replyLastWeek: TimeInterval?
    var replyLoaded = false
    var scheduledSends: Int?
    var busiest: (startHour: Int, share: Double)?
    var folderLoad: [(mailboxId: String, count: Int)] = []

    /// Believable values for demo mode.
    static func demo(messages: [EmailSummary]) -> CardStatValues {
        var v = CardStatValues()
        v.oldestUnread = messages.filter(\.isUnread).min { $0.receivedAt < $1.receivedAt }
        v.oldestUnreadLoaded = true
        v.waiting = 2
        v.replyDebt = 4
        v.replyThisWeek = 3 * 3600 + 20 * 60
        v.replyLastWeek = 5 * 3600 + 10 * 60
        v.replyLoaded = true
        v.scheduledSends = 1
        v.busiest = (9, 0.31)
        v.folderLoad = [("inbox", 42), ("archive", 31), ("f4", 18), ("f2", 6)]
        return v
    }
}

// MARK: - Local ledgers

/// Lowest Inbox count seen each day, for the streak. Kept for 120 days.
enum StreakLedger {
    private static let key = "card.streakLedger"

    static var days: [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func record(inboxCount: Int, now: Date = Date()) {
        var d = days
        let today = MailStats.dayKey(now)
        guard inboxCount < (d[today] ?? Int.max) else { return }
        d[today] = inboxCount
        if d.count > 120 {
            for k in d.keys.sorted().prefix(d.count - 120) { d[k] = nil }
        }
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// Messages opened with remote content kept blocked, by id, for "Trackers blocked this week".
enum PrivacyLedger {
    private static let key = "card.trackersBlocked"

    static func record(_ emailId: String, now: Date = Date()) {
        var d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard d[emailId] == nil else { return }
        d[emailId] = now.timeIntervalSince1970
        let cutoff = now.addingTimeInterval(-8 * 86_400).timeIntervalSince1970
        d = d.filter { $0.value > cutoff }
        UserDefaults.standard.set(d, forKey: key)
    }

    static func countThisWeek(now: Date = Date()) -> Int {
        let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let cutoff = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        return d.values.filter { $0 > cutoff }.count
    }
}

// MARK: - One stat on the card

struct CardStatRow: View {
    @Environment(MailStore.self) private var store
    let stat: CardStat
    let now: Date
    @AppStorage("card.streakTarget") private var streakTarget = 0
    @AppStorage("card.waitingDays") private var waitingDays = 3

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: stat.symbol)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .frame(width: 14)
                .accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.Typeface.meta)
        .help(stat.explanation)
    }

    @ViewBuilder private var content: some View {
        let v = store.cardStats
        switch stat {
        case .oldestUnread:
            if let oldest = v.oldestUnread {
                line("Oldest unread: \(Self.age(now.timeIntervalSince(oldest.receivedAt)))",
                     detail: oldest.from?.first?.cleaned.name)
            } else {
                line(v.oldestUnreadLoaded ? "No unread mail in the Inbox" : "Oldest unread: …", detail: nil)
            }
        case .streak:
            let days = MailStats.streak(dailyMinimum: StreakLedger.days, target: streakTarget, today: now)
            let goal = streakTarget == 0 ? "Inbox Zero" : "\(streakTarget) or fewer"
            line(days == 0 ? "Streak: none yet" : "Streak: \(days) day\(days == 1 ? "" : "s")",
                 detail: "Goal: \(goal)")
        case .waiting:
            if let n = v.waiting {
                line(n == 0 ? "Nobody owes you a reply" : "Waiting on \(n) repl\(n == 1 ? "y" : "ies")",
                     detail: n == 0 ? nil : "\(waitingDays)+ days")
            } else { line("Waiting on replies: …", detail: nil) }
        case .replyDebt:
            if let n = v.replyDebt {
                line(n == 0 ? "No reply debt" : "Reply debt: \(n)", detail: n == 0 ? nil : "read, not answered")
            } else { line("Reply debt: …", detail: nil) }
        case .responseTime:
            if let week = v.replyThisWeek {
                line("Typical reply: \(Self.duration(week))",
                     detail: v.replyLastWeek.map { "last week \(Self.duration($0))" })
            } else {
                line(v.replyLoaded ? "No replies this week" : "Typical reply: …", detail: nil)
            }
        case .trackers:
            let n = PrivacyLedger.countThisWeek(now: now)
            line("Trackers blocked: \(n)", detail: "this week")
        case .busiestHours:
            if let b = v.busiest {
                line("Mail usually arrives \(Self.window(b.startHour))", detail: "\(Int((b.share * 100).rounded()))%")
            } else { line("Busiest hours: not enough mail yet", detail: nil) }
        case .scheduled:
            let s = store.snoozeSummary
            let sends = v.scheduledSends ?? 0
            let snoozed = s.count == 0 ? "Nothing snoozed"
                : "\(s.count) snoozed" + (s.next.map { ", next \(Self.when($0, now: now))" } ?? "")
            line(snoozed, detail: sends > 0 ? "\(sends) send\(sends == 1 ? "" : "s") scheduled" : nil)
        case .topSenders:
            TopSendersStat(now: now)
        case .folderLoad:
            FolderLoadStat(load: v.folderLoad)
        }
    }

    /// Main text, with any detail on its own line so nothing is cut off in a narrow sidebar.
    private func line(_ text: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(text).foregroundStyle(Theme.text).lineLimit(1)
            if let detail {
                Text(detail).foregroundStyle(Theme.secondaryText).lineLimit(1)
            }
        }
        .truncationMode(.tail)
    }

    static func age(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3600)
        if hours < 1 { return "under an hour" }
        if hours < 48 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(hours / 24) days"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))m" }
        let hours = minutes / 60
        if hours < 48 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    static func window(_ startHour: Int) -> String {
        func label(_ h: Int) -> String {
            let hour = (h % 24 + 24) % 24
            let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
            return date.formatted(.dateTime.hour())
        }
        return "\(label(startHour))–\(label(startHour + 2))"
    }

    static func when(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour())
    }
}

/// Up to three senders, each with a menu to archive their mail or unsubscribe.
struct TopSendersStat: View {
    @Environment(MailStore.self) private var store
    let now: Date

    var body: some View {
        let today = store.inboxRecent.filter { Calendar.current.isDate($0.receivedAt, inSameDayAs: now) }
        let top = MailStats.topSenders(today)
        VStack(alignment: .leading, spacing: 3) {
            Text("Top senders today").foregroundStyle(Theme.text)
            if top.isEmpty {
                Text("No mail yet today").foregroundStyle(Theme.secondaryText)
            }
            ForEach(top, id: \.sender.address) { entry in
                HStack(spacing: 4) {
                    Text(entry.sender.name).foregroundStyle(Theme.text).lineLimit(1)
                    Text("\(entry.mail.count)").foregroundStyle(Theme.secondaryText).monospacedDigit()
                    Spacer(minLength: 2)
                    Menu {
                        Button("Archive Today’s Mail from \(entry.sender.name)") {
                            store.archiveFromSender(entry.mail, name: entry.sender.name)
                        }
                        Button("Unsubscribe") { store.unsubscribeFromSender(entry.mail) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Actions for \(entry.sender.name)")
                }
            }
        }
    }
}

/// A stacked bar of where the week's mail went, with the three largest named.
struct FolderLoadStat: View {
    @Environment(MailStore.self) private var store
    let load: [(mailboxId: String, count: Int)]

    var body: some View {
        let total = max(load.reduce(0) { $0 + $1.count }, 1)
        let top = Array(load.prefix(3))
        let rest = load.dropFirst(3).reduce(0) { $0 + $1.count }
        let shades: [Double] = [1.0, 0.65, 0.4]
        VStack(alignment: .leading, spacing: 4) {
            Text("This week’s mail").foregroundStyle(Theme.text)
            if load.isEmpty {
                Text("Not enough mail yet").foregroundStyle(Theme.secondaryText)
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(top.enumerated()), id: \.offset) { i, item in
                            Rectangle().fill(Theme.accent.opacity(shades[i]))
                                .frame(width: geo.size.width * CGFloat(item.count) / CGFloat(total))
                        }
                        if rest > 0 {
                            Rectangle().fill(Theme.secondaryText.opacity(0.3))
                        }
                    }
                }
                .frame(height: 6)
                .clipShape(Capsule())
                Text(top.map { "\(name($0.mailboxId)) \(Int((Double($0.count) / Double(total) * 100).rounded()))%" }
                    .joined(separator: " · "))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func name(_ id: String) -> String { store.mailbox(id: id)?.name ?? "Other" }
}

// MARK: - Settings tab

struct SummaryCardSettings: View {
    @Environment(MailStore.self) private var store
    @AppStorage("sidebar.showConditions") private var showCard = true
    @AppStorage(CardStat.storageKey) private var statsRaw = ""
    @AppStorage("card.streakTarget") private var streakTarget = 0
    @AppStorage("card.waitingDays") private var waitingDays = 3
    @AppStorage("card.showArrivalsGraph") private var showGraph = true

    private var chosen: [CardStat] { CardStat.parse(statsRaw) }

    private func binding(_ stat: CardStat) -> Binding<Bool> {
        Binding(
            get: { chosen.contains(stat) },
            set: { on in
                var list = chosen
                if on, !list.contains(stat), list.count < CardStat.maxShown { list.append(stat) }
                if !on { list.removeAll { $0 == stat } }
                statsRaw = list.map(\.rawValue).joined(separator: ",")
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show the Inbox summary card at the top of the sidebar", isOn: $showCard)
                Toggle("Show the 24-hour graph of arriving mail", isOn: $showGraph)
                    .disabled(!showCard)
            } footer: {
                Text("The card shows your unread count, a one-word summary and, if you like, a 24-hour graph of arriving mail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(CardStat.allCases) { stat in
                    let isOn = chosen.contains(stat)
                    Toggle(isOn: binding(stat)) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: stat.symbol).frame(width: 18).foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stat.title)
                                Text(stat.explanation).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .disabled(!isOn && chosen.count >= CardStat.maxShown)
                }
            } header: {
                Text("Extra stats: choose up to \(CardStat.maxShown)")
            } footer: {
                Text(chosen.count >= CardStat.maxShown
                     ? "\(chosen.count) of \(CardStat.maxShown) chosen. Turn one off to choose another. They appear in the order you turned them on."
                     : "\(chosen.count) of \(CardStat.maxShown) chosen. They appear in the order you turn them on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!showCard)
            Section("Options") {
                Stepper(value: $streakTarget, in: 0...50) {
                    Text(streakTarget == 0 ? "Streak counts days the Inbox reaches zero"
                                           : "Streak counts days the Inbox gets to \(streakTarget) or fewer")
                }
                Stepper(value: $waitingDays, in: 1...10) {
                    Text("Waiting on replies after \(waitingDays) day\(waitingDays == 1 ? "" : "s")")
                }
            }
            .disabled(!showCard)
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onChange(of: statsRaw) { _, _ in store.refreshStats(force: true) }
        .onChange(of: waitingDays) { _, _ in store.refreshStats(force: true) }
    }
}
