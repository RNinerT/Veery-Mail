import AppKit
import Foundation
import VeeryMailCore

extension MailStore {
    // MARK: Opening compose windows

    var defaultIdentity: Identity? {
        let preferred = defaults.string(forKey: "defaultIdentityId")
        return identities.first { $0.id == preferred } ?? identities.first
    }

    /// Opens `draft` in its own window.
    func present(_ draft: ComposeDraft) {
        composeDrafts[draft.id] = draft
        _ = draftSaver(for: draft.id)
        if let open = openComposeWindow {
            open(draft.id)
        } else {
            pendingComposeIds.append(draft.id)
        }
    }

    func compose(to address: EmailAddress? = nil) {
        var d = ComposeDraft(identityId: defaultIdentity?.id)
        d.to = address?.fieldText ?? ""
        if let block = Signatures.block(for: d.identityId, reply: false) {
            d.body = "\n\n" + block
            d.signatureBlock = block
        }
        present(d)
    }

    func reply(all: Bool, to email: EmailDetail? = nil) {
        guard let original = email ?? thread.last else { return }
        let me = Set(identities.map { $0.email.lowercased() })
        var to = original.replyTo ?? original.from ?? []
        var cc: [EmailAddress] = []
        if all {
            let others = ((original.to ?? []) + (original.cc ?? [])).filter { !me.contains($0.email.lowercased()) }
            if to.allSatisfy({ me.contains($0.email.lowercased()) }) { to = original.to ?? [] }
            cc = others.filter { o in !to.contains { $0.email.lowercased() == o.email.lowercased() } }
        }
        let identity = identities.first { id in
            ((original.to ?? []) + (original.cc ?? [])).contains { $0.email.lowercased() == id.email.lowercased() }
        } ?? defaultIdentity
        var d = ComposeDraft(identityId: identity?.id)
        d.to = to.map(\.fieldText).joined(separator: ", ")
        d.cc = cc.map(\.fieldText).joined(separator: ", ")
        d.showCc = !cc.isEmpty
        d.subject = Self.prefixed("Re:", original.subject)
        d.signatureBlock = Signatures.block(for: d.identityId, reply: true)
        d.body = "\n\n" + (d.signatureBlock.map { $0 + "\n\n" } ?? "") + Self.quote(original)
        d.inReplyTo = original.messageId?.first
        d.references = (original.references ?? []) + (original.messageId ?? [])
        d.replyingToEmailId = original.id
        d.threadId = original.threadId
        present(d)
    }

    func forward(_ email: EmailDetail? = nil) {
        guard let original = email ?? thread.last else { return }
        var d = ComposeDraft(identityId: defaultIdentity?.id)
        d.subject = Self.prefixed("Fwd:", original.subject)
        let header = """
        ---------- Forwarded message ----------
        From: \(original.from?.map(\.formatted).joined(separator: ", ") ?? "")
        Date: \(original.receivedAt.formatted(date: .abbreviated, time: .shortened))
        Subject: \(original.subject ?? "")
        To: \(original.to?.map(\.formatted).joined(separator: ", ") ?? "")
        """
        d.signatureBlock = Signatures.block(for: d.identityId, reply: true)
        d.body = "\n\n" + (d.signatureBlock.map { $0 + "\n\n" } ?? "") + "\(header)\n\n\(original.plainTextFallback)"
        d.replyingToEmailId = original.id
        d.threadId = original.threadId
        d.isForward = true
        d.forwardedAttachments = original.visibleAttachments.compactMap { part in
            guard let blob = part.blobId else { return nil }
            return OutgoingAttachment(blobId: blob, name: part.name ?? "attachment",
                                      type: part.type, size: part.size ?? 0)
        }
        present(d)
    }

    /// Handles mailto: links (Veery Mail can be set as the default mail app).
    func composeMailto(_ url: URL, defaultSubject: String = "") {
        guard url.scheme?.lowercased() == "mailto" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func item(_ name: String) -> String? {
            comps?.queryItems?.first { $0.name.lowercased() == name }?.value
        }
        var d = ComposeDraft(identityId: defaultIdentity?.id)
        d.to = [comps?.path, item("to")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        d.cc = item("cc") ?? ""
        d.bcc = item("bcc") ?? ""
        d.showCc = !d.cc.isEmpty || !d.bcc.isEmpty
        d.subject = item("subject") ?? defaultSubject
        d.body = item("body") ?? ""
        present(d)
    }

    /// Opens a saved draft in a compose window.
    func openDraft(_ row: EmailSummary) {
        guard row.isDraft, let client else { return }
        let gen = generation
        Task {
            guard let detail = try? await client.details(ids: [row.id]).first, isLive(gen) else { return }
            var d = ComposeDraft(identityId: identities.first {
                $0.email.lowercased() == detail.from?.first?.email.lowercased()
            }?.id ?? defaultIdentity?.id)
            d.to = detail.to?.map(\.fieldText).joined(separator: ", ") ?? ""
            d.cc = detail.cc?.map(\.fieldText).joined(separator: ", ") ?? ""
            d.bcc = detail.bcc?.map(\.fieldText).joined(separator: ", ") ?? ""
            d.showCc = !d.cc.isEmpty || !d.bcc.isEmpty
            d.subject = detail.subject ?? ""
            d.body = detail.plainTextFallback
            d.inReplyTo = detail.inReplyTo?.first
            d.references = detail.references ?? []
            d.savedDraftId = detail.id
            d.forwardedAttachments = detail.visibleAttachments.compactMap { p in
                p.blobId.map { OutgoingAttachment(blobId: $0, name: p.name ?? "attachment", type: p.type, size: p.size ?? 0) }
            }
            // The server copy is the saved state: only real edits make it dirty.
            draftSavers[d.id] = makeSaver(existingDraftId: detail.id, snapshot: d.snapshot)
            present(d)
        }
    }

    static func prefixed(_ prefix: String, _ subject: String?) -> String {
        let s = subject ?? ""
        return s.lowercased().hasPrefix(prefix.lowercased()) ? s : "\(prefix) \(s)"
    }

    static func quote(_ email: EmailDetail) -> String {
        let who = email.from?.first?.formatted ?? "someone"
        let when = email.receivedAt.formatted(date: .abbreviated, time: .shortened)
        let quoted = email.plainTextFallback
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        return "On \(when), \(who) wrote:\n\(quoted)"
    }

    // MARK: Drafts

    private func makeSaver(existingDraftId: String?, snapshot: DraftSnapshot?) -> DraftSaveCoordinator? {
        if isDemo { return DraftSaveCoordinator(server: DemoDraftServer(), existingDraftId: existingDraftId, existingSnapshot: snapshot) }
        guard let client, let drafts = mailbox(role: "drafts") else { return nil }
        let server = JMAPDraftServer(client: client, draftsId: drafts.id, identities: identities,
                                     fallbackAddress: EmailAddress(email: client.session?.username ?? ""))
        return DraftSaveCoordinator(server: server, existingDraftId: existingDraftId, existingSnapshot: snapshot)
    }

    func draftSaver(for id: UUID) -> DraftSaveCoordinator? {
        if let saver = draftSavers[id] { return saver }
        guard let draft = composeDrafts[id] else { return nil }
        let saver = makeSaver(existingDraftId: draft.savedDraftId,
                              snapshot: draft.savedDraftId == nil ? nil : draft.snapshot)
        draftSavers[id] = saver
        return saver
    }

    func isDirty(_ id: UUID) -> Bool {
        guard let draft = composeDrafts[id] else { return false }
        guard let saver = draftSaver(for: id) else { return !draft.isEmpty }
        return saver.isDirty(draft.snapshot)
    }

    /// Saves the window's current contents. True when they're safely on the server.
    @discardableResult
    func saveDraft(_ id: UUID) async -> Bool {
        guard let draft = composeDrafts[id] else { return true }
        guard let saver = draftSaver(for: id) else { return false }
        guard saver.isDirty(draft.snapshot) else { return true }
        let ok = await saver.save(draft.snapshot)
        if ok, let newId = saver.serverDraftId { composeDrafts[id]?.savedDraftId = newId }
        return ok && composeDrafts[id]?.snapshot == draft.snapshot
    }

    /// Discards the window's draft, including any copy already saved on the server.
    func discardDraft(_ id: UUID) {
        let saver = draftSavers[id]
        let fallbackId = composeDrafts[id]?.savedDraftId
        closeComposer(id)
        var ids: [String] = []
        if let saver {
            let retired = saver.retireNow()
            ids = [retired.draftId].compactMap { $0 } + retired.staleCopies
        } else if let fallbackId {
            ids = [fallbackId]
        }
        guard !ids.isEmpty, let client else { return }
        Task { _ = try? await client.destroyEmails(ids) }
    }

    func closeComposer(_ id: UUID) {
        composeDrafts[id] = nil
        draftSavers[id] = nil
        pendingComposeIds.removeAll { $0 == id }
    }

    // MARK: Sending

    /// Queues the window's message in the outbox and closes the window.
    /// Returns a message to show in the window if it can't be sent yet.
    func send(_ id: UUID, sendAt: Date? = nil) async -> String? {
        guard var draft = composeDrafts[id] else { return nil }
        if !draft.invalidRecipients.isEmpty { return "Fix the highlighted addresses before sending." }
        guard draft.hasRecipients else { return "Add at least one recipient." }
        guard let identity = identities.first(where: { $0.id == draft.identityId }) ?? defaultIdentity else {
            return "No sending address is available. Check your Fastmail identities."
        }
        let domain = identity.email.split(separator: "@").last.map(String.init) ?? ""
        let message = draft.outgoing(from: identity.address, messageId: OutgoingMessage.makeMessageId(senderDomain: domain))
        var serverDraftId = draft.savedDraftId
        var stale: [String] = []
        if let saver = draftSavers[id] {
            // Waits for a save in progress; a save finishing later removes its own copy.
            let retired = await saver.retire()
            serverDraftId = retired.draftId
            stale = retired.staleCopies
        }
        draft.savedDraftId = serverDraftId
        let state = try? JSONEncoder().encode(draft)
        closeComposer(id)
        let undo = defaults.object(forKey: "undoSendSeconds") as? Double ?? 10
        outbox.enqueue(message, identityId: identity.id, accountKey: accountKey ?? "",
                       serverDraftId: serverDraftId, sendAt: sendAt, undoWindow: undo, composerState: state)
        if !stale.isEmpty, let client { Task { _ = try? await client.destroyEmails(stale) } }
        return nil
    }

    /// Undo Send / Edit: takes a message back from the outbox and reopens it.
    func takeBack(_ itemId: UUID) {
        guard let item = outbox.takeBack(itemId) else { return }
        reopen(item)
    }

    func reopen(_ item: OutboxItem) {
        var draft = item.composerState.flatMap { try? JSONDecoder().decode(ComposeDraft.self, from: $0) }
            ?? Self.draft(from: item)
        draft.id = UUID()
        draft.savedDraftId = item.serverDraftId
        draftSavers[draft.id] = makeSaver(existingDraftId: item.serverDraftId,
                                          snapshot: item.serverDraftId == nil ? nil : draft.snapshot)
        present(draft)
    }

    private static func draft(from item: OutboxItem) -> ComposeDraft {
        let m = item.message
        var d = ComposeDraft(identityId: item.identityId)
        d.to = m.to.map(\.fieldText).joined(separator: ", ")
        d.cc = m.cc.map(\.fieldText).joined(separator: ", ")
        d.bcc = m.bcc.map(\.fieldText).joined(separator: ", ")
        d.showCc = !m.cc.isEmpty || !m.bcc.isEmpty
        d.subject = m.subject
        d.body = m.body
        d.htmlBody = m.htmlBody
        d.inReplyTo = m.inReplyTo
        d.references = m.references
        d.attachments = m.attachments
        d.replyingToEmailId = m.replyingToEmailId
        d.isForward = m.isForward
        return d
    }

    func handleOutboxEvent(_ event: OutboxEvent) {
        switch event {
        case .sent(_, let scheduled):
            showToast(scheduled ? "Message scheduled" : "Message sent", undo: nil)
        case .sentWithProblem(_, let text):
            showToast(text, undo: nil)
        case .failed(let id, let reason):
            present(Toast(message: reason, actionTitle: "Edit") { [weak self] in self?.takeBack(id) })
        case .needsDecision(_, let reason):
            showToast(reason, undo: nil)
        }
    }

    // MARK: Autocomplete

    /// Fastmail contacts first, then people you've corresponded with recently.
    var knownAddresses: [EmailAddress] {
        let mine = Set(identities.map { $0.email.lowercased() })
        var seen = Set<String>()
        var out: [EmailAddress] = []
        let fromThread = thread.flatMap { ($0.from ?? []) + ($0.to ?? []) + ($0.cc ?? []) }
        let saved = (defaults.object(forKey: "contacts.enabled") as? Bool ?? true) ? contacts : []
        for addr in saved + fromThread + messages.flatMap({ ($0.from ?? []) + ($0.to ?? []) }) {
            let key = addr.email.lowercased()
            if mine.contains(key) || key.contains("noreply") || key.contains("no-reply") { continue }
            if seen.insert(key).inserted { out.append(addr) }
        }
        return out
    }

    var supportsScheduledSend: Bool { isDemo || (client?.session?.maxDelayedSend ?? 0) > 0 }
}

/// Saves drafts to the account's Drafts mailbox.
struct JMAPDraftServer: DraftServer {
    let client: JMAPClient
    let draftsId: String
    let identities: [Identity]
    let fallbackAddress: EmailAddress

    func create(_ snapshot: DraftSnapshot) async throws -> String {
        let from = identities.first { $0.id == snapshot.identityId }?.address ?? identities.first?.address ?? fallbackAddress
        let message = OutgoingMessage(from: from, to: EmailAddress.parseList(snapshot.to),
                                      cc: EmailAddress.parseList(snapshot.cc), bcc: EmailAddress.parseList(snapshot.bcc),
                                      subject: snapshot.subject, body: snapshot.body, htmlBody: snapshot.htmlBody,
                                      inReplyTo: snapshot.inReplyTo, references: snapshot.references,
                                      attachments: snapshot.attachments, replyingToEmailId: snapshot.replyingToEmailId,
                                      isForward: snapshot.isForward)
        return try await client.createDraft(message, draftsId: draftsId)
    }

    func destroy(_ id: String) async throws {
        let outcome = try await client.destroyEmails([id])
        if let error = outcome.failed[id], error != "notFound" { throw JMAPError.setFailed("Draft not removed: \(error)") }
    }
}

/// Demo mode: drafts "save" instantly and nothing leaves the Mac.
struct DemoDraftServer: DraftServer {
    func create(_ snapshot: DraftSnapshot) async throws -> String { "demo-draft-\(UUID().uuidString)" }
    func destroy(_ id: String) async throws {}
}

struct DemoOutboxSender: OutboxSending {
    func submit(_ item: OutboxItem) async throws -> SubmitResponse {
        try await Task.sleep(nanoseconds: 400_000_000)
        return SubmitResponse(emailId: "demo", submissionId: "demo", movedToSent: true)
    }
    func reconcile(_ item: OutboxItem) async throws -> SendReconciliation {
        SendReconciliation(emailIds: [], submissions: [], inSent: false)
    }
    func complete(_ item: OutboxItem) async throws -> FollowUpResult { FollowUpResult(draftRemoved: true, keywordSet: true) }
    func discardCreatedCopy(_ emailId: String) async {}
}
