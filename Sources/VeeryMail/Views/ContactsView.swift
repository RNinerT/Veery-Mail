import SwiftUI
import VeeryMailCore

struct ContactDraft: Identifiable {
    let id = UUID()
    var name = ""
    var email = ""
    var contact: SavedContact?
}

private enum ContactSort: String, CaseIterable {
    case ascending = "Name A–Z", descending = "Name Z–A", company = "Company"

    func precedes(_ left: SavedContact, _ right: SavedContact) -> Bool {
        if self == .company {
            switch (left.organizations.first, right.organizations.first) {
            case (let lhs?, let rhs?):
                let comparison = lhs.localizedStandardCompare(rhs)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
        }
        let comparison = left.name.localizedStandardCompare(right.name)
        if comparison == .orderedSame { return left.id < right.id }
        return comparison == (self == .descending ? .orderedDescending : .orderedAscending)
    }
}

private enum ContactFilter: String, CaseIterable {
    case all = "Any Contact", email = "Has Email", phone = "Has Phone", company = "Has Company"

    func matches(_ card: SavedContact) -> Bool {
        switch self {
        case .all: return true
        case .email: return !card.emails.isEmpty
        case .phone: return !card.phones.isEmpty
        case .company: return !card.organizations.isEmpty
        }
    }
}

struct ContactsView: View {
    @Environment(MailStore.self) private var store
    @State private var cards: [SavedContact] = []
    @State private var books: [ContactAddressBook] = []
    @State private var search = ""
    @State private var bookID = ""
    @State private var filter = ContactFilter.all
    @State private var sort = ContactSort.ascending
    @State private var selected: String?
    @State private var loading = true
    @State private var error: String?

    private var results: [SavedContact] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return cards.filter { card in
            guard (bookID.isEmpty || card.addressBookIDs.contains(bookID)), filter.matches(card) else { return false }
            let values = [card.name] + card.organizations + card.emails.map(\.email) + card.phones
            return query.isEmpty || values.contains { $0.localizedStandardContains(query) }
        }.sorted(by: sort.precedes)
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
                TextField("Search name, email, phone, company", text: $search)
                    .accessibilityLabel("Search contacts")
                HStack {
                    Menu {
                        Picker("Sort by", selection: $sort) {
                            ForEach(ContactSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                    Menu {
                        Picker("Address Book", selection: $bookID) {
                            Text("All Address Books").tag("")
                            ForEach(books) { Text($0.name).tag($0.id) }
                        }
                        Picker("Contact Details", selection: $filter) {
                            ForEach(ContactFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label(bookID.isEmpty && filter == .all ? "Filter" : "Filtered",
                              systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Spacer(minLength: 0)
                    Text("\(results.count)").monospacedDigit()
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                        .accessibilityLabel("\(results.count) contacts")
                }
                if let error, !cards.isEmpty {
                    Text(error).font(.caption).foregroundStyle(Theme.secondaryText)
                }
                if loading && cards.isEmpty {
                    ProgressView("Loading contacts…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error, cards.isEmpty {
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
                ContactProfile(contact: contact,
                               books: books.filter { contact.addressBookIDs.contains($0.id) }) {
                    store.newContact = ContactDraft(contact: contact)
                }
            } else {
                ContentUnavailableView("Select a Contact", systemImage: "person.crop.circle")
                    .foregroundStyle(WorkspacePaper.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(WorkspacePaper.surface)
            }
        }
        .task(id: store.accountKey) { await reload() }
        .onChange(of: results.map(\.id)) { _, ids in
            if !ids.contains(where: { $0 == selected }) { selected = ids.first }
        }
        .sheet(item: $store.newContact) { draft in
            ContactEditor(draft: draft, books: books.filter(\.canWrite), existing: cards) { contact in
                search = ""
                if !bookID.isEmpty && !contact.addressBookIDs.contains(bookID) { bookID = "" }
                if !filter.matches(contact) { filter = .all }
                if store.isDemo {
                    cards.removeAll { $0.id == contact.id }
                    cards.append(contact)
                    selected = contact.id
                } else {
                    await reload(preselect: contact.id)
                    store.loadContacts(store.generation)
                }
            }
        }
    }

    private var queryTitle: String { cards.isEmpty ? "No Saved Contacts" : "No Matching Contacts" }

    @MainActor private func reload(preselect: String? = nil) async {
        loading = true
        error = nil
        let generation = store.generation
        defer { if store.isLive(generation) { loading = false } }
        guard let client = store.client, client.contactsAccountId != nil else {
            if store.isDemo {
                books = [ContactAddressBook(id: "personal", name: "Personal", isDefault: true),
                         ContactAddressBook(id: "work", name: "Work")]
                guard cards.isEmpty else { return }
                cards = [
                    SavedContact(id: "imani", name: "Imani Okafor", emails: [.init(email: "imani@fernhill.example")],
                                 phones: ["(203) 555-0142"], organizations: ["Fernhill Studio"], addressBookIDs: ["work"]),
                    SavedContact(id: "priya", name: "Priya Raman", emails: [.init(email: "priya@example.org")], addressBookIDs: ["personal"]),
                    SavedContact(id: "jonas", name: "Jonas Lindqvist", emails: [.init(email: "jonas@example.net")], addressBookIDs: ["personal"])
                ]
                selected = cards.first?.id
            } else {
                cards = []
                error = "Sign in to Fastmail with contacts access to view your address book."
            }
            return
        }
        do {
            async let fetchedCards = client.contactDirectory()
            async let fetchedBooks = client.contactAddressBooks()
            let (contacts, addressBooks) = try await (fetchedCards, fetchedBooks)
            guard !Task.isCancelled, store.isLive(generation) else { return }
            books = addressBooks
            if !books.contains(where: { $0.id == bookID }) { bookID = "" }
            cards = contacts
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
    let books: [ContactAddressBook]
    let edit: () -> Void
    @State private var messages: [EmailSummary] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !books.isEmpty {
                            Text(books.map(\.name).joined(separator: " · "))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(WorkspacePaper.secondary)
                        }
                        Text(contact.name).font(.system(size: 38, weight: .regular, design: .serif))
                        ForEach(Array(contact.organizations.enumerated()), id: \.offset) { _, company in
                            Text(company).foregroundStyle(WorkspacePaper.secondary)
                        }
                    }
                    Spacer(minLength: 10)
                    Button("Edit", systemImage: "pencil", action: edit)
                        .disabled(!store.isDemo && !books.contains(where: \.canWrite))
                }
                if let address = contact.emails.first {
                    HStack {
                        Button("Compose", systemImage: "square.and.pencil") { store.compose(to: address) }
                            .buttonStyle(.borderedProminent)
                            .tint(WorkspacePaper.accent)
                        Button("Find Correspondence") { store.findCorrespondence(contact.emails) }
                    }
                }
                if !contact.emails.isEmpty {
                    LabeledContent("Email") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(contact.emails, id: \.email) { email in
                                Text(email.email)
                                    .textSelection(.enabled)
                                    .contextMenu {
                                        Button("Compose to This Address") { store.compose(to: email) }
                                    }
                            }
                        }
                    }
                }
                if !contact.phones.isEmpty {
                    LabeledContent("Phone") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(contact.phones.enumerated()), id: \.offset) { _, phone in
                                Text(phone).textSelection(.enabled)
                            }
                        }
                    }
                }
                if !contact.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Notes").font(.headline)
                        ForEach(Array(contact.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).textSelection(.enabled)
                        }
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
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(32)
        }
        .foregroundStyle(WorkspacePaper.ink)
        .background(WorkspacePaper.surface)
        .environment(\.colorScheme, .light)
        .task(id: contact.emails.map(\.email)) {
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
    let draft: ContactDraft
    let books: [ContactAddressBook]
    let existing: [SavedContact]
    let didSave: (SavedContact) async -> Void
    @State private var original: ContactEdit?
    @State private var values = ContactEdit()
    @State private var addressBookID = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.contact == nil ? "Add Contact" : "Edit Contact").font(.title2)
            if original != nil {
                Form {
                    Section("Name") {
                        TextField("Display name", text: $values.name)
                        if draft.contact == nil, !books.isEmpty {
                            Picker("Address Book", selection: $addressBookID) {
                                ForEach(books) { Text($0.name).tag($0.id) }
                            }
                        }
                    }
                    entries("Email", fields: $values.emails)
                    entries("Phone", fields: $values.phones)
                    entries("Company", fields: $values.organizations)
                    entries("Note", fields: $values.notes, multiline: true)
                }.formStyle(.grouped)
            } else if error == nil {
                ProgressView("Loading contact…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
                Button("Save Contact") { Task { await saveContact() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || original == nil)
            }
        }
        .padding(24)
        .frame(width: 500, height: 510)
        .interactiveDismissDisabled(saving)
        .task { await load() }
    }

    private func entries(_ label: String, fields: Binding<[ContactEdit.Entry]>, multiline: Bool = false) -> some View {
        Section(label) {
            ForEach(fields) { $entry in
                HStack {
                    TextField(label, text: $entry.value, axis: multiline ? .vertical : .horizontal)
                    Button {
                        fields.wrappedValue.removeAll { $0.id == entry.id }
                    } label: { Label("Remove \(label)", systemImage: "minus.circle") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            }
            Button("Add \(label)", systemImage: "plus") { fields.wrappedValue.append(.init()) }
                .buttonStyle(.borderless)
        }
    }

    private func load() async {
        addressBookID = books.first(where: \.isDefault)?.id ?? books.first?.id ?? ""
        do {
            if let contact = draft.contact {
                if store.isDemo {
                    values = ContactEdit(name: contact.name)
                    values.emails = contact.emails.map { .init(value: $0.email) }
                    values.phones = contact.phones.map { .init(value: $0) }
                    values.organizations = contact.organizations.map { .init(value: $0) }
                    values.notes = contact.notes.map { .init(value: $0) }
                } else {
                    guard let client = store.client else { throw JMAPError.notConnected }
                    let loaded = try await client.contactForEditing(contact.id)
                    guard !Task.isCancelled else { return }
                    values = loaded
                }
                original = values
            } else {
                values = ContactEdit(name: draft.name, email: draft.email)
                original = ContactEdit()
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func saveContact() async {
        guard let original, !saving else { return }
        func cleaned(_ entries: [ContactEdit.Entry], original: [ContactEdit.Entry]) -> [ContactEdit.Entry] {
            let old = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0.value) })
            return entries.compactMap {
                if old[$0.id] == $0.value { return $0 }
                let text = $0.value.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : .init(id: $0.id, value: text)
            }
        }
        var edited = values
        if edited.name != original.name { edited.name = edited.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        edited.emails = cleaned(values.emails, original: original.emails)
        edited.phones = cleaned(values.phones, original: original.phones)
        edited.organizations = cleaned(values.organizations, original: original.organizations)
        edited.notes = cleaned(values.notes, original: original.notes)
        let originalEmails = Dictionary(uniqueKeysWithValues: original.emails.map { ($0.id, $0.value) })
        guard edited.emails.allSatisfy({ entry in
            originalEmails[entry.id] == entry.value || EmailAddress.parseList(entry.value).first?.email == entry.value
        }) else {
            error = "Enter one valid email address per row."
            return
        }
        guard !edited.name.isEmpty || !edited.emails.isEmpty || !edited.phones.isEmpty || !edited.organizations.isEmpty else {
            error = "Enter a name, email, phone number, or company."
            return
        }
        if draft.contact == nil {
            let addresses = Set(edited.emails.map { $0.value.lowercased() })
            if let match = existing.first(where: { card in
                card.emails.contains { addresses.contains($0.email.lowercased()) }
            }) {
                error = "An email on this card is already saved for \(match.name)."
                return
            }
        }
        saving = true
        error = nil
        let generation = store.generation
        defer { saving = false }
        do {
            let id: String
            if store.isDemo { id = draft.contact?.id ?? UUID().uuidString }
            else {
                guard let client = store.client else { throw JMAPError.notConnected }
                if let contact = draft.contact {
                    try await client.updateContact(original, with: edited)
                    id = contact.id
                } else {
                    id = try await client.createContact(edited, addressBookID: addressBookID.isEmpty ? nil : addressBookID)
                }
            }
            guard store.isLive(generation) else { return }
            let emails = edited.emails.map { EmailAddress(name: edited.name.isEmpty ? nil : edited.name, email: $0.value) }
            let companies = edited.organizations.map(\.value)
            let name = edited.name.isEmpty ? companies.first ?? emails.first?.email ?? "Unnamed Contact" : edited.name
            let saved = SavedContact(id: id, name: name, emails: emails, phones: edited.phones.map(\.value),
                                     organizations: companies, addressBookIDs: draft.contact?.addressBookIDs ?? [addressBookID],
                                     notes: edited.notes.map(\.value))
            await didSave(saved)
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
