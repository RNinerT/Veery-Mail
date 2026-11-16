import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeeryMailCore

/// One compose window. Separate from the main window so it can be moved, resized and kept
/// open beside the inbox.
struct ComposeWindow: View {
    @Environment(MailStore.self) private var store
    let id: UUID
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if store.composeDrafts[id] != nil {
                ComposeView(id: id, window: window)
            } else {
                // Sent, discarded, or a window restored after relaunch without a draft.
                Color.clear.onAppear { window?.close() }
            }
        }
        .background(WindowAccessor { w in
            window = w
            w.setFrameAutosaveName("VeeryMail.Compose")
        })
        .onChange(of: store.composeDrafts[id] == nil) { _, gone in if gone { window?.close() } }
    }
}

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    let id: UUID
    let window: NSWindow?

    @State private var controller = RichTextController()
    @State private var importing = false
    @State private var uploading = 0
    @State private var showSchedule = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var confirmCancel = false
    @State private var showEmoji = false
    @State private var showLink = false
    @State private var linkText = "https://"
    @State private var problem: String?
    @State private var closeAfterSave = false
    @State private var suggestions: [EmailAddress] = []
    @State private var aiInstruction = ""
    @State private var aiTask: Task<Void, Never>?
    @State private var syncTask: Task<Void, Never>?
    @State private var guardInstalled = false
    @AppStorage("ai.enabled") private var aiEnabled = false

    private var draft: Binding<ComposeDraft> {
        Binding(get: { store.composeDrafts[id] ?? ComposeDraft(identityId: nil) },
                set: { store.composeDrafts[id] = $0 })
    }

    private var saver: DraftSaveCoordinator? { store.draftSaver(for: id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FormattingBar(controller: controller, showEmoji: $showEmoji, showLink: $showLink)
            if aiEnabled || store.isDemo { aiBar }
            Divider()
            RichTextEditor(controller: controller, initialRTF: draft.wrappedValue.bodyRTF,
                           initialText: draft.wrappedValue.body)
                .dropDestination(for: URL.self) { urls, _ in attach(urls); return true }
            if !draft.wrappedValue.allAttachments.isEmpty || uploading > 0 {
                Divider()
                attachmentList
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 640)
        .background(Theme.canvas)
        .navigationTitle(draft.wrappedValue.subject.isEmpty ? "New Message" : draft.wrappedValue.subject)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .onAppear {
            suggestions = store.knownAddresses
            controller.onChange = { scheduleSync() }
        }
        .onChange(of: window) { _, w in installCloseGuard(w) }
        .task { await autosaveLoop() }
        .onChange(of: draft.wrappedValue.identityId) { _, newId in swapSignature(to: newId) }
        .confirmationDialog("Delete this draft?", isPresented: $confirmCancel) {
            Button("Save Draft and Close") { Task { await saveAndClose() } }
            Button("Delete Draft", role: .destructive) { store.discardDraft(id) }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Deleting removes it from your Drafts on Fastmail too.")
        }
        .sheet(isPresented: $showSchedule) { scheduleSheet }
        .alert("Add Link", isPresented: $showLink) {
            TextField("https://", text: $linkText)
            Button("Add") { controller.setLink(URL(string: linkText)) }
            Button("Remove Link") { controller.setLink(nil) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Select the text first, then enter the address.") }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 0) {
            row("From") {
                Picker("From", selection: draft.identityId) {
                    ForEach(store.identities) { identity in
                        Text(identity.address.formatted).tag(Optional(identity.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            addressRow(.to, text: draft.to) {
                Button(draft.wrappedValue.showCc ? "Hide Cc" : "Cc/Bcc") { draft.wrappedValue.showCc.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if draft.wrappedValue.showCc {
                addressRow(.cc, text: draft.cc) { EmptyView() }
                addressRow(.bcc, text: draft.bcc) { EmptyView() }
            }
            row("Subject") {
                TextField("Subject", text: draft.subject)
                    .textFieldStyle(.plain)
                    .labelsHidden()
            }
        }
    }

    private func addressRow<Trailing: View>(_ field: ComposeDraft.Field, text: Binding<String>,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        let invalid = RecipientParser.parse(text.wrappedValue).filter { $0.address == nil }
        return VStack(alignment: .leading, spacing: 0) {
            row(field.rawValue) {
                AddressField(text: text, suggestions: suggestions, invalid: !invalid.isEmpty, label: field.rawValue)
                trailing()
            }
            if !invalid.isEmpty {
                Text("Not a valid address: " + invalid.map { "“\($0.raw)”" }.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 82)
                    .padding(.bottom, 6)
                    .accessibilityLabel("\(field.rawValue) field has invalid addresses: " + invalid.map(\.raw).joined(separator: ", "))
            }
        }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
                content()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider().padding(.leading, 12)
        }
    }

    // MARK: AI

    private var aiBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.accent).accessibilityHidden(true)
            if draft.wrappedValue.threadId != nil {
                TextField("Tell AI what to say, e.g. “yes, but suggest Thursday”", text: $aiInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { draftWithAI() }
                Button("Draft Reply") { draftWithAI() }
                    .disabled(aiTask != nil)
                    .keyboardShortcut("d", modifiers: [.command, .option])
            } else {
                TextField("Tell AI what to write, e.g. “invite the team to lunch Friday at noon”", text: $aiInstruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { writeWithAI() }
                Button("Write") { writeWithAI() }
                    .disabled(aiTask != nil)
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .help("Writes the message from your instruction, and a subject if there isn’t one (⌥⌘D)")
            }
            Menu("Rewrite") {
                ForEach(AIPromptBuilder.RewriteStyle.allCases, id: \.self) { style in
                    Button(style.rawValue) { rewrite(style) }
                }
            }
            .fixedSize()
            .disabled(aiTask != nil)
            .help("Rewrites the selected text, or the whole message if nothing is selected (⌥⌘E for shorter)")
            if aiTask != nil {
                ProgressView().controlSize(.small)
                Button("Stop") { aiTask?.cancel(); aiTask = nil }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.card.opacity(0.4))
    }

    /// New message: writes the body (and a subject when empty) from the instruction. The result is
    /// collected first so a suggested subject line can go into the Subject field, then inserted.
    private func writeWithAI() {
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, aiTask == nil else { return }
        let current = draft.wrappedValue
        let recipients = EmailAddress.parseList(current.to) + EmailAddress.parseList(current.cc) + EmailAddress.parseList(current.bcc)
        let identity = store.identities.first { $0.id == current.identityId } ?? store.defaultIdentity
        problem = nil
        aiTask = Task {
            defer { aiTask = nil }
            do {
                var examples: [String] = []
                if let client = store.client { examples = await styleExamples(client) }
                let prompt = try AIPromptBuilder.compose(instruction: instruction, recipients: recipients, subject: current.subject,
                                                         myName: identity?.name.isEmpty == false ? identity!.name : "me",
                                                         styleExamples: examples, exclusions: store.ai.exclusions)
                var result = ""
                try await store.ai.run(.compose, prompt: prompt) { result += $0 }
                try Task.checkCancellation()
                let split = AIPromptBuilder.splitSubject(result)
                if let subject = split.subject, draft.wrappedValue.subject.trimmingCharacters(in: .whitespaces).isEmpty {
                    draft.wrappedValue.subject = subject
                }
                guard !split.body.isEmpty else { return }
                controller.textView?.setSelectedRange(NSRange(location: 0, length: 0))
                controller.insert(split.body + "\n")
                aiInstruction = ""
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func draftWithAI() {
        let instruction = aiInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, let threadId = draft.wrappedValue.threadId, let client = store.client else {
            if store.isDemo { demoDraft() }
            return
        }
        let identity = store.identities.first { $0.id == draft.wrappedValue.identityId } ?? store.defaultIdentity
        aiTask = Task {
            defer { aiTask = nil }
            do {
                let thread = try await client.thread(threadId)
                let examples = await styleExamples(client)
                let prompt = try AIPromptBuilder.draftReply(thread, instruction: instruction,
                                                            myName: identity?.name ?? "me",
                                                            styleExamples: examples, exclusions: store.ai.exclusions)
                controller.textView?.setSelectedRange(NSRange(location: 0, length: 0))
                try await store.ai.run(.draftReply, prompt: prompt) { text in controller.insert(text) }
                controller.insert("\n")
                aiInstruction = ""
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func demoDraft() {
        aiTask = Task {
            defer { aiTask = nil }
            controller.textView?.setSelectedRange(NSRange(location: 0, length: 0))
            do {
                for try await event in DemoAIProvider().stream(system: "", user: "", maxTokens: 0) {
                    if case .text(let t) = event { controller.insert(t) }
                }
            } catch {}
        }
    }

    /// The user's own recent sent messages, as tone examples. One request; skipped on failure.
    private func styleExamples(_ client: JMAPClient) async -> [String] {
        guard let sent = store.mailbox(role: "sent"),
              let page = try? await client.queryEmails(filter: ["inMailbox": sent.id], limit: 3, collapseThreads: false),
              let details = try? await client.details(ids: page.emails.map(\.id)) else { return [] }
        return details.map { AIPromptBuilder.trimQuoted($0.plainTextFallback) }.filter { !$0.isEmpty }
    }

    private func rewrite(_ style: AIPromptBuilder.RewriteStyle) {
        let text = controller.selectedText.isEmpty ? controller.plainText : controller.selectedText
        aiTask = Task {
            defer { aiTask = nil }
            do {
                let prompt = try AIPromptBuilder.rewrite(text, style: style)
                var result = ""
                try await store.ai.run(.rewrite, prompt: prompt) { result += $0 }
                if !result.isEmpty { controller.replaceSelectionOrAll(with: result.trimmingCharacters(in: .whitespacesAndNewlines)) }
            } catch is CancellationError {
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    // MARK: Attachments and footer

    private var attachmentList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(draft.wrappedValue.allAttachments) { a in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").accessibilityHidden(true)
                        Text(a.name).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            draft.wrappedValue.attachments.removeAll { $0.blobId == a.blobId }
                            draft.wrappedValue.forwardedAttachments.removeAll { $0.blobId == a.blobId }
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(a.name)")
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
                }
                if uploading > 0 {
                    ProgressView().controlSize(.small)
                    Text("Uploading \(uploading)…").font(.caption)
                }
            }
            .padding(8)
        }
    }

    private var statusText: String? {
        if let problem { return problem }
        guard let saver else { return nil }
        if saver.isSaving { return "Saving…" }
        if let error = saver.lastError { return "Couldn’t save draft: \(error)" }
        if saver.savedSnapshot != nil { return saver.isDirty(draft.wrappedValue.snapshot) ? "Edited" : "Draft saved" }
        return nil
    }

    private var footer: some View {
        HStack {
            Button { importing = true } label: { Label("Attach", systemImage: "paperclip") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Save Draft") { Task { await saveAndClose() } }
                .keyboardShortcut("s")
                .help("Saves to Drafts on Fastmail and closes the window")
            if let status = statusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(problem != nil || saver?.lastError != nil ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") {
                if draft.wrappedValue.isEmpty && draft.wrappedValue.savedDraftId == nil { store.discardDraft(id) }
                else { confirmCancel = true }
            }
            .keyboardShortcut(.cancelAction)
            if store.supportsScheduledSend {
                Menu("Send Later") {
                    ForEach(SnoozePresets.options().dropFirst(), id: \.name) { option in
                        Button("\(option.name) – \(option.date.formatted(date: .abbreviated, time: .shortened))") {
                            send(at: option.date)
                        }
                    }
                    Divider()
                    Button("Pick Date & Time…") { showSchedule = true }
                }
                .fixedSize()
                .disabled(uploading > 0)
            }
            Button("Send") { send(at: nil) }
                .keyboardShortcut(.return, modifiers: .command)
                .primaryButton()
                .disabled(uploading > 0 || !draft.wrappedValue.hasRecipients || !draft.wrappedValue.invalidRecipients.isEmpty)
        }
        .padding(10)
    }

    private var scheduleSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Later").font(.headline)
            DatePicker("Send at", selection: $scheduleDate, in: Date()...)
                .datePickerStyle(.graphical)
            HStack {
                Spacer()
                Button("Cancel") { showSchedule = false }
                Button("Schedule") {
                    showSchedule = false
                    send(at: scheduleDate)
                }
                .primaryButton()
            }
        }
        .padding()
        .frame(width: 360)
    }

    // MARK: Actions

    /// Copies the editor's text into the draft (debounced while typing).
    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            syncNow()
        }
    }

    private func syncNow() {
        guard store.composeDrafts[id] != nil else { return }
        draft.wrappedValue.body = controller.plainText
        draft.wrappedValue.bodyRTF = controller.rtfData
        draft.wrappedValue.htmlBody = controller.html
        problem = nil
    }

    private func send(at date: Date?) {
        syncTask?.cancel()
        syncNow()
        Task {
            if let message = await store.send(id, sendAt: date) { problem = message }
        }
    }

    /// Saves, then closes only if the save succeeded. On failure the window stays open with
    /// everything intact and the error shown.
    private func saveAndClose() async {
        syncTask?.cancel()
        syncNow()
        if draft.wrappedValue.isEmpty && draft.wrappedValue.savedDraftId == nil {
            store.discardDraft(id)
            return
        }
        if await store.saveDraft(id) {
            store.closeComposer(id)
        } else {
            problem = saver?.lastError.map { "Couldn’t save the draft: \($0). Your message is still here." }
                ?? "Couldn’t save the draft. Your message is still here."
        }
    }

    /// Autosave every 20 seconds while there are unsaved edits (serialized with manual saves).
    private func autosaveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard store.composeDrafts[id] != nil else { return }
            syncNow()
            if !draft.wrappedValue.isEmpty, store.isDirty(id), saver?.isSaving == false {
                _ = await store.saveDraft(id)
            }
        }
    }

    private func swapSignature(to identityId: String?) {
        let reply = draft.wrappedValue.replyingToEmailId != nil
        let newBlock = Signatures.block(for: identityId, reply: reply)
        if let old = draft.wrappedValue.signatureBlock, old != newBlock {
            _ = controller.replaceFirst(old, with: newBlock ?? "")
        }
        draft.wrappedValue.signatureBlock = newBlock
    }

    private func attach(_ urls: [URL]) {
        guard let client = store.client else { return problem = "Attachments need a connection to Fastmail." }
        for url in urls {
            uploading += 1
            Task {
                defer { uploading -= 1 }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    let result = try await client.upload(data, type: type)
                    draft.wrappedValue.attachments.append(OutgoingAttachment(blobId: result.blobId, name: url.lastPathComponent,
                                                                             type: type, size: result.size))
                } catch { problem = error.localizedDescription }
            }
        }
    }

    /// Closing the window with unsaved changes saves first; if that fails the window stays open.
    private func installCloseGuard(_ window: NSWindow?) {
        guard let window, !guardInstalled else { return }
        guardInstalled = true
        WindowCloseProxy.install(on: window) { _ in
            syncNow()
            let current = draft.wrappedValue
            if current.isEmpty && current.savedDraftId == nil {
                store.discardDraft(id)
                return true
            }
            if !store.isDirty(id) {
                store.closeComposer(id)
                return true
            }
            Task { await saveAndClose() }
            return false
        }
    }
}

/// Formatting controls for the compose body.
struct FormattingBar: View {
    let controller: RichTextController
    @Binding var showEmoji: Bool
    @Binding var showLink: Bool

    var body: some View {
        HStack(spacing: 2) {
            tool("bold", "Bold (⌘B)") { controller.toggleTrait(.boldFontMask) }.keyboardShortcut("b")
            tool("italic", "Italic (⌘I)") { controller.toggleTrait(.italicFontMask) }.keyboardShortcut("i")
            tool("underline", "Underline (⌘U)") { controller.toggle(.underlineStyle) }.keyboardShortcut("u")
            tool("strikethrough", "Strikethrough") { controller.toggle(.strikethroughStyle) }
            divider
            tool("textformat.size.smaller", "Smaller text") { controller.adjustSize(by: -2) }
            tool("textformat.size.larger", "Bigger text") { controller.adjustSize(by: 2) }
            Menu {
                Button("Automatic") { controller.setColor(nil) }
                Divider()
                ForEach(Self.colors.indices, id: \.self) { i in
                    Button { controller.setColor(Self.colors[i].1) } label: {
                        Label(Self.colors[i].0, systemImage: "circle.fill")
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Text color")
            .accessibilityLabel("Text color")
            divider
            tool("list.bullet", "Bulleted list") { controller.applyLineStyle(.bullets) }
            tool("list.number", "Numbered list") { controller.applyLineStyle(.numbers) }
            tool("text.quote", "Quote") { controller.applyLineStyle(.quote) }
            tool("link", "Add link (⇧⌘K)") { showLink = true }.keyboardShortcut("k", modifiers: [.command, .shift])
            tool("eraser", "Clear formatting") { controller.clearFormatting() }
            divider
            Button { showEmoji.toggle() } label: {
                Image(systemName: "face.smiling").frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .help("Emoji (⌃⌘Space for the system picker)")
            .accessibilityLabel("Emoji")
            .popover(isPresented: $showEmoji, arrowEdge: .bottom) {
                EmojiPicker { emoji in controller.insert(emoji) }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .onAppear {
            if UserDefaults.standard.bool(forKey: "uitest.openEmoji") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showEmoji = true }
            }
        }
    }

    static let colors: [(String, NSColor)] = [
        ("Copper", NSColor(srgbRed: 0.60, green: 0.29, blue: 0.09, alpha: 1)),
        ("Red", .systemRed), ("Orange", .systemOrange), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple), ("Gray", .systemGray),
    ]

    private var divider: some View { Divider().frame(height: 16).padding(.horizontal, 4) }

    private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Address input with autocomplete from Fastmail contacts and people you've corresponded with.
struct AddressField: View {
    @Binding var text: String
    let suggestions: [EmailAddress]
    var invalid = false
    var label = "To"
    @State private var showSuggestions = false

    private var currentToken: String {
        RecipientParser.split(text).last.map { text.hasSuffix(",") || text.hasSuffix(";") ? "" : $0 } ?? ""
    }

    private var matches: [EmailAddress] {
        let token = currentToken.lowercased()
        guard token.count >= 2 else { return [] }
        return Array(suggestions.filter {
            $0.email.lowercased().contains(token) || ($0.name?.lowercased().contains(token) ?? false)
        }.prefix(6))
    }

    var body: some View {
        // Inline list instead of a popover so typing focus never leaves the field.
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: $text)
                .textFieldStyle(.plain)
                .labelsHidden()
                .foregroundStyle(invalid ? Color.red : Color.primary)
                .onChange(of: text) { _, _ in showSuggestions = !matches.isEmpty }
                .accessibilityLabel(label)
            if showSuggestions {
                ForEach(matches, id: \.email) { address in
                    Button {
                        complete(with: address)
                    } label: {
                        HStack {
                            Text(address.displayName)
                            if address.name != nil {
                                Text(address.email).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .font(.callout)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func complete(with address: EmailAddress) {
        var parts = RecipientParser.split(text)
        if !(text.hasSuffix(",") || text.hasSuffix(";")), !parts.isEmpty { parts.removeLast() }
        parts.append(address.fieldText)
        text = parts.joined(separator: ", ") + ", "
        showSuggestions = false
    }
}

/// Gives a SwiftUI view access to its NSWindow.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = AccessorView()
        v.onWindow = configure
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Lets a window ask before closing while forwarding everything else to SwiftUI's own delegate.
final class WindowCloseProxy: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let shouldClose: (NSWindow) -> Bool
    private static var installed: [ObjectIdentifier: WindowCloseProxy] = [:]

    private init(original: NSWindowDelegate?, shouldClose: @escaping (NSWindow) -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    static func install(on window: NSWindow, shouldClose: @escaping (NSWindow) -> Bool) {
        let proxy = WindowCloseProxy(original: window.delegate, shouldClose: shouldClose)
        installed[ObjectIdentifier(window)] = proxy   // the window holds its delegate weakly
        window.delegate = proxy
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        original?.windowWillClose?(notification)
        if let window = notification.object as? NSWindow { Self.installed[ObjectIdentifier(window)] = nil }
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        original?.responds(to: aSelector) == true ? original : super.forwardingTarget(for: aSelector)
    }
}
