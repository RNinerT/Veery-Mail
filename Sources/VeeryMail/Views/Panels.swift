import AppKit
import VeeryMailCore
import SwiftUI

// MARK: - Command palette (⌘K)

struct CommandPalette: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    struct Command: Identifiable {
        var id: String { title }
        let title: String
        let icon: String
        let shortcut: String
        let run: () -> Void
    }

    private var commands: [Command] {
        var list: [Command] = [
            Command(title: "New Message", icon: "square.and.pencil", shortcut: "C") { store.compose() },
            Command(title: "Reply", icon: "arrowshape.turn.up.left", shortcut: "R") { store.reply(all: false) },
            Command(title: "Reply All", icon: "arrowshape.turn.up.left.2", shortcut: "A") { store.reply(all: true) },
            Command(title: "Forward", icon: "arrowshape.turn.up.right", shortcut: "F") { store.forward() },
            Command(title: "Archive", icon: "archivebox", shortcut: "E") { store.archive() },
            Command(title: "Move to Trash", icon: "trash", shortcut: "#") { store.trash() },
            Command(title: "Mark as Spam", icon: "xmark.bin", shortcut: "!") { store.markSpam() },
            Command(title: "Toggle Read", icon: "envelope.open", shortcut: "U") { store.toggleRead() },
            Command(title: "Toggle Flag", icon: "flag", shortcut: "S") { store.toggleFlag() },
            Command(title: "Masked Email…", icon: "theatermasks", shortcut: "⇧⌘M") { store.showMaskedEmail = true },
            Command(title: "Refresh", icon: "arrow.clockwise", shortcut: "⌥⌘R") { Task { await store.syncNow() } },
            Command(title: "Go to Unread", icon: "envelope.badge", shortcut: "") { store.source = .unread },
            Command(title: "Go to Flagged", icon: "flag", shortcut: "") { store.source = .flagged },
        ]
        for option in SnoozePresets.options() {
            list.append(Command(title: "Snooze: \(option.name)", icon: "clock", shortcut: "") {
                store.snooze(until: option.date)
            })
        }
        for item in store.mailboxTree {
            list.append(Command(title: "Go to \(item.mailbox.name)", icon: item.mailbox.systemImage, shortcut: "") {
                store.source = .mailbox(item.mailbox.id)
            })
            list.append(Command(title: "Move to \(item.mailbox.name)", icon: "folder", shortcut: "") {
                store.move(to: item.mailbox.id, label: "Moved to \(item.mailbox.name)")
            })
        }
        return list
    }

    private var filtered: [Command] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var results = q.isEmpty ? Array(commands.prefix(12)) : commands.filter { Self.fuzzy(q, $0.title) }
        if !q.isEmpty {
            let search = Command(title: "Search mail for “\(q)”", icon: "magnifyingglass", shortcut: "") {
                store.searchText = q
                store.source = .search(q)
            }
            // A query with operators (from:, is:unread …) is clearly a search, so it goes first.
            if q.contains(":") { results.insert(search, at: 0) } else { results.append(search) }
        }
        return results
    }

    /// Substring or subsequence match: "arch" → "Archive", "mtt" → "Move to Trash".
    static func fuzzy(_ needle: String, _ haystack: String) -> Bool {
        let n = needle.lowercased(), h = haystack.lowercased()
        if h.contains(n) { return true }
        let compact = n.filter { $0 != " " }
        var i = compact.startIndex
        for ch in h where i < compact.endIndex && ch == compact[i] {
            i = compact.index(after: i)
        }
        return i == compact.endIndex
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            TextField("Type a command, mailbox, or search…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit { run(items, highlighted) }
                .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled }
                .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, cmd in
                            HStack {
                                Image(systemName: cmd.icon).frame(width: 20)
                                Text(cmd.title)
                                Spacer()
                                Text(cmd.shortcut).foregroundStyle(.secondary).font(.caption.monospaced())
                            }
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(idx == highlighted ? Theme.accent.opacity(0.18) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { run(items, idx) }
                            .id(idx)
                        }
                    }
                }
                .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
            }
        }
        .frame(width: 520, height: 380)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func run(_ items: [Command], _ index: Int) {
        guard items.indices.contains(index) else { return }
        dismiss()
        items[index].run()
    }
}

// MARK: - Masked Email (Fastmail)

struct MaskedEmailView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MaskedEmail] = []
    @State private var loading = true
    @State private var error: String?
    @State private var filter = ""
    @State private var newDomain = ""
    @State private var newDescription = ""

    private var visible: [MaskedEmail] {
        let base = items.filter { $0.state != "deleted" }
            .sorted { ($0.lastMessageAt ?? $0.createdAt ?? .distantPast) > ($1.lastMessageAt ?? $1.createdAt ?? .distantPast) }
        guard !filter.isEmpty else { return base }
        let f = filter.lowercased()
        return base.filter {
            $0.email.lowercased().contains(f) || ($0.forDomain ?? "").lowercased().contains(f)
                || ($0.description ?? "").lowercased().contains(f)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Masked Email").font(.title2.weight(.semibold))
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            GroupBox("Create new") {
                HStack {
                    TextField("Website (e.g. example.com)", text: $newDomain)
                    TextField("Description", text: $newDescription)
                    Button("Create & Copy") { create() }
                        .disabled(newDomain.isEmpty && newDescription.isEmpty)
                }
                .textFieldStyle(.roundedBorder)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Table(visible) {
                    TableColumn("Address") { m in
                        Text(m.email).textSelection(.enabled)
                            .foregroundStyle(m.state == "disabled" ? .secondary : .primary)
                    }
                    TableColumn("For") { m in Text(m.forDomain ?? m.description ?? "") }
                    TableColumn("Last mail") { m in
                        Text(m.lastMessageAt.map { RelativeDate.short($0) } ?? "—").foregroundStyle(.secondary)
                    }
                    .width(90)
                    TableColumn("") { m in
                        HStack {
                            Button { copy(m.email) } label: { Image(systemName: "doc.on.doc") }
                                .help("Copy")
                            Button(m.state == "disabled" ? "Enable" : "Block") {
                                setState(m, m.state == "disabled" ? "enabled" : "disabled")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(110)
                }
            }
            HStack {
                Text("\(visible.count) addresses").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 480)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.client else { return }
        do {
            items = try await client.maskedEmails()
        } catch {
            self.error = "Couldn't load Masked Email. Make sure your API token includes the Masked Email scope. (\(error.localizedDescription))"
        }
        loading = false
    }

    private func create() {
        guard let client = store.client else { return }
        Task {
            do {
                let m = try await client.createMaskedEmail(forDomain: newDomain, description: newDescription)
                items.insert(m, at: 0)
                copy(m.email)
                newDomain = ""; newDescription = ""
                store.showToast("Created \(m.email) — copied", undo: nil)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func setState(_ m: MaskedEmail, _ state: String) {
        guard let client = store.client, let idx = items.firstIndex(of: m) else { return }
        let old = items[idx].state
        items[idx].state = state
        Task {
            do { try await client.setMaskedEmailState(id: m.id, state: state) } catch {
                if let i = items.firstIndex(where: { $0.id == m.id }) { items[i].state = old }
                self.error = error.localizedDescription
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Login

struct LoginView: View {
    @Environment(MailStore.self) private var store
    @State private var token = ""

    private static let steps: [(String, String)] = [
        ("Open Fastmail in your browser and sign in.", "Use the button below, or go to app.fastmail.com."),
        ("Go to Settings → Privacy & Security → Integrations.", "Then open the API tokens section."),
        ("Choose New API token.", "Give it a name you will recognize, such as “Veery Mail on my Mac”."),
        ("Set the access.", "Leave Read-only off, because Veery Mail needs to archive, delete and send. Turn on Mail, Email submission (so you can send) and Masked Email."),
        ("Create the token and copy it.", "Fastmail shows the token only once, so copy it before closing the window. It starts with “fmu1-”."),
        ("Paste it below and choose Sign In.", "Veery Mail keeps it in your Mac’s Keychain."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Image(systemName: "bird")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text("Veery Mail").font(.largeTitle.weight(.bold))
                    Text("A fast, native client for Fastmail. Sign in with an API token.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("How to create your API token").font(.headline)
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(width: 22, height: 22)
                                .background(Theme.accent.opacity(0.18), in: Circle())
                                .foregroundStyle(Theme.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(step.0).font(.callout.weight(.medium))
                                Text(step.1).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Step \(index + 1). \(step.0) \(step.1)")
                    }
                    HStack(spacing: 14) {
                        Link("Open Fastmail", destination: URL(string: "https://app.fastmail.com/")!)
                        Link("Fastmail’s own guide", destination: URL(string: "https://www.fastmail.help/hc/en-us/articles/5254602856719")!)
                    }
                    .font(.callout)
                    .padding(.top, 2)
                    Text("Menu names can change slightly. If you do not see one, look for the page that lists API tokens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(width: 460, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.rim))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste your token").font(.headline)
                    HStack {
                        SecureField("fmu1-…", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { store.signIn(token: token) }
                        Button("Paste") {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                token = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                        .help("Paste the token from the clipboard")
                    }
                    if let error = store.lastError {
                        Text(error).foregroundStyle(.red).font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 460)

                Button("Sign In") { store.signIn(token: token) }
                    .keyboardShortcut(.defaultAction)
                    .primaryButton()
                    .disabled(token.isEmpty || store.phase == .connecting)
            }
            .padding(.vertical, 36)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MessageListSettings()
                .tabItem { Label("Message List", systemImage: "list.bullet.rectangle") }
        }
    }
}

struct GeneralSettings: View {
    @Environment(MailStore.self) private var store
    @AppStorage("undoSendSeconds") private var undoSeconds = 10.0
    @AppStorage("markReadDelay") private var markReadDelay = 0.0
    @AppStorage("loadRemoteContent") private var loadRemote = false
    @AppStorage("notifications") private var notifications = true
    @AppStorage("defaultIdentityId") private var defaultIdentityId = ""
    @AppStorage("appearance") private var appearance = "dark"
    @AppStorage("readerDim") private var readerDim = false
    @AppStorage("sidebar.showConditions") private var showConditions = true

    var body: some View {
        Form {
            Section("Sending") {
                Picker("Undo send window", selection: $undoSeconds) {
                    Text("Off").tag(0.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("20 seconds").tag(20.0)
                    Text("30 seconds").tag(30.0)
                }
                Picker("Default From", selection: $defaultIdentityId) {
                    Text("Automatic").tag("")
                    ForEach(store.identities) { Text($0.address.formatted).tag($0.id) }
                }
            }
            Section("Appearance") {
                Toggle("Show the Inbox summary card at the top of the sidebar", isOn: $showConditions)
                Picker("Theme", selection: $appearance) {
                    Text("Ink (dark)").tag("dark")
                    Text("Light").tag("light")
                    Text("Match System").tag("system")
                }
            }
            Section("Reading") {
                Picker("Mark as read", selection: $markReadDelay) {
                    Text("Immediately").tag(0.0)
                    Text("After 2 seconds").tag(2.0)
                    Text("Never (manual)").tag(-1.0)
                }
                Toggle("Load remote images by default (allows tracking pixels)", isOn: $loadRemote)
                Toggle("Dim reader instead of paper (dark theme only)", isOn: $readerDim)
            }
            Section("Notifications") {
                Toggle("Notify about new Inbox mail", isOn: $notifications)
            }
            Section("Account") {
                if let user = store.client?.session?.username {
                    LabeledContent("Signed in as", value: user)
                }
                Button("Sign Out", role: .destructive) { store.signOut() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical)
    }
}

// MARK: - Message list formatting

struct MessageListSettings: View {
    private var f = ListFormatStorage()
    @State private var element: ListFormat.Element = .sender

    private var unreadDotColor: Binding<Color> {
        Binding(get: { f.format.unreadDotColor }, set: { f.unreadDotHex = $0.hexString })
    }

    var body: some View {
        VStack(spacing: 0) {
            preview
            Picker("Element", selection: $element) {
                ForEach(ListFormat.Element.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Form {
                StyleEditor(element: element, style: f.binding(element))
                Section("Layout") {
                    Picker("First line shows", selection: f.$firstLine) {
                        ForEach(ListFormat.FirstLine.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Preview lines", selection: f.$previewLines) {
                        Text("None").tag(0)
                        Text("One").tag(1)
                        Text("Two").tag(2)
                        Text("Three").tag(3)
                    }
                    Picker("Date format", selection: f.$dateStyle) {
                        ForEach(ListFormat.DateStyle.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Row spacing", selection: f.$spacing) {
                        ForEach(ListFormat.Spacing.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show sender avatars", isOn: f.$showAvatars)
                    Toggle("Show unread dot", isOn: f.$showUnreadDot)
                    LabeledContent("Unread dot color") {
                        HStack {
                            ColorPicker("Unread dot color", selection: unreadDotColor, supportsOpacity: false)
                                .labelsHidden()
                            Button("Default") { f.unreadDotHex = "" }
                                .disabled(f.unreadDotHex.isEmpty)
                        }
                    }
                    .disabled(!f.showUnreadDot)
                    Toggle("Clean up sender names from mail relays (SimpleLogin)", isOn: f.$cleanSenders)
                }
                Section {
                    HStack {
                        Text("⌘= / ⌘− resize all list text; ⌘0 restores default sizes.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset Everything") { ListFormat.resetToDefaults() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 760)
    }

    private var preview: some View {
        let now = Date()
        let samples = [
            EmailSummary(id: "p1", threadId: "p1", keywords: [:],
                         from: [EmailAddress(name: "Ada Park", email: "ada@example.com")],
                         subject: "Q4 creative review deck", receivedAt: now.addingTimeInterval(-1_800),
                         preview: "Attached is the latest version with the market-by-market breakdown. Can you take a look before Thursday?",
                         hasAttachment: true),
            EmailSummary(id: "p2", threadId: "p2", keywords: ["$seen": true, "$flagged": true],
                         from: [EmailAddress(name: "Fastmail", email: "support@example.com")],
                         subject: "Your weekly summary", receivedAt: now.addingTimeInterval(-90_000),
                         preview: "Here's what happened in your account this week."),
            EmailSummary(id: "p3", threadId: "p3", keywords: ["$seen": true],
                         from: [EmailAddress(name: "Sam Rivera", email: "sam@example.com")],
                         subject: "Lunch Friday?", receivedAt: now.addingTimeInterval(-400_000),
                         preview: "There's a new place on Elm Street that's supposed to be great."),
        ]
        let format = f.format
        return VStack(alignment: .leading, spacing: 0) {
            Text("PREVIEW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
            ForEach(samples) { row in
                MessageRow(row: row, format: format)
                    .padding(.horizontal, 12)
                Divider().padding(.leading, 12)
            }
        }
        .background(Theme.canvas)
    }
}

/// Editor for one element's `TextStyle`.
struct StyleEditor: View {
    let element: ListFormat.Element
    @Binding var style: TextStyle

    private var unreadColor: Binding<Color> {
        Binding(get: { Color(hex: style.unreadHex) ?? .white },
                set: { style.unreadHex = $0.hexString })
    }

    private var customColor: Binding<Color> {
        Binding(get: { Color(hex: style.customHex) ?? .gray },
                set: { style.customHex = $0.hexString })
    }

    var body: some View {
        Section("\(element.label) font") {
            Picker("Font", selection: $style.family) {
                Text("System (San Francisco)").tag("")
                Divider()
                ForEach(ListFormat.fontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            if style.family.isEmpty {
                Picker("Design", selection: $style.design) {
                    ForEach(TextStyle.Design.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            LabeledContent("Size") {
                HStack {
                    Slider(value: $style.size, in: TextStyle.sizeRange, step: 0.5)
                    Text(String(format: "%g pt", style.size))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
            Picker("Weight, read messages", selection: $style.readWeight) {
                ForEach(TextStyle.Weight.allCases) { Text($0.label).tag($0) }
            }
            Picker("Weight, unread messages", selection: $style.unreadWeight) {
                ForEach(TextStyle.Weight.allCases) { Text($0.label).tag($0) }
            }
        }
        Section("\(element.label) style") {
            Toggle("Italic", isOn: $style.italic)
            Toggle("Underline", isOn: $style.underline)
            Picker("Color", selection: $style.color) {
                ForEach(TextStyle.ColorChoice.allCases) { Text($0.label).tag($0) }
            }
            if style.color == .custom {
                ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
            }
            Toggle("Different color when unread", isOn: $style.unreadColorOn)
            if style.unreadColorOn {
                ColorPicker("Unread color", selection: unreadColor, supportsOpacity: false)
            }
            Picker("Letter case", selection: $style.letterCase) {
                ForEach(TextStyle.LetterCase.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Letter spacing") {
                HStack {
                    Slider(value: $style.tracking, in: -1...4, step: 0.25)
                    Text(String(format: "%+.2g", style.tracking))
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
            HStack {
                Spacer()
                Button("Reset \(element.label) Style") { style = element.defaultStyle }
            }
        }
    }
}
