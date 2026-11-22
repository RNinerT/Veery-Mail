import XCTest
@testable import VeeryMailCore

final class SearchQueryTests: XCTestCase {
    func testCorrespondenceSearchMatchesEitherDirectionAndKeepsMailboxExclusions() throws {
        let query = SearchQuery.parse("with:one@example.com with:two@example.com")
        let filter = query.filter(defaultMailboxId: nil, excludedMailboxIds: ["trash"]) { _ in nil }
        XCTAssertEqual(filter["operator"] as? String, "AND")
        let conditions = try XCTUnwrap(filter["conditions"] as? [[String: Any]])
        XCTAssertEqual(conditions[0]["operator"] as? String, "OR")
        let fields = try XCTUnwrap(conditions[0]["conditions"] as? [[String: String]])
        XCTAssertEqual(fields.count, 8)
        XCTAssertTrue(fields.contains(["from": "one@example.com"]))
        XCTAssertTrue(fields.contains(["to": "two@example.com"]))
        XCTAssertEqual(conditions[1]["inMailboxOtherThan"] as? [String], ["trash"])
    }

    func testParsesOperatorsAndFreeText() {
        let q = SearchQuery.parse(#"from:alice subject:"q3 plan" has:attachment is:unread budget"#)
        XCTAssertEqual(q.from, ["alice"])
        XCTAssertEqual(q.subject, ["q3 plan"])
        XCTAssertEqual(q.hasAttachment, true)
        XCTAssertEqual(q.unread, true)
        XCTAssertEqual(q.text, ["budget"])
    }

    func testRelativeDates() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let q = SearchQuery.parse("newer_than:7d", now: now)
        XCTAssertEqual(q.after, now.addingTimeInterval(-7 * 86_400))
    }

    func testUnknownOperatorIsText() {
        XCTAssertEqual(SearchQuery.parse("foo:bar").text, ["foo:bar"])
    }

    func testFilterSingleCondition() {
        let f = SearchQuery.parse("hello").filter(defaultMailboxId: nil) { _ in nil }
        XCTAssertEqual(f["text"] as? String, "hello")
    }

    func testFilterCombinesWithAnd() {
        let f = SearchQuery.parse("from:bob in:archive is:flagged").filter(defaultMailboxId: nil) {
            $0 == "archive" ? "mb-archive" : nil
        }
        XCTAssertEqual(f["operator"] as? String, "AND")
        let conditions = f["conditions"] as? [[String: Any]] ?? []
        XCTAssertTrue(conditions.contains { $0["from"] as? String == "bob" })
        XCTAssertTrue(conditions.contains { $0["hasKeyword"] as? String == "$flagged" })
        XCTAssertTrue(conditions.contains { $0["inMailbox"] as? String == "mb-archive" })
    }

    func testExcludesTrashWhenSearchingEverywhere() {
        let f = SearchQuery.parse("x").filter(defaultMailboxId: nil, excludedMailboxIds: ["t"]) { _ in nil }
        let conditions = f["conditions"] as? [[String: Any]] ?? []
        XCTAssertTrue(conditions.contains { ($0["inMailboxOtherThan"] as? [String]) == ["t"] })
    }
}

final class ModelTests: XCTestCase {
    func testParseAddressList() {
        let list = EmailAddress.parseList(#""Ann Lee" <ann@example.com>, bob@example.com; not-an-address"#)
        XCTAssertEqual(list, [EmailAddress(name: "Ann Lee", email: "ann@example.com"),
                              EmailAddress(email: "bob@example.com")])
    }

    func testDecodesEmailDetailWithHeaderProperties() throws {
        let json = """
        {"id":"M1","threadId":"T1","mailboxIds":{"inbox":true},"keywords":{"$seen":true},
         "from":[{"name":"News","email":"news@example.com"}],"subject":"Hi",
         "receivedAt":"2026-11-14T09:30:00Z",
         "htmlBody":[{"partId":"2","type":"text/html"}],
         "textBody":[{"partId":"1","type":"text/plain"}],
         "bodyValues":{"1":{"value":"plain"},"2":{"value":"<p>html</p>"}},
         "attachments":[],
         "header:List-Unsubscribe:asURLs":["mailto:u@example.com","https://example.com/u"],
         "header:List-Unsubscribe-Post:asText":"List-Unsubscribe=One-Click"}
        """
        let email = try JMAPDate.decoder().decode(EmailDetail.self, from: Data(json.utf8))
        XCTAssertEqual(email.html, "<p>html</p>")
        XCTAssertEqual(email.plainText, "plain")
        XCTAssertFalse(email.isUnread)
        XCTAssertEqual(email.unsubscribeURL?.absoluteString, "https://example.com/u")
        XCTAssertTrue(email.supportsOneClickUnsubscribe)
    }

    func testDetailPropertiesIncludeHeaderAccessors() {
        XCTAssertTrue(EmailDetail.properties.contains("header:List-Unsubscribe:asURLs"))
        XCTAssertTrue(EmailDetail.properties.contains("bodyValues"))
    }

    func testPushPayloadParsing() {
        let payload = #"{"@type":"StateChange","changed":{"u123":{"Email":"s1","Mailbox":"s2"}}}"#
        XCTAssertEqual(JMAPClient.changedTypes(payload, account: "u123"), ["Email", "Mailbox"])
        XCTAssertNil(JMAPClient.changedTypes(payload, account: "other"))
    }

    func testSessionMaxDelayedSend() throws {
        let json = """
        {"username":"me@fastmail.com","apiUrl":"https://api.fastmail.com/jmap/api/",
         "downloadUrl":"https://x/{accountId}/{blobId}/{name}?type={type}",
         "uploadUrl":"https://x/upload/{accountId}/","eventSourceUrl":"https://x/es?types={types}",
         "state":"s","capabilities":{"urn:ietf:params:jmap:core":{}},
         "primaryAccounts":{"urn:ietf:params:jmap:mail":"u1"},
         "accounts":{"u1":{"name":"me","isPersonal":true,"isReadOnly":false,
           "accountCapabilities":{"urn:ietf:params:jmap:submission":{"maxDelayedSend":44236800}}}}}
        """
        let s = try JSONDecoder().decode(JMAPSession.self, from: Data(json.utf8))
        XCTAssertEqual(s.mailAccountId, "u1")
        XCTAssertEqual(s.maxDelayedSend, 44_236_800)
    }

    func testHTMLEscaping() {
        XCTAssertEqual("<a&\"b\">".htmlEscaped, "&lt;a&amp;&quot;b&quot;&gt;")
    }
}

final class PresentationTests: XCTestCase {
    func testCleansSimpleLoginSender() {
        let c = EmailAddress(name: "Austin Hendrick - ahendrick at autostarsilverthorne.net",
                             email: "random123@simplelogin.co").cleaned
        XCTAssertEqual(c.name, "Austin Hendrick")
        XCTAssertEqual(c.domain, "autostarsilverthorne.net")
        XCTAssertEqual(c.address, "ahendrick@autostarsilverthorne.net")
        XCTAssertTrue(c.isRelayed)
    }

    func testCleansRelayedSenderWithoutName() {
        let c = EmailAddress(name: "finserv at tcu.edu", email: "x@relay.example").cleaned
        XCTAssertEqual(c.name, "finserv@tcu.edu")
        XCTAssertTrue(c.isRelayed)
    }

    func testLeavesOrdinarySendersAlone() {
        let c = EmailAddress(name: "Look at this deal", email: "news@Shop.example").cleaned
        XCTAssertEqual(c.name, "Look at this deal")
        XCTAssertEqual(c.domain, "shop.example")
        XCTAssertFalse(c.isRelayed)

        let bare = EmailAddress(email: "bob@example.com").cleaned
        XCTAssertEqual(bare.name, "bob@example.com")
    }

    func testSimpleHTMLDetection() {
        XCTAssertTrue(HTMLHeuristics.isSimple("<div>hi<br><a href=\"https://x.example\">link</a></div>"))
        XCTAssertFalse(HTMLHeuristics.isSimple("<table><tr><td>newsletter</td></tr></table>"))
        XCTAssertFalse(HTMLHeuristics.isSimple("<div style=\"background-color:#fff\">x</div>"))
        XCTAssertTrue(HTMLHeuristics.hasRemoteContent("<img src=\"https://t.example/p.gif\">"))
        XCTAssertFalse(HTMLHeuristics.hasRemoteContent("<img src=\"cid:logo\">"))
    }

    func testDayBuckets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        XCTAssertEqual(DayBucket.bucket(for: ago(1), now: now, calendar: cal), .today)
        XCTAssertEqual(DayBucket.bucket(for: ago(20), now: now, calendar: cal), .yesterday)
        XCTAssertEqual(DayBucket.bucket(for: ago(24 * 4), now: now, calendar: cal), .week)
        XCTAssertEqual(DayBucket.bucket(for: ago(24 * 15), now: now, calendar: cal), .month)
        XCTAssertEqual(DayBucket.bucket(for: ago(24 * 90), now: now, calendar: cal), .older)
    }
}

final class MailStatsTests: XCTestCase {
    private func mail(_ id: String, thread: String, from: String, hoursAgo: Double, now: Date,
                      boxes: [String: Bool] = ["inbox": true], keywords: [String: Bool] = ["$seen": true]) -> EmailSummary {
        EmailSummary(id: id, threadId: thread, mailboxIds: boxes, keywords: keywords,
                     from: [EmailAddress(email: from)], receivedAt: now.addingTimeInterval(-hoursAgo * 3600))
    }

    func testMedian() {
        XCTAssertNil(MailStats.median([]))
        XCTAssertEqual(MailStats.median([3, 1, 2]), 2)
        XCTAssertEqual(MailStats.median([4, 1, 2, 3]), 2.5)
    }

    func testStreakSkipsUnfinishedToday() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 12))!
        func key(_ daysAgo: Int) -> String { MailStats.dayKey(today.addingTimeInterval(Double(-daysAgo) * 86_400), cal) }
        let ledger = [key(0): 7, key(1): 0, key(2): 0, key(3): 5, key(4): 0]
        XCTAssertEqual(MailStats.streak(dailyMinimum: ledger, target: 0, today: today, calendar: cal), 2)
        XCTAssertEqual(MailStats.streak(dailyMinimum: ledger, target: 5, today: today, calendar: cal), 4)
        XCTAssertEqual(MailStats.streak(dailyMinimum: [:], target: 0, today: today, calendar: cal), 0)
    }

    func testWaitingAndReplyDelays() {
        let now = Date()
        let mine: Set<String> = ["me@example.com"]
        // t1: they wrote, I replied 2h later, no answer for 4 days -> waiting.
        // t2: I wrote, they answered -> not waiting.
        let t1in = mail("a", thread: "t1", from: "ann@example.com", hoursAgo: 98, now: now)
        let t1out = mail("b", thread: "t1", from: "me@example.com", hoursAgo: 96, now: now, boxes: ["sent": true])
        let t2out = mail("c", thread: "t2", from: "me@example.com", hoursAgo: 100, now: now, boxes: ["sent": true])
        let t2in = mail("d", thread: "t2", from: "bob@example.com", hoursAgo: 90, now: now)
        let sent = [t1out, t2out], all = [t1in, t1out, t2out, t2in]
        XCTAssertEqual(MailStats.waitingThreads(sent: sent, threadMail: all, sentMailboxId: "sent",
                                                myAddresses: mine, olderThan: 3 * 86_400, now: now), 1)
        let delays = MailStats.replyDelays(sent: sent, threadMail: all, sentMailboxId: "sent", myAddresses: mine)
        XCTAssertEqual(delays.count, 1)
        XCTAssertEqual(delays[0].delay, 2 * 3600, accuracy: 1)
    }

    func testBusiestWindowAndFolderLoad() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let dates = (0..<30).map { base.addingTimeInterval(Double($0 % 3 == 0 ? 14 : 9) * 3600 + Double($0) * 86_400) }
        XCTAssertEqual(MailStats.busiestWindow(dates, calendar: cal)?.startHour, 9)
        XCTAssertNil(MailStats.busiestWindow(Array(dates.prefix(5)), calendar: cal))

        let meta = [MailMeta(id: "1", threadId: "1", receivedAt: base, mailboxIds: ["inbox": true, "label": true]),
                    MailMeta(id: "2", threadId: "2", receivedAt: base, mailboxIds: ["archive": true]),
                    MailMeta(id: "3", threadId: "3", receivedAt: base, mailboxIds: ["archive": true])]
        let load = MailStats.folderLoad(meta, preferredOrder: ["inbox", "archive"])
        XCTAssertEqual(load.first?.mailboxId, "archive")
        XCTAssertEqual(load.first?.count, 2)
        XCTAssertEqual(load.last?.mailboxId, "inbox")
    }
}
