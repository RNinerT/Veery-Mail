import XCTest
@testable import VeeryMailCore

@MainActor
final class OutboxTests: XCTestCase {
    func makeOutbox(_ storage: MemoryOutboxStorage = MemoryOutboxStorage(), clock: TestClock = TestClock(),
                    sender: MockSender = MockSender()) -> OutboxController {
        let outbox = OutboxController(storage: storage, now: { clock.now }, sleep: neverSleep)
        outbox.sender = sender
        return outbox
    }

    /// Acceptance: two overlapping Undo Send windows keep their own deadlines.
    func testOverlappingUndoWindowsAreIndependent() async {
        let clock = TestClock(), sender = MockSender()
        let outbox = makeOutbox(clock: clock, sender: sender)
        let start = clock.now
        let a = outbox.enqueue(message("A"), identityId: "i", accountKey: "k", serverDraftId: "DA",
                               sendAt: nil, undoWindow: 10, composerState: nil)
        clock.advance(5)
        let b = outbox.enqueue(message("B"), identityId: "i", accountKey: "k", serverDraftId: "DB",
                               sendAt: nil, undoWindow: 10, composerState: nil)
        XCTAssertEqual(outbox.item(a)?.state, .queued(until: start.addingTimeInterval(10)), "starting B must not touch A")
        XCTAssertEqual(outbox.item(b)?.state, .queued(until: start.addingTimeInterval(15)))
        XCTAssertEqual(sender.submitCalls, 0)

        clock.advance(5)          // t = 10: only A is due
        outbox.fireDue()
        await outbox.settle(a)
        XCTAssertNil(outbox.item(a), "A sent and cleared")
        XCTAssertEqual(outbox.item(b)?.state, .queued(until: start.addingTimeInterval(15)), "B keeps its remaining window")
        XCTAssertEqual(sender.submitCalls, 1)

        // Undo B within its window: returned intact, never sent.
        let undone = outbox.takeBack(b)
        XCTAssertEqual(undone?.message.subject, "B")
        XCTAssertEqual(undone?.serverDraftId, "DB")
        clock.advance(10); outbox.fireDue(); await drain()
        XCTAssertEqual(sender.submitCalls, 1)
    }

    /// Acceptance: quit during submission → next launch reconciles instead of resending.
    func testQuitDuringSubmissionReconcilesAfterRestart() async {
        let storage = MemoryOutboxStorage(), clock = TestClock()
        let sender = MockSender(); sender.holdSubmit = true
        let outbox = makeOutbox(storage, clock: clock, sender: sender)
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: "D",
                                sendAt: nil, undoWindow: 0, composerState: nil)
        outbox.fireDue()
        await drain()
        if case .submitting = storage.load().first?.state {} else { XCTFail("submitting must be on disk before the request") }
        // App quits here: the request's outcome is never seen.

        let sender2 = MockSender()
        sender2.reconcileResult = { SendReconciliation(emailIds: ["E1"], submissions: [.init(id: "S1", undoStatus: "final")], inSent: true) }
        let relaunched = makeOutbox(storage, clock: clock, sender: sender2)
        relaunched.load()
        if case .unknown = relaunched.item(id)?.state {} else { XCTFail("an interrupted send is unknown after restart") }
        relaunched.resume()
        await relaunched.settle(id)
        XCTAssertNil(relaunched.item(id), "found on the server, so treated as sent")
        XCTAssertEqual(sender2.submitCalls, 0, "never sent a second time")
        XCTAssertEqual(sender2.completeCalls, 1, "old draft removed only after confirmation")
    }

    /// A message still in its Undo Send window at quit is held, not sent, at next launch.
    func testQueuedMessageIsHeldAfterRestart() async {
        let storage = MemoryOutboxStorage()
        let outbox = makeOutbox(storage)
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: nil,
                                sendAt: nil, undoWindow: 30, composerState: Data("composer".utf8))
        outbox.suspendForQuit()
        let sender = MockSender()
        let relaunched = makeOutbox(storage, sender: sender)
        relaunched.load(); relaunched.resume(); await drain()
        XCTAssertEqual(relaunched.item(id)?.state, .held)
        XCTAssertEqual(sender.submitCalls, 0)
        XCTAssertEqual(relaunched.takeBack(id)?.composerState, Data("composer".utf8), "reopens with everything")
    }

    /// Acceptance: a rejected submission leaves the old draft intact.
    func testRejectedSubmissionKeepsDraft() async {
        let sender = MockSender()
        sender.submitResult = { SubmitResponse(emailId: "E9", emailError: nil, submissionId: nil,
                                               submissionError: "forbiddenToSend: quota", movedToSent: nil) }
        let outbox = makeOutbox(sender: sender)
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: "D1",
                                sendAt: nil, undoWindow: 0, composerState: nil)
        outbox.fireDue(); await outbox.settle(id)
        guard case .failed(let reason) = outbox.item(id)?.state else { return XCTFail("should fail") }
        XCTAssertTrue(reason.contains("forbiddenToSend"))
        XCTAssertEqual(sender.completeCalls, 0, "draft not removed")
        XCTAssertEqual(outbox.item(id)?.serverDraftId, "D1")
        XCTAssertEqual(sender.discarded, ["E9"], "the extra copy made for sending is removed")
        XCTAssertNotNil(outbox.takeBack(id), "user can reopen it")
    }

    /// Acceptance: sent, but the follow-up update failed → reported separately, not as a failed send.
    func testSuccessfulSubmissionWithFailedFollowUp() async {
        let sender = MockSender()
        sender.completeResult = { FollowUpResult(draftRemoved: false, keywordSet: false) }
        var events: [OutboxEvent] = []
        let outbox = makeOutbox(sender: sender)
        outbox.onEvent = { events.append($0) }
        var m = message(); m.replyingToEmailId = "ORIG"
        let id = outbox.enqueue(m, identityId: "i", accountKey: "k", serverDraftId: "D",
                                sendAt: nil, undoWindow: 0, composerState: nil)
        outbox.fireDue(); await outbox.settle(id)
        guard case .sentWithProblem(let problem) = outbox.item(id)?.state else { return XCTFail("expected sentWithProblem") }
        XCTAssertTrue(problem.hasPrefix("Sent, but"))
        XCTAssertTrue(problem.contains("draft") && problem.contains("answered"))
        XCTAssertFalse(events.contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertNil(outbox.takeBack(id), "a sent message can't be taken back")
    }

    /// Acceptance: timeout after the server accepted → reconciled, no duplicate.
    func testTimeoutAfterAcceptanceDoesNotDuplicate() async {
        let sender = MockSender()
        sender.submitResult = { throw URLError(.timedOut) }
        sender.reconcileResult = { SendReconciliation(emailIds: ["E1"], submissions: [.init(id: "S1", undoStatus: "pending")], inSent: false) }
        let outbox = makeOutbox(sender: sender)
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: nil,
                                sendAt: nil, undoWindow: 0, composerState: nil)
        outbox.fireDue(); await outbox.settle(id)
        XCTAssertEqual(sender.submitCalls, 1)
        XCTAssertNil(outbox.item(id), "confirmed by reconciliation")
    }

    /// Inconclusive reconciliation → the user decides.
    func testInconclusiveReconciliationAsksUser() async {
        let sender = MockSender()
        sender.submitResult = { throw URLError(.networkConnectionLost) }
        sender.reconcileResult = { throw URLError(.notConnectedToInternet) }
        var asked = false
        let outbox = makeOutbox(sender: sender)
        outbox.onEvent = { if case .needsDecision = $0 { asked = true } }
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: "D",
                                sendAt: nil, undoWindow: 0, composerState: nil)
        outbox.fireDue(); await outbox.settle(id)
        guard case .unknown = outbox.item(id)?.state else { return XCTFail("stays unknown") }
        XCTAssertTrue(asked)
        XCTAssertNil(outbox.takeBack(id), "no blind retry or edit while unknown")
        let kept = outbox.resolveUnknown(id, .keepAsDraft)
        XCTAssertEqual(kept?.serverDraftId, "D")
        XCTAssertEqual(sender.submitCalls, 1)
    }

    /// Not submitted after a drop → failed, and a retry reuses the created copy.
    func testRetryAfterReconciledFailureReusesCopy() async {
        let sender = MockSender()
        var first = true
        sender.submitResult = {
            if first { first = false; throw URLError(.timedOut) }
            return SubmitResponse(emailId: "E1", submissionId: "S1", movedToSent: true)
        }
        sender.reconcileResult = { SendReconciliation(emailIds: ["E1"], submissions: [], inSent: false) }
        let outbox = makeOutbox(sender: sender)
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: nil,
                                sendAt: nil, undoWindow: 0, composerState: nil)
        outbox.fireDue(); await outbox.settle(id)
        guard case .failed = outbox.item(id)?.state else { return XCTFail("not submitted → failed") }
        XCTAssertEqual(outbox.item(id)?.createdEmailId, "E1")
        outbox.retry(id); await outbox.settle(id)
        XCTAssertNil(outbox.item(id))
        XCTAssertEqual(sender.submitCalls, 2)
    }

    /// Scheduled sends use the same recovery.
    func testScheduledSendTimeoutReconciles() async {
        let sender = MockSender()
        sender.submitResult = { throw URLError(.timedOut) }
        sender.reconcileResult = { SendReconciliation(emailIds: ["E1"], submissions: [.init(id: "S1", undoStatus: "pending")], inSent: false) }
        var scheduledEvent = false
        let outbox = makeOutbox(sender: sender)
        outbox.onEvent = { if case .sent(_, let scheduled) = $0 { scheduledEvent = scheduled } }
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: nil,
                                sendAt: Date().addingTimeInterval(3600), undoWindow: 0, composerState: nil)
        outbox.fireDue(); await outbox.settle(id)
        XCTAssertNil(outbox.item(id))
        XCTAssertTrue(scheduledEvent)
    }

    /// Request never left the Mac → definitely not sent.
    func testNoConnectionIsDefiniteFailure() async {
        let sender = MockSender()
        sender.submitResult = { throw URLError(.notConnectedToInternet) }
        let outbox = makeOutbox(sender: sender)
        let id = outbox.enqueue(message(), identityId: "i", accountKey: "k", serverDraftId: "D",
                                sendAt: nil, undoWindow: 0, composerState: nil)
        outbox.fireDue(); await outbox.settle(id)
        guard case .failed = outbox.item(id)?.state else { return XCTFail("definite failure") }
    }
}

final class SubmitParsingTests: XCTestCase {
    func testCreateAndSubmitReportsEachStep() async throws {
        let (client, transport) = try await makeClient { calls in
            XCTAssertEqual(calls.map { $0[0] as? String }, ["Email/set", "EmailSubmission/set"])
            let set = calls[0][1] as! [String: Any]
            XCTAssertNil(set["destroy"], "the user's draft is never destroyed in the send request")
            let created = (set["create"] as! [String: Any])["msg"] as! [String: Any]
            XCTAssertEqual(created["messageId"] as? [String], ["mid@example.com"])
            return [
                ["Email/set", ["created": ["msg": ["id": "E1"]]], "e"],
                ["EmailSubmission/set", ["created": ["sub": ["id": "S1"]]], "s"],
                ["Email/set", ["updated": ["E1": NSNull()]], "s"],
            ]
        }
        var m = message(); m.messageId = "mid@example.com"
        let r = try await client.createAndSubmit(m, identityId: "i", draftsId: "drafts", sentId: "sent", sendAt: nil)
        XCTAssertEqual(r, SubmitResponse(emailId: "E1", emailError: nil, submissionId: "S1", submissionError: nil, movedToSent: true))
        XCTAssertEqual(transport.count, 2)
    }

    func testSubmissionMethodErrorKeepsCreatedId() async throws {
        let (client, _) = try await makeClient { _ in [
            ["Email/set", ["created": ["msg": ["id": "E1"]]], "e"],
            ["error", ["type": "forbidden"], "s"],
        ] }
        let r = try await client.createAndSubmit(message(), identityId: "i", draftsId: "d", sentId: "s", sendAt: nil)
        XCTAssertEqual(r.emailId, "E1")
        XCTAssertFalse(r.accepted)
        XCTAssertEqual(r.submissionError, "forbidden")
    }

    func testFollowUpReportsPartsSeparately() async throws {
        let (client, _) = try await makeClient { _ in [
            ["Email/set", ["destroyed": ["D1"], "notUpdated": ["O1": ["type": "notFound"]]], "f"],
        ] }
        let r = try await client.completeSend(oldDraftId: "D1", originalEmailId: "O1", keyword: "$answered")
        XCTAssertEqual(r, FollowUpResult(draftRemoved: true, keywordSet: false))
    }
}

@MainActor
final class DraftSavingTests: XCTestCase {
    final class FakeServer: DraftServer, @unchecked Sendable {
        let lock = NSLock()
        var created: [DraftSnapshot] = []
        var destroyed: [String] = []
        var fail = false
        var hold: CheckedContinuation<Void, Never>?
        var holdNext = false
        /// Set when release() runs before the held call has parked, so it doesn't wait at all.
        var releasedEarly = false
        func create(_ snapshot: DraftSnapshot) async throws -> String {
            if lock.withLock({ holdNext }) {
                await withCheckedContinuation { c in
                    let resumeNow: Bool = lock.withLock {
                        holdNext = false
                        if releasedEarly { releasedEarly = false; return true }
                        hold = c
                        return false
                    }
                    if resumeNow { c.resume() }
                }
            }
            if lock.withLock({ fail }) { throw URLError(.timedOut) }
            return lock.withLock { created.append(snapshot); return "D\(created.count)" }
        }
        func destroy(_ id: String) async throws { lock.withLock { destroyed.append(id) } }
        func release() {
            let h: CheckedContinuation<Void, Never>? = lock.withLock {
                let h = hold; hold = nil
                if h == nil { releasedEarly = true }
                return h
            }
            h?.resume()
        }
    }

    func snap(to: String = "", subject: String = "", attachments: [OutgoingAttachment] = []) -> DraftSnapshot {
        DraftSnapshot(identityId: "i", to: to, cc: "", bcc: "", subject: subject, body: "Body", htmlBody: nil,
                      attachments: attachments, inReplyTo: nil, references: [], replyingToEmailId: nil, isForward: false)
    }

    /// Acceptance: recipient-only and attachment-only edits are saved.
    func testRecipientAndAttachmentOnlyEditsAreDirty() async {
        let server = FakeServer()
        let c = DraftSaveCoordinator(server: server)
        let base = snap(to: "a@example.com", subject: "S")
        let ok = await c.save(base)
        XCTAssertTrue(ok)
        let recipientEdit = snap(to: "a@example.com, b@example.com", subject: "S")
        XCTAssertTrue(c.isDirty(recipientEdit))
        let saved2 = await c.save(recipientEdit)
        XCTAssertTrue(saved2)
        let attachmentEdit = snap(to: "a@example.com, b@example.com", subject: "S",
                                  attachments: [OutgoingAttachment(blobId: "B", name: "x.pdf", type: "application/pdf", size: 1)])
        XCTAssertTrue(c.isDirty(attachmentEdit))
        let saved3 = await c.save(attachmentEdit)
        XCTAssertTrue(saved3)
        XCTAssertEqual(server.created.count, 3)
        XCTAssertEqual(server.destroyed, ["D1", "D2"], "previous copy removed only after its replacement exists")
        XCTAssertEqual(c.serverDraftId, "D3")
    }

    /// Acceptance: edits made during a save stay dirty.
    func testChangesDuringSaveRemainDirty() async {
        let server = FakeServer(); server.holdNext = true
        let c = DraftSaveCoordinator(server: server)
        let first = snap(subject: "One")
        let task = Task { await c.save(first) }
        await drain()
        XCTAssertTrue(c.isSaving)
        let typedMeanwhile = snap(subject: "One more")
        server.release()
        _ = await task.value
        XCTAssertEqual(c.savedSnapshot, first, "records exactly what was sent")
        XCTAssertTrue(c.isDirty(typedMeanwhile))
    }

    /// Saves are serialized: a second save waits for the first.
    func testSavesAreSerialized() async {
        let server = FakeServer(); server.holdNext = true
        let c = DraftSaveCoordinator(server: server)
        let t1 = Task { await c.save(self.snap(subject: "A")) }
        await drain()
        let t2 = Task { await c.save(self.snap(subject: "B")) }
        await drain()
        XCTAssertEqual(server.created.count, 0)
        server.release()
        _ = await t1.value; _ = await t2.value
        XCTAssertEqual(server.created.map(\.subject), ["A", "B"])
        XCTAssertEqual(c.savedSnapshot?.subject, "B")
    }

    /// Acceptance (model side): a failed save keeps the old draft and reports the error.
    func testFailedSaveKeepsPreviousDraft() async {
        let server = FakeServer()
        let c = DraftSaveCoordinator(server: server, existingDraftId: "OLD", existingSnapshot: snap(subject: "Old"))
        server.fail = true
        let ok = await c.save(snap(subject: "New"))
        XCTAssertFalse(ok)
        XCTAssertNotNil(c.lastError)
        XCTAssertEqual(c.serverDraftId, "OLD")
        XCTAssertTrue(server.destroyed.isEmpty)
        XCTAssertTrue(c.isDirty(snap(subject: "New")))
    }

    /// A save that finishes after send or discard doesn't bring the draft back.
    func testLateSaveAfterRetireIsCleanedUp() async {
        let server = FakeServer(); server.holdNext = true
        let c = DraftSaveCoordinator(server: server, existingDraftId: "OLD", existingSnapshot: snap(subject: "Old"))
        let t = Task { await c.save(self.snap(subject: "Newer")) }
        await drain()
        let retired = c.retireNow()
        XCTAssertEqual(retired.draftId, "OLD")
        server.release()
        let ok = await t.value
        XCTAssertFalse(ok)
        XCTAssertEqual(server.destroyed, ["D1"], "the late copy is removed")
        XCTAssertEqual(c.serverDraftId, "OLD")
        let afterRetire = await c.save(snap(subject: "Even newer"))
        XCTAssertFalse(afterRetire)
    }
}
