import Foundation
import Observation

/// One message on its way out. Persisted before every step so a quit, crash or dropped
/// connection never loses it or sends it twice.
public struct OutboxItem: Codable, Identifiable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        /// In its Undo Send window.
        case queued(until: Date)
        /// Waiting for the user: it was still in its Undo Send window when the app quit.
        case held
        /// Sent to Fastmail; no answer yet.
        case submitting(since: Date)
        /// The connection failed after sending started, so we don't know whether Fastmail
        /// accepted it. Checked against the server before any retry is allowed.
        case unknown(reason: String)
        /// Definitely not sent. The user's draft is untouched.
        case failed(reason: String)
        /// Accepted by Fastmail, but a follow-up step (removing the draft, marking the
        /// original answered, moving to Sent) failed. The message itself went out.
        case sentWithProblem(problem: String)
    }

    public let id: UUID
    public let accountKey: String
    public var message: OutgoingMessage
    public var identityId: String
    /// The user's saved draft. Removed only after Fastmail confirms the submission.
    public var serverDraftId: String?
    /// The copy created for sending, if the server created one.
    public var createdEmailId: String?
    public var sendAt: Date?
    public var state: State
    public let createdAt: Date
    /// The composer's full state, so undo or failure reopens exactly what was written.
    public var composerState: Data?

    public var isScheduled: Bool { sendAt != nil }

    public var isInUndoWindow: Bool {
        if case .queued = state { return true }
        return false
    }
}

public enum OutboxEvent: Sendable, Equatable {
    case sent(UUID, scheduled: Bool)
    case sentWithProblem(UUID, String)
    case failed(UUID, String)
    case needsDecision(UUID, String)
}

/// What the user chose for a message whose outcome couldn't be confirmed.
public enum UnknownSendDecision: Sendable {
    /// Send again even though it may arrive twice.
    case retryAnyway
    /// Treat it as sent and remove it from the outbox.
    case markAsSent
    /// Keep the draft and remove it from the outbox (returns the item for reopening).
    case keepAsDraft
}

/// The network side of sending, so the controller can be tested without Fastmail.
public protocol OutboxSending: Sendable {
    func submit(_ item: OutboxItem) async throws -> SubmitResponse
    func reconcile(_ item: OutboxItem) async throws -> SendReconciliation
    func complete(_ item: OutboxItem) async throws -> FollowUpResult
    /// Best effort: removes the extra copy created for a send that Fastmail then rejected.
    func discardCreatedCopy(_ emailId: String) async
}

public protocol OutboxStorage: Sendable {
    func load() -> [OutboxItem]
    func save(_ items: [OutboxItem]) throws
}

/// One JSON file, written atomically and synchronously so a crash right after a state
/// change still finds that change on disk.
public struct FileOutboxStorage: OutboxStorage {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> [OutboxItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([OutboxItem].self, from: data)) ?? []
    }

    public func save(_ items: [OutboxItem]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(items).write(to: url, options: [.atomic, .completeFileProtection])
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

/// Queues, sends and recovers outgoing mail.
///
/// - Every message has its own Undo Send window; starting a second send never shortens or
///   flushes the first.
/// - Creating the message, submitting it and the follow-up steps are separate outcomes.
/// - A timeout or dropped connection after sending starts is treated as "unknown" and is
///   checked against the server (by Message-ID) before a retry is allowed.
@MainActor
@Observable
public final class OutboxController {
    public private(set) var items: [OutboxItem] = []
    @ObservationIgnored public var onEvent: ((OutboxEvent) -> Void)?
    @ObservationIgnored public var sender: OutboxSending?

    @ObservationIgnored private let storage: OutboxStorage
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: (TimeInterval) async throws -> Void
    @ObservationIgnored private var timers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var inFlight: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored public private(set) var persistError: String?

    public init(storage: OutboxStorage,
                now: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000)) }) {
        self.storage = storage
        self.now = now
        self.sleep = sleep
    }

    // MARK: Lifecycle

    /// Loads persisted items after a launch. Messages that were in their Undo Send window are
    /// held for the user to decide; messages that were mid-send are reconciled with the server.
    public func load() {
        items = storage.load().map { item in
            var item = item
            switch item.state {
            case .queued: item.state = .held
            case .submitting: item.state = .unknown(reason: "Veery Mail closed while this message was being sent.")
            default: break
            }
            return item
        }
        persist()
    }

    /// Call once a connection is available: checks every message whose outcome is unknown.
    public func resume() {
        for item in items {
            if case .unknown = item.state { startReconcile(item.id) }
        }
    }

    // MARK: Queueing

    @discardableResult
    public func enqueue(_ message: OutgoingMessage, identityId: String, accountKey: String,
                        serverDraftId: String?, sendAt: Date?, undoWindow: TimeInterval,
                        composerState: Data?) -> UUID {
        let item = OutboxItem(id: UUID(), accountKey: accountKey, message: message, identityId: identityId,
                              serverDraftId: serverDraftId, createdEmailId: nil, sendAt: sendAt,
                              state: .queued(until: now().addingTimeInterval(max(0, undoWindow))),
                              createdAt: now(), composerState: composerState)
        items.append(item)
        persist()
        schedule(item.id, after: undoWindow)
        return item.id
    }

    private func schedule(_ id: UUID, after delay: TimeInterval) {
        timers[id]?.cancel()
        timers[id] = Task { [weak self] in
            do { try await self?.sleep(delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.timers[id] = nil
            if let item = self.item(id), case .queued = item.state { self.startSubmit(id) }
        }
    }

    /// Sends every queued message whose window has passed. Timers call this; tests can too.
    public func fireDue() {
        for item in items {
            if case .queued(let until) = item.state, until <= now() { startSubmit(item.id) }
        }
    }

    /// Undo Send (or "Edit" for a held or failed message). Returns the item so the composer can reopen it.
    public func takeBack(_ id: UUID) -> OutboxItem? {
        guard let item = item(id) else { return nil }
        switch item.state {
        case .queued, .held, .failed: break
        default: return nil
        }
        timers.removeValue(forKey: id)?.cancel()
        if let created = item.createdEmailId, let sender {
            Task { await sender.discardCreatedCopy(created) }
        }
        items.removeAll { $0.id == id }
        persist()
        return item
    }

    /// Sends a queued or held message now (also "Send Now" when quitting).
    public func sendNow(_ id: UUID) {
        guard let item = item(id) else { return }
        switch item.state {
        case .queued, .held: startSubmit(id)
        default: break
        }
    }

    /// Retries a message that definitely wasn't sent.
    public func retry(_ id: UUID) {
        guard let item = item(id), case .failed = item.state else { return }
        startSubmit(id)
    }

    /// The user's choice for a message whose outcome couldn't be confirmed.
    @discardableResult
    public func resolveUnknown(_ id: UUID, _ decision: UnknownSendDecision) -> OutboxItem? {
        guard let item = item(id), case .unknown = item.state else { return nil }
        switch decision {
        case .retryAnyway:
            startSubmit(id)
            return nil
        case .markAsSent:
            items.removeAll { $0.id == id }
            persist()
            return nil
        case .keepAsDraft:
            items.removeAll { $0.id == id }
            persist()
            return item
        }
    }

    /// Clears a sent message whose follow-up problem the user has seen.
    public func dismiss(_ id: UUID) {
        guard let item = item(id), case .sentWithProblem = item.state else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Checks again whether a message with an unknown outcome was sent.
    public func recheck(_ id: UUID) {
        guard let item = item(id), case .unknown = item.state else { return }
        startReconcile(id)
    }

    // MARK: Quitting

    public var queuedCount: Int { items.filter { if case .queued = $0.state { return true } else { return false } }.count }
    public var heldCount: Int { items.filter { $0.state == .held }.count }
    public var submittingCount: Int { items.filter { if case .submitting = $0.state { return true } else { return false } }.count }

    /// Waits for in-flight sends, up to `timeout` seconds. Returns true if none are left in flight.
    public func waitForInFlight(timeout: TimeInterval) async -> Bool {
        let deadline = now().addingTimeInterval(timeout)
        while submittingCount > 0, now() < deadline {
            try? await self.sleep(0.2)
        }
        return submittingCount == 0
    }

    /// Stops timers without sending: queued messages stay on disk and are held at next launch.
    public func suspendForQuit() {
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
        persist()
    }

    /// Stops all work without touching disk (used on sign-out after the user has decided).
    public func shutdown() {
        for (_, t) in timers { t.cancel() }
        timers.removeAll()
        inFlight.removeAll()
    }

    // MARK: Sending

    private func startSubmit(_ id: UUID) {
        guard inFlight[id] == nil else { return }
        timers.removeValue(forKey: id)?.cancel()
        inFlight[id] = Task { [weak self] in
            await self?.submit(id)
            self?.inFlight[id] = nil
        }
    }

    private func startReconcile(_ id: UUID) {
        guard inFlight[id] == nil else { return }
        inFlight[id] = Task { [weak self] in
            await self?.reconcile(id)
            self?.inFlight[id] = nil
        }
    }

    /// Lets tests and the quit handler wait for a message's current step to finish.
    public func settle(_ id: UUID) async {
        await inFlight[id]?.value
    }

    func submit(_ id: UUID) async {
        guard let sender else {
            update(id) { $0.state = .failed(reason: "Not connected to Fastmail.") }
            notifyFailed(id)
            return
        }
        update(id) { $0.state = .submitting(since: now()) }   // on disk before the request goes out
        guard let item = item(id) else { return }

        let response: SubmitResponse
        do {
            response = try await sender.submit(item)
        } catch {
            if error.requestCertainlyNotSent || error.isDefiniteRejection {
                update(id) { $0.state = .failed(reason: Self.describe(error)) }
                notifyFailed(id)
            } else {
                update(id) { $0.state = .unknown(reason: "The connection was interrupted while sending (\(Self.describe(error))).") }
                await reconcile(id)
            }
            return
        }

        if let created = response.emailId { update(id) { $0.createdEmailId = created } }
        if response.accepted {
            await finishAccepted(id, movedToSent: response.movedToSent)
        } else {
            // Definite rejection. The user's draft is untouched; remove the copy made for sending.
            let reason = response.submissionError ?? response.emailError ?? "Fastmail didn't accept the message."
            if let created = response.emailId {
                await sender.discardCreatedCopy(created)
                update(id) { $0.createdEmailId = nil }
            }
            update(id) { $0.state = .failed(reason: "Not sent: \(reason)") }
            notifyFailed(id)
        }
    }

    func reconcile(_ id: UUID) async {
        guard let sender, let item = item(id) else { return }
        do {
            let found = try await sender.reconcile(item)
            if found.wasSubmitted {
                if let created = found.emailIds.first { update(id) { $0.createdEmailId = created } }
                // The move to Sent ran in the same request as the submission. A pending or scheduled
                // submission may not show there yet, so absence isn't reported as a problem.
                await finishAccepted(id, movedToSent: found.inSent ? true : nil)
            } else {
                // Not submitted. A created copy (if any) is reused by a retry, so nothing is duplicated.
                update(id) {
                    $0.createdEmailId = found.emailIds.first
                    $0.state = .failed(reason: "Not sent. The connection dropped before Fastmail accepted it.")
                }
                notifyFailed(id)
            }
        } catch {
            let reason = "Couldn't confirm whether this message was sent (\(Self.describe(error))). It may already have been delivered."
            update(id) { $0.state = .unknown(reason: reason) }
            onEvent?(.needsDecision(id, reason))
        }
    }

    private func finishAccepted(_ id: UUID, movedToSent: Bool?) async {
        guard let sender, let item = item(id) else { return }
        var problems: [String] = []
        if movedToSent == false { problems.append("it wasn't moved to Sent") }
        do {
            let follow = try await sender.complete(item)
            if follow.draftRemoved == false { problems.append("the old draft couldn't be removed") }
            if follow.keywordSet == false {
                problems.append(item.message.isForward ? "the original wasn't marked as forwarded"
                                                       : "the original wasn't marked as answered")
            }
        } catch {
            problems.append("the follow-up update failed (\(Self.describe(error)))")
        }
        if problems.isEmpty {
            items.removeAll { $0.id == id }
            persist()
            onEvent?(.sent(id, scheduled: item.isScheduled))
        } else {
            let text = (item.isScheduled ? "Scheduled" : "Sent") + ", but " + problems.joined(separator: " and ") + "."
            update(id) { $0.state = .sentWithProblem(problem: text) }
            onEvent?(.sentWithProblem(id, text))
        }
    }

    // MARK: Helpers

    public func item(_ id: UUID) -> OutboxItem? { items.first { $0.id == id } }

    private func update(_ id: UUID, _ change: (inout OutboxItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        persist()
    }

    private func notifyFailed(_ id: UUID) {
        if let item = item(id), case .failed(let reason) = item.state { onEvent?(.failed(id, reason)) }
    }

    private func persist() {
        do {
            try storage.save(items)
            persistError = nil
        } catch {
            persistError = error.localizedDescription
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Sends through Fastmail with the account's Drafts and Sent mailboxes.
public struct JMAPOutboxSender: OutboxSending {
    public let client: JMAPClient
    public let draftsId: String
    public let sentId: String

    public init(client: JMAPClient, draftsId: String, sentId: String) {
        self.client = client; self.draftsId = draftsId; self.sentId = sentId
    }

    public func submit(_ item: OutboxItem) async throws -> SubmitResponse {
        try await client.createAndSubmit(item.message, identityId: item.identityId, draftsId: draftsId, sentId: sentId,
                                         sendAt: item.sendAt, existingEmailId: item.createdEmailId)
    }

    public func reconcile(_ item: OutboxItem) async throws -> SendReconciliation {
        guard let messageId = item.message.messageId else {
            throw JMAPError.unsupported("This message has no Message-ID to check.")
        }
        return try await client.findSent(messageId: messageId)
    }

    public func complete(_ item: OutboxItem) async throws -> FollowUpResult {
        let keyword = item.message.replyingToEmailId == nil ? nil : (item.message.isForward ? "$forwarded" : "$answered")
        return try await client.completeSend(oldDraftId: item.serverDraftId,
                                             originalEmailId: item.message.replyingToEmailId, keyword: keyword)
    }

    public func discardCreatedCopy(_ emailId: String) async {
        _ = try? await client.destroyEmails([emailId])
    }
}
