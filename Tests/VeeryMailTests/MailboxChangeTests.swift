import XCTest
@testable import VeeryMailCore

final class MutationTests: XCTestCase {
    /// Acceptance: a mixed-result archive leaves successes moved and undoes only confirmed ones.
    func testMixedResultArchive() async throws {
        let mail = [summary("m1", boxes: ["inbox"]), summary("m2", thread: "t2", boxes: ["inbox"]),
                    summary("m3", thread: "t3", boxes: ["inbox"])]
        let plan = MailMutation.move(mail, scope: "inbox", visibleMailboxes: [:], to: "archive")
        XCTAssertEqual(plan.count, 3)
        let (client, _) = try await makeClient { calls in
            let update = (calls[0][1] as! [String: Any])["update"] as! [String: Any]
            XCTAssertEqual(Set(update.keys), ["m1", "m2", "m3"])
            return [["Email/set", ["updated": ["m1": NSNull(), "m3": NSNull()],
                                   "notUpdated": ["m2": ["type": "forbidden"]]], "u"]]
        }
        let outcome = try await client.updateEmails(MailMutation.patches(plan))
        XCTAssertEqual(outcome.succeeded, ["m1", "m3"])
        XCTAssertEqual(outcome.failed, ["m2": "forbidden"])
        let confirmed = MailMutation.confirmed(plan, outcome)
        XCTAssertEqual(confirmed.map(\.emailId), ["m1", "m3"], "undo only for confirmed changes")
        XCTAssertEqual(MailMutation.summary(verb: "archived", confirmedThreads: 2, totalThreads: 3),
                       "2 of 3 conversations archived. 1 couldn’t be changed.")
        XCTAssertEqual(MailMutation.summary(verb: "moved to Trash", confirmedThreads: 1, totalThreads: 1),
                       "1 conversation moved to Trash")
    }

    /// Acceptance: undo keeps a label another client added after the move.
    func testUndoPreservesUnrelatedLabel() {
        let plan = MailMutation.move([summary("m1", boxes: ["inbox"])], scope: "inbox", visibleMailboxes: [:], to: "archive")
        let undo = MailMutation.patches(plan, inverse: true)["m1"]!
        XCTAssertEqual(Set(undo.keys), ["mailboxIds/inbox", "mailboxIds/archive"])
        XCTAssertNil(undo["mailboxIds/receipts"], "a label added later is never touched")
        XCTAssertTrue(undo["mailboxIds/archive"] is NSNull)
        XCTAssertEqual(undo["mailboxIds/inbox"] as? Bool, true)
    }

    func testSearchViewMoveLeavesOnlyVisibleMailboxes() {
        // In search results the row was seen in Inbox; its copy in Sent stays put.
        let mail = [summary("m1", boxes: ["inbox", "receipts"]), summary("m2", boxes: ["sent"])]
        let plan = MailMutation.move(mail, scope: nil, visibleMailboxes: ["t1": ["inbox"]], to: "archive")
        XCTAssertEqual(plan.map(\.emailId), ["m1"])
        XCTAssertEqual(plan[0].forward, ["mailboxIds/inbox": false, "mailboxIds/archive": true])
    }

    func testKeywordChangesOnlyWhatDiffers() {
        let mail = [summary("a", boxes: ["inbox"], keywords: ["$seen": true]), summary("b", boxes: ["inbox"])]
        let plan = MailMutation.keyword(mail, "$seen", on: true)
        XCTAssertEqual(plan.map(\.emailId), ["b"])
        XCTAssertEqual(plan[0].inverse, ["keywords/$seen": false])
    }
}

final class PermanentDeleteTests: XCTestCase {
    /// Acceptance: a thread containing messages outside Trash only deletes the Trash copies.
    func testThreadWithMessagesOutsideTrash() {
        let thread = [summary("a", boxes: ["trash"]), summary("b", boxes: ["inbox"]), summary("c", boxes: ["sent"])]
        let plan = PermanentDeletePlan.make(threadMail: thread, trashId: "trash")
        XCTAssertEqual(plan.messageIds, ["a"])
        XCTAssertEqual(plan.count, 1)
        XCTAssertTrue(plan.alsoElsewhere.isEmpty)
    }

    /// Acceptance: a message filed in Trash and another mailbox is flagged before confirming.
    func testMessageInTrashAndAnotherMailbox() {
        let plan = PermanentDeletePlan.make(threadMail: [summary("a", boxes: ["trash", "receipts"]),
                                                          summary("b", boxes: ["trash"])], trashId: "trash")
        XCTAssertEqual(Set(plan.messageIds), ["a", "b"])
        XCTAssertEqual(plan.alsoElsewhere, ["a": ["receipts"]])
        XCTAssertEqual(plan.trashOnlyIds, ["b"])
    }

    func testDestroyReportsPerItem() async throws {
        let (client, _) = try await makeClient { _ in
            [["Email/set", ["destroyed": ["a"], "notDestroyed": ["b": ["type": "notFound"]]], "d"]]
        }
        let outcome = try await client.destroyEmails(["a", "b"])
        XCTAssertEqual(outcome.succeeded, ["a"])
        XCTAssertEqual(outcome.failed, ["b": "notFound"])
    }
}

final class SnoozeRecoveryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func planned() -> SnoozeRecord {
        let mail = [summary("m1", boxes: ["inbox"]), summary("m2", thread: "t2", boxes: ["inbox", "label"])]
        return SnoozePlanner.plan(mail, scope: "inbox", visibleMailboxes: [:], later: "later",
                                  until: now.addingTimeInterval(3600), accountKey: "k").0
    }

    /// Acceptance: restart after persisting but before moving → nothing is in Later, record resolves empty.
    func testRestartBeforeMove() {
        let r = SnoozePlanner.resolvePlanned(planned(), current: [summary("m1", boxes: ["inbox"]),
                                                                  summary("m2", thread: "t2", boxes: ["inbox", "label"])])
        XCTAssertTrue(r.entries.isEmpty)
        XCTAssertTrue(r.isFinished)
    }

    /// Acceptance: restart after moving but before recording success → found in Later, kept.
    func testRestartAfterMoveBeforeRecording() {
        let r = SnoozePlanner.resolvePlanned(planned(), current: [summary("m1", boxes: ["later"]),
                                                                  summary("m2", thread: "t2", boxes: ["later", "label"])])
        XCTAssertEqual(r.phase, .active)
        XCTAssertEqual(r.entries.map(\.state), [.moved, .moved])
        XCTAssertEqual(r.entries[0].originalMailboxIds, ["inbox"])
    }

    /// Acceptance: partial success in a batch keeps only confirmed moves.
    func testPartialBatch() {
        let r = SnoozePlanner.applyMove(planned(), SetOutcome(succeeded: ["m1"], failed: ["m2": "forbidden"]))
        XCTAssertEqual(r.entries.map(\.emailId), ["m1"])
    }

    /// Acceptance: a failed wake-up is retried later without undoing other filing.
    func testFailedWakeUpRetries() {
        var r = SnoozePlanner.applyMove(planned(), SetOutcome(succeeded: ["m1", "m2"]))
        let current = [summary("m1", boxes: ["later"]), summary("m2", thread: "t2", boxes: ["later", "label", "projects"])]
        let (woken, patches) = SnoozePlanner.wake(r, current: current)
        XCTAssertEqual(patches["m2"], ["mailboxIds/later": false, "mailboxIds/inbox": true, "keywords/$seen": false],
                       "labels added meanwhile (projects) and kept ones (label) are untouched")
        r = SnoozePlanner.applyWake(woken, SetOutcome(succeeded: ["m1"], failed: ["m2": "serverFail"]), now: now)
        XCTAssertFalse(r.isFinished)
        XCTAssertEqual(r.failedWakeAttempts, 1)
        XCTAssertEqual(r.nextAttempt, now.addingTimeInterval(60))
        XCTAssertEqual(r.entries.first { $0.emailId == "m2" }?.state, .moved, "still to return")
        r = SnoozePlanner.applyWake(r, SetOutcome(succeeded: ["m2"]), now: now)
        XCTAssertTrue(r.isFinished)
    }

    /// A message the user moved out of Later themselves is left alone.
    func testWakeSkipsMailMovedByUser() {
        let r = SnoozePlanner.applyMove(planned(), SetOutcome(succeeded: ["m1"]))
        let (woken, patches) = SnoozePlanner.wake(r, current: [summary("m1", boxes: ["archive"])])
        XCTAssertTrue(patches.isEmpty)
        XCTAssertTrue(woken.isFinished)
    }

    /// Acceptance: records survive on disk per account (sign-out keeps them for recovery).
    func testRecordsPersistPerAccount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = FileSnoozeStorage(url: dir.appendingPathComponent("account-a/snoozes.json"))
        let b = FileSnoozeStorage(url: dir.appendingPathComponent("account-b/snoozes.json"))
        try a.save([planned()])
        XCTAssertEqual(a.load().count, 1)
        XCTAssertTrue(b.load().isEmpty, "another account never sees them")
    }
}

final class RecipientTests: XCTestCase {
    /// Acceptance: a quoted display name containing a comma.
    func testQuotedNameWithComma() {
        let tokens = RecipientParser.parse(#""Doe, Jane" <jane@example.com>, bob@example.com"#)
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].address, EmailAddress(name: "Doe, Jane", email: "jane@example.com"))
        XCTAssertEqual(tokens[1].address, EmailAddress(email: "bob@example.com"))
        XCTAssertEqual(tokens[0].address?.fieldText, #""Doe, Jane" <jane@example.com>"#)
    }

    /// Acceptance: mixed valid and invalid entries are reported, not dropped.
    func testMixedValidAndInvalid() {
        let tokens = RecipientParser.parse("ann@example.com, not an address, bob@, carol@example")
        XCTAssertEqual(tokens.compactMap(\.address).map(\.email), ["ann@example.com"])
        let invalid = tokens.filter { $0.address == nil }.map(\.raw)
        XCTAssertEqual(invalid, ["not an address", "bob@", "carol@example"])
        XCTAssertNil(RecipientParser.addresses("ann@example.com, bob@"))
    }

    /// Acceptance: Bcc-only is valid input (To may be empty).
    func testBccOnly() {
        XCTAssertEqual(RecipientParser.parse("").count, 0)
        XCTAssertEqual(RecipientParser.addresses("")?.count, 0)
        XCTAssertEqual(RecipientParser.addresses("hidden@example.com")?.count, 1)
    }

    /// Acceptance: pasted multi-line addresses.
    func testPastedMultiline() {
        let tokens = RecipientParser.parse("ann@example.com\nBob Lee <bob@example.org>\r\n\n  carol@example.net;")
        XCTAssertEqual(tokens.compactMap(\.address).map(\.email), ["ann@example.com", "bob@example.org", "carol@example.net"])
    }

    func testAngleBracketAndEscapes() {
        XCTAssertEqual(RecipientParser.parse(#""A \"Q\" B" <q@example.com>"#).first?.address?.name, #"A "Q" B"#)
        XCTAssertNil(RecipientParser.parse("Ann <ann@example.com").first?.address)
        XCTAssertNotNil(RecipientParser.parse("user+tag@sub.example.co.uk").first?.address)
        XCTAssertNil(RecipientParser.parse("a..b@example.com").first?.address)
    }
}

final class ContactsTests: XCTestCase {
    func testContactCardsAreRead() async throws {
        let (client, _) = try await makeClient { calls in
            XCTAssertEqual(calls[0][0] as? String, "ContactCard/get")
            return [["ContactCard/get", ["list": [
                ["id": "c1", "name": ["full": "Imani Okafor"], "emails": ["e1": ["address": "imani@example.com"]]],
                ["id": "c2", "name": ["components": [["kind": "given", "value": "Sam"], ["kind": "surname", "value": "Lee"]]],
                 "emails": ["e1": ["address": "sam@example.org"], "e2": ["address": "SAM@example.org"]]],
            ]], "c"]]
        }
        let contacts = try await client.contacts()
        XCTAssertEqual(contacts.map(\.email), ["imani@example.com", "sam@example.org"])
        XCTAssertEqual(contacts.last?.name, "Sam Lee")
    }
}

final class EmojiCatalogTests: XCTestCase {
    /// Regression: a reversed range crashed the app when the emoji picker opened.
    func testRangesAreValid() {
        for (name, _, ranges) in EmojiCatalog.ranges {
            for range in ranges { XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound, name) }
        }
    }

    func testCatalogBuildsWithUniqueEmoji() {
        XCTAssertGreaterThan(EmojiCatalog.categories.count, 5)
        XCTAssertGreaterThan(EmojiCatalog.all.count, 1_000)
        XCTAssertEqual(Set(EmojiCatalog.all.map(\.character)).count, EmojiCatalog.all.count, "picker items need unique ids")
        XCTAssertTrue(EmojiCatalog.categories.allSatisfy { !$0.emoji.isEmpty })
        XCTAssertTrue(EmojiCatalog.all.contains { $0.character == "😀" })
    }
}

final class MailVolumeTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    func testWindowsAreFourteenDaysPlusTwoRollingWeeks() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 15))!
        let w = MailVolume.windows(now: now, calendar: calendar)
        XCTAssertEqual(w.count, 16)
        XCTAssertEqual(w[13].start, calendar.startOfDay(for: now), "last day is today")
        XCTAssertEqual(w[13].end, now, "today is partial")
        XCTAssertEqual(w[0].start, calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now)))
        for i in 0..<13 { XCTAssertEqual(w[i].end, w[i + 1].start, "days are contiguous") }
        XCTAssertEqual(w[14].duration, 7 * 24 * 3600); XCTAssertEqual(w[14].end, now)
        XCTAssertEqual(w[15].end, w[14].start)
    }

    func testPairsTrendAndPeak() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 15))!
        let w = MailVolume.windows(now: now, calendar: calendar)
        let counts: [Int] = [5, 6, 7, 8, 9, 10, 11, 12, 6, 8, 9, 10, 12, 3, 60, 50]
        let v = try XCTUnwrap(MailVolume.from(counts: counts, windows: w))
        XCTAssertEqual(v.pairs.count, 7)
        XCTAssertEqual(v.pairs[0].count, 12); XCTAssertEqual(v.pairs[0].previousCount, 5)
        XCTAssertTrue(v.pairs[6].isToday); XCTAssertEqual(v.pairs[6].count, 3)
        XCTAssertEqual(calendar.dateComponents([.day], from: v.pairs[2].previousDay, to: v.pairs[2].day).day, 7)
        XCTAssertEqual(v.peak, 12)
        XCTAssertEqual(v.trend, MailVolume.Trend.up(20))
        XCTAssertEqual(MailVolume(days: [], thisWeek: 48, lastWeek: 50).trend, MailVolume.Trend.same)
        XCTAssertEqual(MailVolume(days: [], thisWeek: 30, lastWeek: 60).trend, MailVolume.Trend.down(50))
        XCTAssertEqual(MailVolume(days: [], thisWeek: 4, lastWeek: 0).trend, MailVolume.Trend.noHistory)
        XCTAssertNil(MailVolume.from(counts: [1, 2], windows: w))
    }

    func testCountsComeFromOneRequestWithoutDownloadingMail() async throws {
        var seen: [[Any]] = []
        let (client, _) = try await makeClient { calls in
            seen = calls
            return calls.enumerated().map { i, c in ["Email/query", ["total": i + 1, "ids": []] as [String: Any], c[2]] }
        }
        let v = try await client.mailVolume(excluding: ["sent", "trash"], calendar: calendar)
        XCTAssertEqual(seen.count, 16, "one request with 16 counts")
        let args = seen.first?[1] as? [String: Any]
        XCTAssertEqual(args?["limit"] as? Int, 0, "no messages are downloaded")
        XCTAssertEqual(args?["calculateTotal"] as? Bool, true)
        XCTAssertEqual(v?.days.first?.count, 1)
        XCTAssertEqual(v?.thisWeek, 15); XCTAssertEqual(v?.lastWeek, 16)
    }
}
