import Foundation
import Observation

/// Everything a draft contains, compared exactly to decide whether it needs saving.
public struct DraftSnapshot: Codable, Equatable, Sendable {
    public var identityId: String?
    public var to: String
    public var cc: String
    public var bcc: String
    public var subject: String
    public var body: String
    public var htmlBody: String?
    /// Attachments, including ones carried over from a forwarded message.
    public var attachments: [OutgoingAttachment]
    public var inReplyTo: String?
    public var references: [String]
    public var replyingToEmailId: String?
    public var isForward: Bool

    public init(identityId: String?, to: String, cc: String, bcc: String, subject: String, body: String,
                htmlBody: String?, attachments: [OutgoingAttachment], inReplyTo: String?, references: [String],
                replyingToEmailId: String?, isForward: Bool) {
        self.identityId = identityId; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.body = body; self.htmlBody = htmlBody; self.attachments = attachments
        self.inReplyTo = inReplyTo; self.references = references
        self.replyingToEmailId = replyingToEmailId; self.isForward = isForward
    }

    public var isBlank: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty && attachments.isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Where drafts are stored (Fastmail in the app, a fake in tests).
public protocol DraftServer: Sendable {
    func create(_ snapshot: DraftSnapshot) async throws -> String
    func destroy(_ id: String) async throws
}

/// Saves one compose window's draft.
///
/// - Manual saves and autosaves are serialized: at most one request at a time.
/// - A save records exactly the snapshot it sent; edits made during a save stay dirty.
/// - A replacement draft is created before the previous one is removed, so the server
///   always holds a recoverable copy.
/// - Once the draft is sent or discarded (`retire`), a save that finishes late removes
///   the copy it just made instead of bringing the draft back.
@MainActor
@Observable
public final class DraftSaveCoordinator {
    public private(set) var savedSnapshot: DraftSnapshot?
    public private(set) var serverDraftId: String?
    public private(set) var isSaving = false
    public private(set) var lastError: String?
    public private(set) var isRetired = false
    /// Earlier copies whose removal failed; retried on the next successful save.
    public private(set) var staleCopies: [String] = []

    @ObservationIgnored private let server: DraftServer
    @ObservationIgnored private var inFlight: Task<Bool, Never>?

    public init(server: DraftServer, existingDraftId: String? = nil, existingSnapshot: DraftSnapshot? = nil) {
        self.server = server
        self.serverDraftId = existingDraftId
        self.savedSnapshot = existingSnapshot
    }

    public func isDirty(_ current: DraftSnapshot) -> Bool {
        current != savedSnapshot && !(savedSnapshot == nil && current.isBlank)
    }

    /// Saves `snapshot`. Returns true when exactly this snapshot is now saved on the server.
    @discardableResult
    public func save(_ snapshot: DraftSnapshot) async -> Bool {
        guard !isRetired else { return false }
        // Wait for the save ahead of this one. Awaiting a finished task returns without
        // suspending, so clear its slot here rather than spinning until its caller does.
        while let running = inFlight {
            _ = await running.value
            if inFlight == running { inFlight = nil }
        }
        guard !isRetired else { return false }
        if snapshot == savedSnapshot { return true }

        let task = Task { await self.perform(snapshot) }
        inFlight = task
        let ok = await task.value
        // A save queued behind this one may already have taken the slot.
        if inFlight == task { inFlight = nil }
        return ok
    }

    private func perform(_ snapshot: DraftSnapshot) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            let newId = try await server.create(snapshot)
            if isRetired {
                // Sent or discarded while this save was running: don't resurrect the draft.
                try? await server.destroy(newId)
                return false
            }
            let previous = serverDraftId
            serverDraftId = newId
            savedSnapshot = snapshot
            lastError = nil
            var leftovers = staleCopies
            staleCopies = []
            if let previous { leftovers.append(previous) }
            for id in leftovers {
                do { try await server.destroy(id) } catch { staleCopies.append(id) }
            }
            return true
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// Call when the draft is sent or discarded. Waits for any save in progress and returns
    /// the server draft id the caller now owns (to remove after sending, or right away on discard).
    public func retire() async -> (draftId: String?, staleCopies: [String]) {
        isRetired = true
        if let running = inFlight { _ = await running.value }
        return (serverDraftId, staleCopies)
    }

    /// Retires without waiting (window closing). A save still running cleans up after itself.
    public func retireNow() -> (draftId: String?, staleCopies: [String]) {
        isRetired = true
        return (serverDraftId, staleCopies)
    }
}
