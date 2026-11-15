import AppKit
import SwiftUI
import VeeryMailCore

// MARK: - Signatures

/// One signature per sending identity, plus a default, and where to use them.
struct SignatureSettings: View {
    @Environment(MailStore.self) private var store
    @AppStorage("signature.new") private var onNew = true
    @AppStorage("signature.replies") private var onReplies = true
    @AppStorage("signature.delimiter") private var delimiter = true
    @State private var selected = "default"
    @State private var text = ""

    private var key: String { "signature.\(selected)" }

    var body: some View {
        Form {
            Section("Signature for") {
                Picker("Identity", selection: $selected) {
                    Text("All addresses (default)").tag("default")
                    ForEach(store.identities) { Text($0.address.formatted).tag($0.id) }
                }
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 140)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
                    .accessibilityLabel("Signature text")
                if selected != "default" {
                    Text("Leave empty to use the default signature for this address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Use signature") {
                Toggle("In new messages", isOn: $onNew)
                Toggle("In replies and forwards", isOn: $onReplies)
                Toggle("Start with the standard “-- ” separator line", isOn: $delimiter)
                Text("In replies the signature goes above the quoted message. Changing the From address in a compose window swaps the signature.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onAppear { text = UserDefaults.standard.string(forKey: key) ?? "" }
        .onChange(of: selected) { _, _ in text = UserDefaults.standard.string(forKey: key) ?? "" }
        .onChange(of: text) { _, value in UserDefaults.standard.set(value, forKey: key) }
    }
}

// MARK: - AI

/// Optional AI drafting with the user's own key. Off by default.
struct AISettings: View {
    @Environment(MailStore.self) private var store
    @AppStorage("ai.enabled") private var enabled = false
    @AppStorage("ai.provider") private var providerRaw = AIProviderKind.anthropic.rawValue
    @AppStorage("ai.localURL") private var localURL = "http://localhost:11434/v1"
    @AppStorage("ai.cap") private var cap = 10.0
    @AppStorage("ai.exclude.senders") private var excludedSenders = ""
    @AppStorage("ai.exclude.mailboxes") private var excludedMailboxes = ""
    @State private var key = ""
    @State private var models: [String] = []
    @State private var model = ""
    @State private var status: String?
    @State private var testing = false
    @State private var priceIn = 0.0
    @State private var priceOut = 0.0

    private var provider: AIProviderKind { AIProviderKind(rawValue: providerRaw) ?? .anthropic }
    private var ai: AIService { store.ai }

    var body: some View {
        Form {
            Section {
                Toggle("Turn on AI features", isOn: $enabled)
                Text("Summaries, reply drafts and rewrites, only when you click them. Messages are sent to the provider you choose below, using your own key, and nowhere else. Each action asks once before its first use.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(AIProviderKind.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                if provider == .local {
                    TextField("Server address", text: $localURL)
                    Text("Any OpenAI-compatible server on your Mac or network, such as Ollama or LM Studio. Nothing leaves your network.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    SecureField(ai.key(for: provider) == nil ? "API key" : "API key (saved — enter a new one to replace)", text: $key)
                    HStack {
                        Button("Save Key") { saveKey() }.disabled(key.isEmpty)
                        if ai.key(for: provider) != nil {
                            Button("Remove Key", role: .destructive) { try? ai.saveKey("", for: provider); status = "Key removed." }
                        }
                    }
                    setupSteps
                }
                HStack {
                    Button(testing ? "Testing…" : "Test Connection") { test() }.disabled(testing)
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                Picker("Model", selection: $model) {
                    if let def = provider.defaultModel { Text("\(def) (recommended)").tag("") }
                    else { Text("Choose…").tag("") }
                    ForEach(models.filter { $0 != provider.defaultModel }, id: \.self) { Text($0).tag($0) }
                    if !model.isEmpty && !models.contains(model) { Text(model).tag(model) }
                }
                .onChange(of: model) { _, v in UserDefaults.standard.set(v, forKey: "ai.model.\(provider.rawValue)") }
            }
            Section("Spending") {
                LabeledContent("Spent this month", value: String(format: "$%.2f", ai.ledger.spent(in: Date())))
                Picker("Monthly limit", selection: $cap) {
                    Text("$2").tag(2.0); Text("$5").tag(5.0); Text("$10").tag(10.0)
                    Text("$25").tag(25.0); Text("$50").tag(50.0)
                }
                if AIPrice.known(ai.model) == nil && provider != .local {
                    TextField("Price per million input tokens (USD)", value: $priceIn, format: .number)
                    TextField("Price per million output tokens (USD)", value: $priceOut, format: .number)
                    Text("Enter your model’s prices from the provider’s pricing page so the limit can be enforced.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Costs are estimated from the token counts the provider reports. Your provider bills you directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never send") {
                TextField("Senders or domains (comma-separated)", text: $excludedSenders)
                ForEach(store.mailboxTree, id: \.mailbox.id) { item in
                    Toggle(item.mailbox.name, isOn: mailboxBinding(item.mailbox.id))
                }
                Button("Ask Again Before Each Action’s Next Use") { ai.resetConsents() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 640)
        .onAppear(perform: load)
        .onChange(of: providerRaw) { _, _ in load() }
        .onChange(of: priceIn) { _, v in UserDefaults.standard.set(v, forKey: "ai.price.input.\(provider.rawValue)") }
        .onChange(of: priceOut) { _, v in UserDefaults.standard.set(v, forKey: "ai.price.output.\(provider.rawValue)") }
    }

    @ViewBuilder private var setupSteps: some View {
        switch provider {
        case .anthropic:
            Text("Create a key at console.anthropic.com → API Keys. Add billing credit there; usage is billed to your Anthropic account.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Open the Anthropic Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(.caption)
        case .openAI:
            Text("Create a key at platform.openai.com → API keys. Usage is billed to your OpenAI account.")
                .font(.caption).foregroundStyle(.secondary)
            Link("Open the OpenAI dashboard", destination: URL(string: "https://platform.openai.com/api-keys")!).font(.caption)
        case .local:
            EmptyView()
        }
    }

    private func load() {
        key = ""
        status = nil
        models = []
        model = UserDefaults.standard.string(forKey: "ai.model.\(provider.rawValue)") ?? ""
        priceIn = UserDefaults.standard.double(forKey: "ai.price.input.\(provider.rawValue)")
        priceOut = UserDefaults.standard.double(forKey: "ai.price.output.\(provider.rawValue)")
    }

    private func saveKey() {
        do {
            try ai.saveKey(key, for: provider)
            key = ""
            status = "Key saved in your Keychain."
        } catch {
            status = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        status = nil
        Task {
            defer { testing = false }
            do {
                models = try await ai.availableModels(kind: provider).sorted()
                status = "Connected. \(models.count) models available."
            } catch {
                status = error.localizedDescription
            }
        }
    }

    private func mailboxBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { excludedMailboxes.split(separator: ",").map(String.init).contains(id) },
            set: { on in
                var set = Set(excludedMailboxes.split(separator: ",").map(String.init))
                if on { set.insert(id) } else { set.remove(id) }
                excludedMailboxes = set.sorted().joined(separator: ",")
            })
    }
}
