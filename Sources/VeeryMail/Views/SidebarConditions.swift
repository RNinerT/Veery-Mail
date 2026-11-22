import SwiftUI
import VeeryMailCore

/// The Inbox summary at the top of the sidebar: the unread count, and how much new mail
/// arrived each day this week next to the same day last week.
struct ConditionsCard: View {
    @Environment(MailStore.self) private var store
    @AppStorage("notifications") private var notifications = true
    @AppStorage(CardStat.storageKey) private var statsRaw = ""
    @AppStorage("card.showArrivalsGraph") private var showGraph = true

    var body: some View {
        let unread = store.mailbox(role: "inbox")?.unreadThreads ?? 0
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                Button {
                    if let inbox = store.mailbox(role: "inbox") { store.source = .mailbox(inbox.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("INBOX")
                            .font(Theme.Typeface.sectionLabel)
                            .tracking(0.8)
                            .foregroundStyle(Theme.secondaryText)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(unread)")
                                .font(.system(size: 40, weight: .light).monospacedDigit())
                                .foregroundStyle(Theme.text)
                                .contentTransition(.numericText())
                            Text("unread")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Inbox, \(unread) unread")
                .accessibilityHint("Shows the Inbox")

                if showGraph {
                    if let volume = store.mailVolume {
                        WeekVolume(volume: volume, now: context.date)
                    } else {
                        WeekVolumePlaceholder()
                    }
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

/// "New this week" with a quiet comparison, and seven pairs of bars: last week's same weekday
/// (faint, left) beside this week's day (solid, right). Today is copper.
struct WeekVolume: View {
    let volume: MailVolume
    let now: Date
    @State private var hovered: Int?

    private static let chartHeight: CGFloat = 38

    var body: some View {
        let pairs = volume.pairs
        let peak = CGFloat(volume.peak)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(volume.thisWeek)")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.text)
                        .contentTransition(.numericText())
                    Text("new this week")
                        .font(Theme.Typeface.meta)
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                TrendLine(trend: volume.trend, lastWeek: volume.lastWeek)
            }

            HStack(alignment: .bottom, spacing: 0) {
                ForEach(pairs.indices, id: \.self) { i in
                    let pair = pairs[i]
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 2) {
                            bar(pair.previousCount, peak: peak, color: Theme.secondaryText.opacity(hovered == i ? 0.45 : 0.28))
                            bar(pair.count, peak: peak,
                                color: pair.isToday ? Theme.accent : Theme.text.opacity(hovered == i ? 0.95 : 0.7))
                        }
                        .frame(height: Self.chartHeight, alignment: .bottom)
                        Text(pair.day.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 9.5, weight: pair.isToday ? .bold : .medium))
                            .foregroundStyle(pair.isToday ? Theme.accent : Theme.secondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                    .help(Self.detail(pair))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Self.detail(pair))
                }
            }
            .animation(.easeOut(duration: 0.3), value: volume)

            HStack(spacing: 10) {
                // Same order as each pair of bars: last week on the left.
                legend(Theme.secondaryText.opacity(0.28), "Last week")
                legend(Theme.text.opacity(0.7), "This week")
                Spacer(minLength: 0)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New mail by day")
    }

    private func bar(_ count: Int, peak: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(count > 0 ? color : color.opacity(0.5))
            .frame(width: 6, height: count > 0 ? max(3, Self.chartHeight * CGFloat(count) / peak) : 1.5)
    }

    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
    }

    static func detail(_ pair: MailVolume.Pair) -> String {
        let day = pair.isToday ? "Today so far" : pair.day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let last = pair.previousDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day): \(pair.count) new. \(last): \(pair.previousCount)."
    }
}

/// "↑ 21% more than last week", in neutral colours: more or less mail isn't good or bad.
struct TrendLine: View {
    let trend: MailVolume.Trend
    let lastWeek: Int

    var body: some View {
        let (symbol, text): (String?, String) = {
            switch trend {
            case .up(let p): return ("arrow.up.right", "\(p)% more than last week")
            case .down(let p): return ("arrow.down.right", "\(p)% less than last week")
            case .same: return ("equal", "About the same as last week")
            case .noHistory: return (nil, "No mail the week before")
            }
        }()
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(text).lineLimit(1).minimumScaleFactor(0.85)
        }
        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        .foregroundStyle(Theme.secondaryText)
        .help("Last 7 days compared with the 7 days before, when \(lastWeek) new messages arrived")
        .accessibilityElement(children: .combine)
    }
}

/// Shown until the first counts arrive, so the card doesn't jump in height.
struct WeekVolumePlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New this week")
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.secondaryText)
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(0..<7, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.secondaryText.opacity(0.12))
                        .frame(width: 14, height: 1.5)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 38 + 16, alignment: .bottom)
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
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
