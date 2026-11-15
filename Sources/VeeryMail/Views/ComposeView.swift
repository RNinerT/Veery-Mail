import VeeryMailCore
import SwiftUI
import UniformTypeIdentifiers

struct ComposeView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: ComposeDraft
    @State private var importing = false
    @State private var uploading = 0
    @State private var showSchedule = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var lastSavedBody = ""
    @State private var confirmDiscard = false
    /// Autocomplete candidates, gathered once when the window opens (not on every keystroke).
    @State private var suggestions: [EmailAddress] = []
    @FocusState private var focus: Field?

    enum Field { case to, cc, bcc, subject, body }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            TextEditor(text: $draft.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .focused($focus, equals: .body)
                .dropDestination(for: URL.self) { urls, _ in
                    attach(urls)
                    return true
                }
            if !draft.allAttachments.isEmpty || uploading > 0 {
                Divider()
                attachmentList
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 480, idealHeight: 600)
        .background(Theme.canvas)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attach(urls) }
        }
        .onAppear {
            focus = draft.to.isEmpty ? .to : .body
            suggestions = store.knownAddresses
            lastSavedBody = draft.body
        }
        .task { await autosaveLoop() }
        .confirmationDialog("Save this message as a draft?", isPresented: $confirmDiscard) {
            Button("Save Draft") { Task { await saveDraft(); dismiss() } }
            Button("Discard", role: .destructive) { discard() }
            Button("Keep Editing", role: .cancel) {}
        }
        .sheet(isPresented: $showSchedule) { scheduleSheet }
    }

    // MARK: Header fields

    private var form: some View {
        VStack(spacing: 0) {
            row("From") {
                Picker("", selection: $draft.identityId) {
                    ForEach(store.identities) { identity in
                        Text(identity.address.formatted).tag(Optional(identity.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                Spacer()
            }
            row("To") {
                AddressField(text: $draft.to, suggestions: suggestions)
                    .focused($focus, equals: .to)
                Button(draft.showCc ? "Hide Cc" : "Cc/Bcc") { draft.showCc.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if draft.showCc {
                row("Cc") {
                    AddressField(text: $draft.cc, suggestions: suggestions).focused($focus, equals: .cc)
                }
                row("Bcc") {
                    AddressField(text: $draft.bcc, suggestions: suggestions).focused($focus, equals: .bcc)
                }
            }
            row("Subject") {
                TextField("", text: $draft.subject)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .subject)
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

    private var attachmentList: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(draft.allAttachments) { a in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip")
                        Text(a.name).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button {
                            draft.attachments.removeAll { $0.blobId == a.blobId }
                            draft.forwardedAttachments.removeAll { $0.blobId == a.blobId }
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
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

    private var footer: some View {
        HStack {
            Button { importing = true } label: { Label("Attach", systemImage: "paperclip") }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Save Draft") { Task { await saveDraft() } }
                .keyboardShortcut("s")
            Spacer()
            Button("Cancel") {
                if draft.isEmpty { discard() } else { confirmDiscard = true }
            }
            .keyboardShortcut(.cancelAction)
            if store.supportsScheduledSend {
                Menu("Send Later") {
                    ForEach(SnoozePresets.options().dropFirst(), id: \.name) { option in
                        Button("\(option.name) – \(option.date.formatted(date: .abbreviated, time: .shortened))") {
                            store.send(draft, sendAt: option.date)
                        }
                    }
                    Divider()
                    Button("Pick Date & Time…") { showSchedule = true }
                }
                .fixedSize()
                .disabled(uploading > 0)
            }
            Button("Send") { store.send(draft) }
                .keyboardShortcut(.return, modifiers: .command)
                .primaryButton()
                .disabled(uploading > 0 || draft.to.isEmpty && draft.cc.isEmpty && draft.bcc.isEmpty)
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
                    store.send(draft, sendAt: scheduleDate)
                }
                .primaryButton()
            }
        }
        .padding()
        .frame(width: 360)
    }

    // MARK: Actions

    private func attach(_ urls: [URL]) {
        guard let client = store.client else { return }
        for url in urls {
            uploading += 1
            Task {
                defer { uploading -= 1 }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    // Read off the main thread so a large file doesn't freeze the window.
                    let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
                    let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                    let result = try await client.upload(data, type: type)
                    draft.attachments.append(OutgoingAttachment(blobId: result.blobId, name: url.lastPathComponent,
                                                                type: type, size: result.size))
                } catch { store.report(error) }
            }
        }
    }

    private func saveDraft() async {
        if let id = await store.saveDraft(draft) {
            draft.savedDraftId = id
            lastSavedBody = draft.body
        }
    }

    /// Autosave every 20s while there are unsaved edits (like Apple Mail).
    private func autosaveLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !draft.isEmpty && draft.body != lastSavedBody { await saveDraft() }
        }
    }

    private func discard() {
        if let id = draft.savedDraftId {
            Task { try? await store.client?.destroyEmails([id]) }
        }
        store.composer = nil
        dismiss()
    }
}

/// Address input with lightweight autocomplete from people you've corresponded with.
struct AddressField: View {
    @Binding var text: String
    let suggestions: [EmailAddress]
    @State private var showSuggestions = false

    private var currentToken: String {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        return parts.last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
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
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .onChange(of: text) { _, _ in showSuggestions = !matches.isEmpty }
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
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if !parts.isEmpty { parts.removeLast() }
        parts.append(" " + address.formatted)
        text = parts.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ") + ", "
        showSuggestions = false
    }
}
