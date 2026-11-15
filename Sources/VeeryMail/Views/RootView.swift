import AppKit
import VeeryMailCore
import SwiftUI

struct RootView: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        switch store.phase {
        case .signedOut:
            LoginView()
        case .connecting where store.mailboxes.isEmpty:
            ProgressView("Connecting to Fastmail…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            MainView()
        }
    }
}

struct MainView: View {
    @Environment(MailStore.self) private var store
    @State private var columns = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 340)
        } content: {
            InboxListView()
                .overlay(alignment: .bottom) { StatusOverlay() }
                .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 560)
        } detail: {
            ReaderView()
        }
        // Everything lives in the window's top row: search and compose on the left,
        // the actions for the open conversation on the right, above the reader.
        .toolbar {
            ToolbarItem { CommandBarButton() }
            ToolbarItem {
                Button { store.compose() } label: { Label("New Message", systemImage: "square.and.pencil") }
                    .help("New Message (C)")
            }
            ToolbarItem { Spacer() }
            ToolbarItem {
                // Says what the actions apply to when it isn't simply the open conversation.
                if store.selection.count > 1 {
                    Text("\(store.selection.count) selected")
                        .font(Theme.Typeface.meta.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Actions apply to \(store.selection.count) selected conversations")
                }
            }
            // Reply, Archive and the rest act on the selection: the open conversation, or every selected row.
            ToolbarItemGroup {
                let none = store.selection.isEmpty
                let single = store.selection.count == 1
                Button { store.reply(all: false) } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left").labelStyle(.titleAndIcon)
                }
                .help("Reply (R)")
                .disabled(!single || store.thread.isEmpty)
                Button { store.reply(all: true) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    .help("Reply All (A)")
                    .disabled(!single || store.thread.isEmpty)
                Button { store.forward() } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    .help("Forward (F)")
                    .disabled(!single || store.thread.isEmpty)
                Button { store.archive() } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive (E)")
                    .disabled(none)
                Menu {
                    ForEach(SnoozePresets.options(), id: \.name) { option in
                        Button(option.name) { store.snooze(until: option.date) }
                    }
                } label: { Label("Snooze", systemImage: "clock") }
                    .help("Snooze (H = tomorrow)")
                    .disabled(none)
                Button { store.toggleFlag() } label: { Label("Flag", systemImage: "flag") }
                    .help("Flag (S)")
                    .disabled(none)
                Button { store.toggleRead() } label: { Label("Read / Unread", systemImage: "envelope.badge") }
                    .help("Toggle Read (U)")
                    .disabled(none)
                Button { store.trash() } label: { Label("Trash", systemImage: "trash") }
                    .help("Move to Trash (#)")
                    .disabled(none)
            }
        }
        .toolbarBackground(Theme.nav, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale()
        }
        .sheet(item: $store.composer) { draft in
            ComposeView(draft: draft)
        }
        .sheet(isPresented: $store.showCommandPalette) {
            CommandPalette()
        }
        .sheet(isPresented: $store.showMaskedEmail) {
            MaskedEmailView()
        }
    }
}

/// The single entry point for search and every command.
struct CommandBarButton: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        Button { store.showCommandPalette = true } label: {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "magnifyingglass")
                Text("Search or command")
                Spacer(minLength: 0)
                Text("⌘K").font(.caption.monospaced())
            }
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 10)
            .frame(width: 230, height: 26)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.rim))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Search mail or run a command (⌘K or /)")
        .accessibilityLabel("Search mail or run a command")
    }
}

/// Undo-send countdown and action toasts. Solid surfaces, so they read the same with Reduce Transparency.
struct StatusOverlay: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            if let pending = store.pendingSend {
                HStack(spacing: Theme.Space.m) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = max(0, Int(pending.deadline.timeIntervalSince(ctx.date).rounded(.up)))
                        Text(pending.sendAt == nil ? "Sending in \(left)s…" : "Scheduling in \(left)s…")
                            .monospacedDigit()
                    }
                    Button("Undo") { store.undoSend() }
                        .keyboardShortcut("z", modifiers: .command)
                }
                .toastStyle()
            }
            if let toast = store.toast {
                HStack(spacing: Theme.Space.m) {
                    Text(toast.message).lineLimit(2)
                    if let undo = toast.undo {
                        Button("Undo") {
                            undo()
                            store.toast = nil
                        }
                        .keyboardShortcut("z", modifiers: .command)
                    }
                }
                .toastStyle()
                .id(toast.id)
            }
        }
        .padding(.bottom, Theme.Space.l)
        .padding(.horizontal, Theme.Space.m)
        .animation(.snappy(duration: 0.2), value: store.toast?.id)
        .animation(.snappy(duration: 0.2), value: store.pendingSend?.id)
    }
}

private extension View {
    func toastStyle() -> some View {
        self.foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.rim))
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Sidebar

/// Custom-drawn so the selection has its own shape and color, counts sit on the trailing edge,
/// and the long folder list collapses under one heading.
struct SidebarView: View {
    @Environment(MailStore.self) private var store
    /// Ids of collapsed folders, comma-separated so it persists in UserDefaults.
    @AppStorage("sidebar.collapsedMailboxes") private var collapsedStorage = ""
    @AppStorage("sidebar.foldersExpanded") private var foldersExpanded = true

    private static let favoriteRoles = ["inbox", "drafts", "sent"]
    private static let systemRoles = ["archive", "junk", "trash"]

    var body: some View {
        let tree = MailboxTree(store.mailboxes)
        let pinned = Set(Self.favoriteRoles + Self.systemRoles)
        let folders = tree.children(of: nil).filter { !pinned.contains($0.role ?? "") }
        let peak = max(folders.map { tree.descendantUnread(of: $0.id) + MailboxTree.badgeCount($0) }.max() ?? 0, 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ConditionsCard()
                    .padding(.top, Theme.Space.s)
                heading("Favorites")
                role("inbox", tree)
                SidebarRow(title: "Unread", icon: "envelope.badge", count: 0, isSelected: store.source == .unread,
                           action: { store.source = .unread })
                SidebarRow(title: "Flagged", icon: "flag", count: 0, isSelected: store.source == .flagged,
                           action: { store.source = .flagged })
                role("drafts", tree)
                role("sent", tree)

                heading("Mailboxes")
                ForEach(Self.systemRoles, id: \.self) { role($0, tree) }

                Button { foldersExpanded.toggle() } label: {
                    HStack(spacing: Theme.Space.xs) {
                        Text("FOLDERS")
                        Text("\(folders.count)").foregroundStyle(Theme.secondaryText.opacity(0.8))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(foldersExpanded ? 90 : 0))
                    }
                    .font(Theme.Typeface.sectionLabel)
                    .tracking(0.8)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Folders, \(folders.count)")
                .accessibilityValue(foldersExpanded ? "Expanded" : "Collapsed")
                .help(foldersExpanded ? "Hide folders" : "Show folders")

                if foldersExpanded {
                    ForEach(folders) { mailbox in
                        MailboxNode(mailbox: mailbox, tree: tree, depth: 0, collapsed: collapsedBinding, peak: peak)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.bottom, Theme.Space.l)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SyncStatus()
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.nav)
                .overlay(alignment: .top) { Rectangle().fill(Theme.rim).frame(height: 1) }
        }
        .background(Theme.nav.ignoresSafeArea())
        .contextMenu {
            Button("Expand All Folders") { collapsedStorage = "" }
            Button("Collapse All Folders") {
                collapsedStorage = tree.parentIds.sorted().joined(separator: ",")
            }
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.Typeface.sectionLabel)
            .tracking(0.8)
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, Theme.Space.s)
            .padding(.top, Theme.Space.l)
            .padding(.bottom, Theme.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func role(_ role: String, _ tree: MailboxTree) -> some View {
        if let mailbox = store.mailbox(role: role) {
            MailboxNode(mailbox: mailbox, tree: tree, depth: 0, collapsed: collapsedBinding)
        }
    }

    private var collapsedBinding: Binding<Set<String>> {
        Binding(
            get: { Set(collapsedStorage.split(separator: ",").map(String.init)) },
            set: { collapsedStorage = $0.sorted().joined(separator: ",") }
        )
    }
}

/// Parent → children lookup for the mailbox hierarchy, system folders first.
struct MailboxTree {
    private let byParent: [String: [Mailbox]]

    init(_ mailboxes: [Mailbox]) {
        byParent = Dictionary(grouping: mailboxes, by: { $0.parentId ?? "" }).mapValues { list in
            list.sorted { ($0.roleRank, $0.sortOrder, $0.name.lowercased()) < ($1.roleRank, $1.sortOrder, $1.name.lowercased()) }
        }
    }

    func children(of id: String?) -> [Mailbox] { byParent[id ?? ""] ?? [] }

    var parentIds: [String] { byParent.keys.filter { !$0.isEmpty } }

    /// Unread threads in every folder below this one (shown on a collapsed parent).
    func descendantUnread(of id: String) -> Int {
        children(of: id).reduce(0) { sum, child in
            sum + MailboxTree.badgeCount(child) + descendantUnread(of: child.id)
        }
    }

    static func badgeCount(_ mailbox: Mailbox) -> Int {
        switch mailbox.role {
        // "Unread" in these folders is mail you've already dealt with, so a count is just noise.
        case "trash", "junk", "sent", "archive": return 0
        case "drafts": return mailbox.totalEmails
        default: return mailbox.unreadThreads
        }
    }
}

/// One folder and, when expanded, its subfolders.
struct MailboxNode: View {
    @Environment(MailStore.self) private var store
    let mailbox: Mailbox
    let tree: MailboxTree
    let depth: Int
    @Binding var collapsed: Set<String>
    /// The busiest top-level folder's unread count; 0 hides the intensity bar (Favorites, system mailboxes).
    var peak = 0

    var body: some View {
        let kids = tree.children(of: mailbox.id)
        let isExpanded = !collapsed.contains(mailbox.id)
        let hidden = kids.isEmpty || isExpanded ? 0 : tree.descendantUnread(of: mailbox.id)
        SidebarRow(title: mailbox.name, icon: mailbox.systemImage,
                   count: MailboxTree.badgeCount(mailbox) + hidden,
                   countIncludesChildren: hidden > 0,
                   intensity: peak > 0 ? Double(MailboxTree.badgeCount(mailbox) + hidden) / Double(peak) : 0,
                   depth: depth,
                   expanded: kids.isEmpty ? nil : isExpanded,
                   isSelected: store.source == .mailbox(mailbox.id),
                   onToggle: {
                       if isExpanded { collapsed.insert(mailbox.id) } else { collapsed.remove(mailbox.id) }
                   },
                   action: { store.source = .mailbox(mailbox.id) })
            .dropDestination(for: String.self) { ids, _ in
                let rows = store.messages.filter { ids.contains($0.id) }
                guard !rows.isEmpty else { return false }
                store.move(rows, to: mailbox.id, label: "Moved to \(mailbox.name)")
                return true
            }
        if isExpanded {
            ForEach(kids) { child in
                MailboxNode(mailbox: child, tree: tree, depth: depth + 1, collapsed: $collapsed, peak: peak)
            }
        }
    }
}

struct SidebarRow: View {
    let title: String
    let icon: String
    let count: Int
    var countIncludesChildren = false
    /// 0…1: how much unread mail this folder holds relative to the busiest folder,
    /// drawn as a thin bar like precipitation intensity.
    var intensity: Double = 0
    var depth = 0
    /// nil = no subfolders; otherwise whether they are showing.
    var expanded: Bool? = nil
    let isSelected: Bool
    var onToggle: () -> Void = {}
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            // Disclosure control (or the space it would take, so icons stay in one column).
            if let expanded {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityLabel(expanded ? "Collapse \(title)" : "Expand \(title)")
            } else {
                Color.clear.frame(width: 14, height: 24)
            }
            Button(action: action) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: icon)
                        .frame(width: 18)
                        .foregroundStyle(isSelected ? Theme.text : Theme.secondaryText)
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: Theme.Space.xs)
                    if count > 0 {
                        Text("\(count)")
                            .font(Theme.Typeface.meta.monospacedDigit())
                            .foregroundStyle(countIncludesChildren ? Theme.accent : Theme.secondaryText)
                            .layoutPriority(1)
                    }
                }
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .padding(.trailing, Theme.Space.s)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth) * 14 + 2)
        .overlay(alignment: .bottomLeading) {
            if intensity > 0 {
                GeometryReader { geo in
                    let start = CGFloat(depth) * 14 + 2 + 14 + 26   // under the name, past the icon
                    Capsule()
                        .fill(Theme.accent.opacity(0.55))
                        .frame(width: max(6, (geo.size.width - start - Theme.Space.s) * min(intensity, 1)), height: 2)
                        .offset(x: start, y: geo.size.height - 4)
                }
                .accessibilityHidden(true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Theme.selection : (hovering ? Theme.hover : Color.clear)))
        .onHover { hovering = $0 }
        .help(count > 0 && countIncludesChildren ? "\(title) — count includes subfolders" : title)   // full name when truncated
        .accessibilityElement(children: .contain)
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
