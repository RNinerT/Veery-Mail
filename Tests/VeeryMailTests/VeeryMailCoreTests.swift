import XCTest
@testable import VeeryMailCore

final class SearchQueryTests: XCTestCase {
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
