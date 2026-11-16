import Foundation
import Observation
import VeeryMailCore

/// The AI actions the app offers. Each has its own first-use confirmation.
enum AIAction: String, CaseIterable, Identifiable {
    case summarize, draftReply, compose, rewrite
    var id: String { rawValue }
    var title: String {
        switch self {
        case .summarize: return "Summarize conversation"
        case .draftReply: return "Draft a reply"
        case .compose: return "Write a message"
        case .rewrite: return "Rewrite text"
        }
    }
}

/// Shown the first time an action is used: exactly what will be sent, where, and roughly what it costs.
struct AIConsentRequest: Identifiable {
    let id = UUID()
    let action: AIAction
    let providerName: String
    let model: String
    let preview: String
    let estimatedCost: String
    let resume: (_ allowed: Bool, _ remember: Bool) -> Void
}

/// Optional AI drafting. Off until the user turns it on and adds a key; nothing is sent until
/// an AI action is clicked. Prompts, responses and keys are never logged.
@MainActor
@Observable
final class AIService {
    var consent: AIConsentRequest?
    var summaries: [String: String] = [:]
    var summarizing: Set<String> = []
    var lastError: String?

    private var demo: Bool { MailStore.current?.isDemo ?? false }
    private var defaults: UserDefaults { .standard }

    // MARK: Settings (stored in preferences; keys in the Keychain)

    var isEnabled: Bool { defaults.bool(forKey: "ai.enabled") }
    var provider: AIProviderKind { AIProviderKind(rawValue: defaults.string(forKey: "ai.provider") ?? "") ?? .anthropic }
    var model: String {
        let stored = defaults.string(forKey: "ai.model.\(provider.rawValue)") ?? ""
        return stored.isEmpty ? (provider.defaultModel ?? "") : stored
    }
    var baseURL: URL {
        guard provider == .local, let s = defaults.string(forKey: "ai.localURL"), let url = URL(string: s) else {
            return provider.defaultBaseURL
        }
        return url
    }
    var monthlyCap: Double { defaults.object(forKey: "ai.cap") as? Double ?? 10 }
    var exclusions: AIExclusions {
        let boxes = Set((defaults.string(forKey: "ai.exclude.mailboxes") ?? "").split(separator: ",").map(String.init))
        let senders = Set((defaults.string(forKey: "ai.exclude.senders") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        return AIExclusions(mailboxIds: boxes, senders: senders)
    }

    var price: AIPrice? {
        if let known = AIPrice.known(model) { return known }
        let input = defaults.double(forKey: "ai.price.input.\(provider.rawValue)")
        let output = defaults.double(forKey: "ai.price.output.\(provider.rawValue)")
        return input > 0 || output > 0 ? AIPrice(input: input, output: output) : (provider == .local ? AIPrice(input: 0, output: 0) : nil)
    }

    static func keyAccount(_ kind: AIProviderKind) -> String { "ai.key.\(kind.rawValue)" }

    func key(for kind: AIProviderKind) -> String? {
        Keychain.data(account: Self.keyAccount(kind)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveKey(_ key: String, for kind: AIProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { Keychain.delete(account: Self.keyAccount(kind)) }
        else { try Keychain.save(data: Data(trimmed.utf8), account: Self.keyAccount(kind)) }
    }

    var ledger: AISpendLedger {
        get { defaults.data(forKey: "ai.ledger").flatMap { try? JSONDecoder().decode(AISpendLedger.self, from: $0) } ?? AISpendLedger() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "ai.ledger") }
    }

    func setEnabled(_ on: Bool) { defaults.set(on, forKey: "ai.enabled") }

    func resetConsents() {
        for action in AIAction.allCases { defaults.removeObject(forKey: "ai.consent.\(action.rawValue)") }
    }

    func clearAccountState() {
        summaries = [:]
        summarizing = []
        consent = nil
    }

    // MARK: Providers

    func makeProvider(kind: AIProviderKind? = nil, model: String? = nil) throws -> AIProvider {
        if demo { return DemoAIProvider() }
        let kind = kind ?? provider
        let model = model ?? self.model
        switch kind {
        case .anthropic:
            guard let key = key(for: .anthropic) else { throw AIError.missingKey }
            return AnthropicProvider(apiKey: key, model: model.isEmpty ? "claude-opus-5-5" : model)
        case .openAI:
            guard let key = key(for: .openAI) else { throw AIError.missingKey }
            return OpenAICompatibleProvider(apiKey: key, model: model, baseURL: AIProviderKind.openAI.defaultBaseURL)
        case .local:
            return OpenAICompatibleProvider(apiKey: nil, model: model, baseURL: baseURL)
        }
    }

    /// Lists models for the chosen provider (also a connection test).
    func availableModels(kind: AIProviderKind) async throws -> [String] {
        try await makeProvider(kind: kind, model: "").listModels()
    }

    // MARK: Running

    /// Runs one prompt: checks it's allowed, asks on first use, enforces the monthly cap,
    /// streams text to `onText`, and records the cost from the provider's token counts.
    func run(_ action: AIAction, prompt: AIPrompt, onText: @escaping (String) -> Void) async throws {
        guard isEnabled || demo else { throw AIError.excluded("AI is turned off. Turn it on in Settings → AI.") }
        if model.isEmpty && provider != .anthropic && !demo {
            throw AIError.excluded("Choose a model in Settings → AI first.")
        }
        try ledger.checkCap(monthlyCap, at: Date())
        let provider = try makeProvider()

        if !demo, !defaults.bool(forKey: "ai.consent.\(action.rawValue)") {
            let allowed = await askConsent(action, prompt: prompt)
            guard allowed else { throw CancellationError() }
        }

        var usage = AIUsage()
        for try await event in provider.stream(system: prompt.system, user: prompt.user, maxTokens: prompt.maxTokens) {
            try Task.checkCancellation()
            switch event {
            case .text(let t): onText(t)
            case .usage(let u):
                usage.inputTokens += u.inputTokens
                usage.outputTokens += u.outputTokens
            case .refused(let why): throw AIError.excluded(why)
            }
        }
        if !demo, let price {
            var l = ledger
            l.record(price.cost(usage), at: Date())
            ledger = l
        }
    }

    private func askConsent(_ action: AIAction, prompt: AIPrompt) async -> Bool {
        await withCheckedContinuation { continuation in
            let cost: String
            if let price {
                let estimate = price.cost(AIUsage(inputTokens: prompt.estimatedInputTokens, outputTokens: prompt.maxTokens / 2))
                cost = estimate < 0.01 ? "under 1¢" : String(format: "about $%.2f", estimate)
            } else {
                cost = "unknown (add prices in Settings → AI)"
            }
            consent = AIConsentRequest(
                action: action, providerName: provider.label, model: model,
                preview: String((prompt.system + "\n\n" + prompt.user).prefix(4_000)),
                estimatedCost: cost,
                resume: { [weak self] allowed, remember in
                    if allowed && remember { self?.defaults.set(true, forKey: "ai.consent.\(action.rawValue)") }
                    self?.consent = nil
                    continuation.resume(returning: allowed)
                })
        }
    }

    // MARK: Actions

    func summarize(_ thread: [EmailDetail]) {
        guard let threadId = thread.first?.threadId, !summarizing.contains(threadId) else { return }
        lastError = nil
        do {
            let prompt = try AIPromptBuilder.summarize(thread, exclusions: exclusions)
            summarizing.insert(threadId)
            summaries[threadId] = ""
            Task {
                defer { summarizing.remove(threadId) }
                do {
                    try await run(.summarize, prompt: prompt) { [weak self] text in self?.summaries[threadId, default: ""] += text }
                } catch is CancellationError {
                    summaries[threadId] = nil
                } catch {
                    summaries[threadId] = nil
                    lastError = error.localizedDescription
                    MailStore.current?.report(error)
                }
            }
        } catch {
            lastError = error.localizedDescription
            MailStore.current?.report(error)
        }
    }
}
