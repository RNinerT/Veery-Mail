import SwiftUI
import VeeryMailCore

struct ContactDraft: Identifiable {
    let id = UUID()
    var name = ""
    var email = ""
}

struct ContactsView: View {
    @Environment(MailStore.self) private var store
    @State private var cards: [SavedContact] = []
    @State private var search = ""
    @State private var selected: String?
    @State private var loading = true
    @State private var error: String?

    private var results: [SavedContact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? cards : cards.filter { card in
            ([card.name] + card.organizations + card.emails.map(\.email))
                .contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        @Bindable var store = store
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Contacts").font(Theme.Typeface.mailboxTitle)
                    Spacer()
                    Button { store.newContact = ContactDraft() } label: {
                        Label("Add Contact", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .help("Add Contact")
                    .disabled(store.client?.contactsAccountId == nil && !store.isDemo)
                    Button { Task { await reload() } } label: {
                        Label("Refresh Contacts", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("Refresh Contacts")
                    .disabled(loading)
                }
                TextField("Search contacts", text: $search)
                if loading && cards.isEmpty {
                    ProgressView("Loading contacts…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Contacts Unavailable", systemImage: "person.crop.circle.badge.exclamationmark",
                                           description: Text(error))
                } else if results.isEmpty {
                    ContentUnavailableView(queryTitle, systemImage: "person.crop.circle")
                } else {
                    List(results, selection: $selected) { contact in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(contact.name).fontWeight(.medium)
                            if let subtitle = contact.organizations.first ?? contact.emails.first?.email {
                                Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryText).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(contact.id)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .padding(16)
            .frame(minWidth: 235, idealWidth: 285, maxWidth: 380)
            .background(Theme.canvas)

            if let contact = results.first(where: { $0.id == selected }) {
                ContactProfile(contact: contact)
            } else {
                ContentUnavailableView("Select a Contact", systemImage: "person.crop.circle")
                    .foregroundStyle(WorkspacePaper.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WorkspacePaper.surface)
            }
        }
        .task(id: store.accountKey) { await reload() }
        .onChange(of: search) { _, _ in
            if !results.contains(where: { $0.id == selected }) { selected = results.first?.id }
        }
        .sheet(item: $store.newContact) { draft in
            ContactEditor(draft: draft, existing: cards) { contact in
                search = ""
                if store.isDemo {
                    cards.append(contact)
                    selected = contact.id
                } else {
                    await reload(preselect: contact.id)
                    store.loadContacts(store.generation)
                }
            }
        }
    }

    private var queryTitle: String { search.isEmpty ? "No Saved Contacts" : "No Matching Contacts" }

    @MainActor private func reload(preselect: String? = nil) async {
        loading = true
        error = nil
        let generation = store.generation
        defer { if store.isLive(generation) { loading = false } }
        guard let client = store.client, client.contactsAccountId != nil else {
            if store.isDemo {
                cards = [
                    SavedContact(id: "imani", name: "Imani Okafor", emails: [.init(email: "imani@fernhill.example")],
                                 phones: ["(203) 555-0142"], organizations: ["Fernhill Studio"]),
                    SavedContact(id: "priya", name: "Priya Raman", emails: [.init(email: "priya@example.org")]),
                    SavedContact(id: "jonas", name: "Jonas Lindqvist", emails: [.init(email: "jonas@example.net")])
                ]
                selected = cards.first?.id
            } else {
                cards = []
                error = "Sign in to Fastmail with contacts access to view your address book."
            }
            return
        }
        do {
            let contacts = try await client.contactDirectory()
            guard !Task.isCancelled, store.isLive(generation) else { return }
            cards = contacts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let preferred = preselect ?? selected
            selected = results.first(where: { $0.id == preferred })?.id ?? results.first?.id
        } catch {
            if !Task.isCancelled, store.isLive(generation) { self.error = error.localizedDescription }
        }
    }
}

private struct ContactProfile: View {
    @Environment(MailStore.self) private var store
    let contact: SavedContact
    @State private var messages: [EmailSummary] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Text(contact.name).font(.system(size: 38, weight: .regular, design: .serif))
                ForEach(contact.organizations, id: \.self) { Text($0).foregroundStyle(WorkspacePaper.secondary) }
                if let address = contact.emails.first { Text(address.email).textSelection(.enabled) }
                HStack {
                    if let address = contact.emails.first {
                        Button("Compose", systemImage: "square.and.pencil") { store.compose(to: address) }
                            .buttonStyle(.borderedProminent)
                            .tint(WorkspacePaper.accent)
                        Button("Find Correspondence") { store.findCorrespondence(contact.emails) }
                    }
                }
                Divider().padding(.top, 12)
                Text("Recent Correspondence").font(.system(.title2, design: .serif))
                if loading {
                    ProgressView().controlSize(.small)
                } else if let failure {
                    Text(failure).foregroundStyle(WorkspacePaper.secondary)
                } else if messages.isEmpty {
                    Text("No recent conversations").foregroundStyle(WorkspacePaper.secondary)
                } else {
                    ForEach(messages) { message in
                        Button {
                            store.showLinkedMessage(message.id)
                        } label: {
                            HStack {
                                Text(message.subject ?? "(No subject)").lineLimit(2)
                                Spacer()
                                Text(message.receivedAt, format: .dateTime.month().day())
                                    .font(.caption).foregroundStyle(WorkspacePaper.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                if contact.emails.count > 1 || !contact.phones.isEmpty {
                    DisclosureGroup("Contact details") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(contact.emails, id: \.email) { email in
                                Button(email.email) { store.compose(to: email) }
                            }
                            ForEach(Array(Set(contact.phones)).sorted(), id: \.self) { Text($0).textSelection(.enabled) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
        .foregroundStyle(WorkspacePaper.ink)
        .background(WorkspacePaper.surface)
        .environment(\.colorScheme, .light)
        .task(id: contact.id) {
            loading = true
            messages = []
            failure = nil
            defer { if !Task.isCancelled { loading = false } }
            do {
                let matching = try await store.recentCorrespondence(contact.emails)
                if !Task.isCancelled { messages = matching }
            } catch {
                if !Task.isCancelled { failure = "Couldn’t load recent correspondence." }
            }
        }
    }
}

private struct ContactEditor: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var draft: ContactDraft
    let existing: [SavedContact]
    let didSave: (SavedContact) async -> Void
    @State private var saving = false
    @State private var error: String?

    private var address: EmailAddress? {
        let text = draft.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = EmailAddress.parseList(text).first, parsed.email == text else { return nil }
        return EmailAddress(name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), email: parsed.email)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Contact").font(.title2)
            TextField("Name", text: $draft.name)
            TextField("Email", text: $draft.email)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
                Button("Save Contact") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || address == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled(saving)
    }

    @MainActor private func save() async {
        guard let address, !saving else { return }
        if let match = existing.first(where: { contact in
            contact.emails.contains { $0.email.caseInsensitiveCompare(address.email) == .orderedSame }
        }) {
            error = "This email is already saved for \(match.name)."
            return
        }
        saving = true
        defer { saving = false }
        let generation = store.generation
        do {
            let id: String
            if store.isDemo { id = UUID().uuidString }
            else {
                guard let client = store.client else { throw JMAPError.notConnected }
                id = try await client.addContact(address)
            }
            guard store.isLive(generation) else { return }
            await didSave(SavedContact(id: id, name: address.displayName, emails: [address]))
            dismiss()
        } catch {
            if store.isLive(generation) { self.error = error.localizedDescription }
        }
    }
}

enum WorkspacePaper {
    static let surface = Color(red: 0.98, green: 0.96, blue: 0.92)
    static let ink = Color(red: 0.14, green: 0.20, blue: 0.25)
    static let secondary = Color(red: 0.33, green: 0.38, blue: 0.41)
    static let accent = Color(red: 0.57, green: 0.25, blue: 0.13)
}
