import AppKit
import VeeryMailCore
import SwiftUI

// MARK: - Shared keyboard shortcuts (Gmail / Superhuman conventions)

@MainActor
enum ListKeys {
    /// `arrows`: handle ↑/↓ here (the custom list) or leave them to the system list.
    static func handle(_ press: KeyPress, store: MailStore, arrows: Bool) -> KeyPress.Result {
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        switch press.key {
        case .downArrow:
            guard arrows else { return .ignored }
            store.moveSelection(1); return .handled
        case .upArrow:
            guard arrows else { return .ignored }
            store.moveSelection(-1); return .handled
        case .return:
            guard let row = store.selectedRows.first, row.isDraft else { return .ignored }
            store.openDraft(row); return .handled
        case .escape: store.selection = []; return .handled
        case .delete, .deleteForward: store.trash(); return .handled
        default: break
        }
        switch press.characters {
        case "j": store.moveSelection(1)
        case "k": store.moveSelection(-1)
        case "e", "y": store.archive()
        case "#": store.trash()
        case "!": store.markSpam()
        case "r": store.reply(all: false)
        case "a": store.reply(all: true)
        case "f": store.forward()
        case "c": store.compose()
        case "s": store.toggleFlag()
        case "u", "U": store.toggleRead()
        case "i": store.moveToInbox()
        case "h": if let tomorrow = SnoozePresets.options().dropFirst().first { store.snooze(until: tomorrow.date) }
        case "/": store.showCommandPalette = true
        default: return .ignored
        }
        return .handled
    }
}

@MainActor
enum ListSubtitle {
    static func text(_ store: MailStore) -> String {
        if case .mailbox(let id) = store.source, let mb = store.mailbox(id: id), mb.unreadThreads > 0,
           mb.role != "archive", mb.role != "trash", mb.role != "junk", mb.role != "sent" {
            return "\(mb.unreadThreads) unread"
        }
        if let total = store.totalInSource { return "\(total) conversations" }
        return ""
    }
}

struct ListEmptyState: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        if store.messages.isEmpty {
            if store.isLoadingList {
                ProgressView()
            } else if case .search = store.source {
                ContentUnavailableView("No Results", systemImage: "magnifyingglass")
            } else if store.currentMailboxId == store.mailbox(role: "inbox")?.id {
                VStack(spacing: 10) {
                    Image(systemName: "bird.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Inbox Zero").font(.system(size: 24, weight: .semibold, design: .serif)).foregroundStyle(Theme.text)
                    Text("Nothing left to triage.").foregroundStyle(Theme.secondaryText)
                }
            } else {
                ContentUnavailableView("No Messages", systemImage: "tray")
            }
        }
    }
}

// MARK: - Inbox list

struct DaySection: Identifiable {
    let bucket: DayBucket
    var rows: [EmailSummary]
    var id: Int { bucket.rawValue }

    static func group(_ messages: [EmailSummary]) -> [DaySection] {
        let now = Date()
        let calendar = Calendar.current
        var buckets = DayBucket.allCases.map { DaySection(bucket: $0, rows: []) }
        for message in messages {
            buckets[DayBucket.bucket(for: message.receivedAt, now: now, calendar: calendar).rawValue].rows.append(message)
        }
        return buckets.filter { !$0.rows.isEmpty }
    }
}

struct InboxListView: View {
    @Environment(MailStore.self) private var store
    private var listFormat = ListFormatStorage()
    @FocusState private var focused: Bool
    /// The keyboard cursor: the last row clicked or moved to. Shift-click ranges start here.
    @State private var cursorId: String?

    var body: some View {
        let format = listFormat.format
        let outgoing = store.showsRecipients
        let sections = DaySection.group(store.messages)
        let single = store.selection.count == 1
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    // Section labels scroll with the rows (not pinned), so a row moved to with the
                    // keyboard is always scrolled fully into view and never hides under a label.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            Text(section.bucket.title.uppercased())
                                .font(Theme.Typeface.sectionLabel)
                                .tracking(1.1)
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.leading, Theme.Space.s + Theme.Space.dotColumn + Theme.Space.s)
                                .padding(.top, Theme.Space.l)
                                .padding(.bottom, Theme.Space.s)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.rows) { row in
                                let selected = store.selection.contains(row.id)
                                InboxRow(row: row, format: format, showRecipients: outgoing,
                                         isOpen: selected && single,
                                         isSelected: selected && !single,
                                         isCursor: focused && cursorId == row.id && !(selected && single))
                                    .onTapGesture { click(row) }
                                    .simultaneousGesture(TapGesture(count: 2).onEnded { _ in store.openDraft(row) })
                                    .contextMenu { RowContextMenu(rows: contextRows(for: row)) }
                                    .draggable(row.id)
                                    .onAppear { store.loadMoreIfNeeded(current: row) }
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.bottom, Theme.Space.l)
                }
                .onChange(of: store.selection) { _, new in
                    store.selectionChanged()
                    if new.count == 1, let id = new.first {
                        cursorId = id
                        proxy.scrollTo(id)   // no anchor: the smallest scroll that shows the whole row
                    }
                }
            }
        }
        .background(Theme.canvas)
        .overlay { ListEmptyState() }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .onAppear { focused = true }
        // Give the keyboard back to the list when a sheet closes.
        .onChange(of: store.showCommandPalette) { _, showing in if !showing { focused = true } }
        .onChange(of: store.showMaskedEmail) { _, showing in if !showing { focused = true } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(store.sourceTitle)
                .font(Theme.Typeface.mailboxTitle)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if case .search = store.source {
                Button { store.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondaryText)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
            }
            Spacer(minLength: Theme.Space.s)
            if store.isLoadingList && !store.messages.isEmpty {
                ProgressView().controlSize(.small)
            }
            if !store.isOnline {
                Label("Offline", systemImage: "wifi.slash")
                    .font(Theme.Typeface.meta)
                    .foregroundStyle(Theme.flag)
                    .help(store.lastError ?? "Offline")
            }
            Text(ListSubtitle.text(store))
                .font(Theme.Typeface.meta)
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
        }
        .padding(.leading, Theme.Space.s + Theme.Space.dotColumn + Theme.Space.s)
        .padding(.trailing, Theme.Space.l + Theme.Space.xs)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.xs)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        ListKeys.handle(press, store: store, arrows: true)
    }

    /// Click opens, ⌘-click toggles, ⇧-click selects a range.
    private func click(_ row: EmailSummary) {
        focused = true
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            if store.selection.contains(row.id) { store.selection.remove(row.id) } else { store.selection.insert(row.id) }
            cursorId = row.id
        } else if flags.contains(.shift),
                  let anchor = cursorId ?? store.selection.first,
                  let a = store.messages.firstIndex(where: { $0.id == anchor }),
                  let b = store.messages.firstIndex(where: { $0.id == row.id }) {
            store.selection = Set(store.messages[min(a, b)...max(a, b)].map(\.id))
        } else {
            store.selection = [row.id]
            cursorId = row.id
        }
    }

    /// Right-clicking inside a multi-selection acts on all of it; otherwise on that row.
    private func contextRows(for row: EmailSummary) -> [EmailSummary] {
        store.selection.contains(row.id) && store.selection.count > 1 ? store.selectedRows : [row]
    }
}

/// One row with its four states, each drawn differently:
/// open in the reader (copper tint and edge), part of a multi-selection (neutral fill and outline),
/// keyboard cursor (outline only), and hover (faint fill plus quick actions).
struct InboxRow: View {
    @Environment(MailStore.self) private var store
    let row: EmailSummary
    let format: ListFormat
    let showRecipients: Bool
    let isOpen: Bool
    let isSelected: Bool
    let isCursor: Bool
    @State private var hovering = false

    private var fill: Color {
        if isOpen { return Theme.accent.opacity(0.16) }
        if isSelected { return Theme.selection }
        return hovering ? Theme.hover : Color.clear
    }

    private var outline: Color {
        if isCursor { return Theme.text.opacity(0.7) }
        return isSelected ? Theme.secondaryText.opacity(0.6) : Color.clear
    }

    var body: some View {
        MessageRow(row: row, format: format, showRecipients: showRecipients)
            .padding(.leading, Theme.Space.s)
            .padding(.trailing, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(outline, lineWidth: 1.5))
            .overlay(alignment: .leading) {
                if isOpen {
                    RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3).padding(.vertical, 6)
                }
            }
            .overlay(alignment: .bottom) {
                // Quiet divider, hidden next to a filled row.
                if !isOpen && !isSelected && !hovering {
                    Rectangle().fill(Theme.rim).frame(height: 1)
                        .padding(.leading, Theme.Space.s + Theme.Space.dotColumn)
                        .padding(.trailing, Theme.Space.m)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering { quickActions }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityAddTraits(isOpen || isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if row.isUnread { parts.append("Unread") }
        if row.isFlagged { parts.append("Flagged") }
        parts.append(row.from?.first?.cleaned.name ?? "No sender")
        parts.append(row.displaySubject)
        if row.hasAttachment { parts.append("Has attachment") }
        parts.append(RelativeDate.short(row.receivedAt))
        return parts.joined(separator: ", ")
    }

    /// Shown on hover, so triage works with the mouse as fast as with the keyboard.
    private var quickActions: some View {
        HStack(spacing: 0) {
            quick("archivebox", "Archive (E)") { store.archive([row]) }
            quick("trash", "Trash (#)") { store.trash([row]) }
            quick(row.isUnread ? "envelope.open" : "envelope.badge", row.isUnread ? "Mark as Read (U)" : "Mark as Unread (U)") {
                store.setRead(row.isUnread, rows: [row])
            }
            quick("clock", "Snooze until tomorrow (H)") {
                if let tomorrow = SnoozePresets.options().dropFirst().first { store.snooze(until: tomorrow.date, rows: [row]) }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.rim))
        .padding(5)
    }

    private func quick(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Context menu

struct RowContextMenu: View {
    @Environment(MailStore.self) private var store
    let rows: [EmailSummary]

    var body: some View {
        Button("Reply") { openAndReply(all: false) }
        Button("Reply All") { openAndReply(all: true) }
        Divider()
        Button("Archive") { store.archive(rows) }
        Button("Move to Trash") { store.trash(rows) }
        Button("Delete Permanently…") { store.requestPermanentDelete(rows) }
        Button("Mark as Spam") { store.markSpam(rows) }
        Divider()
        let anyUnread = rows.contains { $0.isUnread }
        Button(anyUnread ? "Mark as Read" : "Mark as Unread") { store.setRead(anyUnread, rows: rows) }
        Menu("Snooze") {
            ForEach(SnoozePresets.options(), id: \.name) { option in
                Button(option.name) { store.snooze(until: option.date, rows: rows) }
            }
        }
        Menu("Move To") {
            ForEach(store.mailboxTree, id: \.mailbox.id) { item in
                Button(String(repeating: "  ", count: item.depth) + item.mailbox.name) {
                    store.move(rows, to: item.mailbox.id, verb: "moved to \(item.mailbox.name)")
                }
            }
        }
    }

    private func openAndReply(all: Bool) {
        guard let row = rows.first else { return }
        Task {
            if let emails = try? await store.client?.thread(row.threadId), let last = emails.last {
                store.reply(all: all, to: last)
            }
        }
    }
}

// MARK: - Row content (the inbox and the Settings preview)

/// A fixed grid: [unread dot] sender ............ time
///                            subject ..... [clip][flag]
///                            preview
/// The dot column and the two indicator slots are always reserved, so text and times line up on every row.
struct MessageRow: View {
    let row: EmailSummary
    let format: ListFormat
    /// Sent and Drafts show who the message is to instead of your own name.
    var showRecipients = false

    private var senderSize: CGFloat { CGFloat(format.sender.size) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle()
                .fill(row.isUnread && format.showUnreadDot ? format.unreadDotColor : Color.clear)
                .frame(width: 8, height: 8)
                .frame(width: Theme.Space.dotColumn, height: senderSize * 1.25)
                .accessibilityHidden(true)
            if format.showAvatars {
                Avatar(address: row.from?.first, size: senderSize * 2.4)
                    .padding(.trailing, Theme.Space.s)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    if format.firstLine == .sender { senderText } else { subjectText }
                    Spacer(minLength: Theme.Space.xs)
                    Text(dateString)
                        .textStyle(format.date, unread: row.isUnread)
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                    if format.firstLine == .sender { subjectText } else { senderText }
                    Spacer(minLength: Theme.Space.xs)
                    indicator("paperclip", shown: row.hasAttachment, color: Theme.secondaryText)
                    indicator("flag.fill", shown: row.isFlagged, color: Theme.flag)
                }
                if format.previewLines > 0, let preview = row.preview, !preview.isEmpty {
                    Text(preview)
                        .textStyle(format.preview, unread: row.isUnread)
                        .lineLimit(format.previewLines)
                }
            }
        }
        .padding(.vertical, format.spacing.padding)
    }

    private func indicator(_ symbol: String, shown: Bool, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5))
            .foregroundStyle(color)
            .frame(width: 13)
            .opacity(shown ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var senderName: String {
        if showRecipients {
            let names = (row.to ?? []).map { format.cleanSenders ? $0.cleaned.name : $0.displayName }
            return names.isEmpty ? "(no recipients)" : "To: " + names.joined(separator: ", ")
        }
        guard let from = row.from?.first else { return "(no sender)" }
        return format.cleanSenders ? from.cleaned.name : from.displayName
    }

    @ViewBuilder private var senderText: some View {
        if row.isDraft && !showRecipients {
            Text("Draft").foregroundStyle(.red).textStyle(format.sender, unread: row.isUnread).lineLimit(1)
        } else {
            Text(senderName).textStyle(format.sender, unread: row.isUnread).lineLimit(1)
        }
    }

    private var subjectText: some View {
        Text(row.displaySubject)
            .textStyle(format.subject, unread: row.isUnread)
            .lineLimit(1)
    }

    private var dateString: String {
        switch format.dateStyle {
        case .relative: return RelativeDate.short(row.receivedAt)
        case .time: return row.receivedAt.formatted(date: .numeric, time: .omitted)
        case .full: return row.receivedAt.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

enum RelativeDate {
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEE"); return f
    }()
    private static let date: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()

    static func short(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 7 { return weekday.string(from: d) }
        return date.string(from: d)
    }
}
