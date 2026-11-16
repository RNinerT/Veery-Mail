import SwiftUI
import VeeryMailCore

/// Inbox "conditions": a glanceable summary at the top of the sidebar, in the spirit of
/// weather apps such as Acme Weather and Dark Sky. A large numeral, a one-word condition,
/// a sentence about what's happening, and a 24-hour graph of when mail arrived.
struct InboxConditions {
    let unread: Int
    let arrivals: [Date]
    let now: Date

    var condition: (word: String, symbol: String) {
        switch unread {
        case 0: return ("Clear", "sun.max")
        case 1...3: return ("Light", "sun.haze")
        case 4...10: return ("Steady", "cloud.sun")
        case 11...30: return ("Busy", "cloud")
        default: return ("Stormy", "cloud.bolt.rain")
        }
    }

    /// Arrivals per hour, oldest first; the last bucket is the current hour.
    var hourly: [Int] {
        var buckets = Array(repeating: 0, count: 24)
        for date in arrivals {
            let hoursAgo = Int(now.timeIntervalSince(date) / 3600)
            if (0..<24).contains(hoursAgo) { buckets[23 - hoursAgo] += 1 }
        }
        return buckets
    }

    var lastHour: Int { arrivals.filter { now.timeIntervalSince($0) < 3600 }.count }
    var today: Int { arrivals.filter { Calendar.current.isDate($0, inSameDayAs: now) }.count }

    /// One plain sentence, like a forecast summary.
    var summary: String {
        let hour = lastHour, day = today
        if hour > 0 { return "\(hour) new in the last hour · \(day) today" }
        if let latest = arrivals.max() {
            let quiet = now.timeIntervalSince(latest)
            if quiet > 3 * 3600 { return "Quiet for \(Int(quiet / 3600)) hours · \(day) today" }
            return "Last arrival at \(latest.formatted(date: .omitted, time: .shortened)) · \(day) today"
        }
        return "Nothing new in the last day"
    }
}

struct ConditionsCard: View {
    @Environment(MailStore.self) private var store
    @AppStorage("notifications") private var notifications = true
    @AppStorage(CardStat.storageKey) private var statsRaw = ""
    @AppStorage("card.showArrivalsGraph") private var showGraph = true

    var body: some View {
        let unread = store.mailbox(role: "inbox")?.unreadThreads ?? 0
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let c = InboxConditions(unread: unread, arrivals: store.inboxArrivals, now: context.date)
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Button {
                    if let inbox = store.mailbox(role: "inbox") { store.source = .mailbox(inbox.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("INBOX")
                            .font(Theme.Typeface.sectionLabel)
                            .tracking(0.8)
                            .foregroundStyle(Theme.secondaryText)
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                            Text("\(unread)")
                                .font(.system(size: 46, weight: .light).monospacedDigit())
                                .foregroundStyle(Theme.text)
                                .contentTransition(.numericText())
                            VStack(alignment: .leading, spacing: 0) {
                                Label(c.condition.word, systemImage: c.condition.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .symbolRenderingMode(.hierarchical)
                                Text("unread")
                                    .font(Theme.Typeface.meta)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        Text(c.summary)
                            .font(Theme.Typeface.meta)
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Inbox: \(unread) unread, \(c.condition.word). \(c.summary)")
                .accessibilityHint("Shows the Inbox")

                if showGraph {
                    ArrivalsGraph(hourly: c.hourly, now: context.date)
                }

                // Optional stats chosen in Settings → Summary Card. Never more than three.
                let stats = CardStat.parse(statsRaw)
                if !stats.isEmpty {
                    Rectangle().fill(Theme.rim).frame(height: 1)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(stats.prefix(CardStat.maxShown)) { stat in
                            CardStatRow(stat: stat, now: context.date)
                        }
                    }
                }

                // Notifications get a visible switch here instead of living only in Settings.
                Button { notifications.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: notifications ? "bell.fill" : "bell.slash")
                        Text(notifications ? "New mail alerts on" : "New mail alerts off")
                        Spacer(minLength: 0)
                    }
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(notifications ? Theme.text : Theme.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Turn new-mail notifications on or off")
                .accessibilityLabel("New mail alerts")
                .accessibilityValue(notifications ? "On" : "Off")
            }
            .padding(Theme.Space.m)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rim))
            .animation(.easeOut(duration: 0.25), value: unread)
        }
    }
}

/// 24 hourly bars, like an hourly precipitation graph. The current hour is copper.
struct ArrivalsGraph: View {
    let hourly: [Int]
    let now: Date

    var body: some View {
        let peak = max(hourly.max() ?? 0, 1)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(hourly.indices, id: \.self) { i in
                    let count = hourly[i]
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == hourly.count - 1 ? Theme.accent
                              : (count > 0 ? Theme.secondaryText.opacity(0.55) : Theme.secondaryText.opacity(0.18)))
                        .frame(height: count > 0 ? max(3, 30 * CGFloat(count) / CGFloat(peak)) : 2)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 30, alignment: .bottom)
            HStack {
                Text(now.addingTimeInterval(-23 * 3600).formatted(.dateTime.hour()))
                Spacer()
                Text(now.addingTimeInterval(-12 * 3600).formatted(.dateTime.hour()))
                Spacer()
                Text("Now")
            }
            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
            .foregroundStyle(Theme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mail arrivals over the last 24 hours: \(hourly.reduce(0, +)) messages, \(hourly.last ?? 0) this hour")
    }
}

/// "Updated just now", like the timestamp on a forecast.
struct SyncStatus: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(store.isOnline ? Theme.accent : Theme.secondaryText)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(text(now: context.date))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.Typeface.meta)
            .foregroundStyle(Theme.secondaryText)
        }
        .help(store.lastError ?? "Mail is pushed from Fastmail as it arrives")
    }

    private func text(now: Date) -> String {
        if !store.isOnline { return "Offline · retrying" }
        if store.isDemo { return "Demo mail · not connected" }
        let age = now.timeIntervalSince(store.lastSync)
        if store.lastSync == .distantPast { return "Connecting…" }
        if age < 60 { return "Updated just now" }
        return "Updated " + RelativeDateTimeFormatter().localizedString(for: store.lastSync, relativeTo: now)
    }
}
