import VeeryMailCore
import Foundation

/// Fictional mail for screenshots and design review. Nothing here touches the network.
/// Launch with:  open "build/Veery Mail.app" --args -demo YES
@MainActor
enum DemoMail {
    static func install(in store: MailStore) {
        let me = ["name": "Robin Vale", "email": "robin@example.com"]
        func person(_ name: String, _ email: String) -> [String: Any] { ["name": name, "email": email] }
        func at(_ hoursAgo: Double) -> String { JMAPDate.string(Date().addingTimeInterval(-hoursAgo * 3600)) }

        func box(_ id: String, _ name: String, role: String? = nil, parent: String? = nil,
                 unread: Int = 0, total: Int = 0, order: Int = 10) -> [String: Any] {
            ["id": id, "name": name,
             "parentId": parent.map { $0 as Any } ?? NSNull(), "role": role.map { $0 as Any } ?? NSNull(),
             "sortOrder": order, "totalEmails": total, "unreadEmails": unread,
             "totalThreads": total, "unreadThreads": unread]
        }
        let mailboxes: [[String: Any]] = [
            box("inbox", "Inbox", role: "inbox", unread: 3, total: 9, order: 1),
            box("drafts", "Drafts", role: "drafts", total: 2, order: 2),
            box("sent", "Sent", role: "sent", order: 3),
            box("archive", "Archive", role: "archive", total: 4210, order: 4),
            box("junk", "Spam", role: "junk", order: 5),
            box("trash", "Trash", role: "trash", order: 6),
            box("f1", "Harbor Street Renovation — Contractors and Permits"),
            box("f2", "Receipts"),
            box("f2a", "2026 Quarterly Estimated Taxes and Filings", parent: "f2", unread: 1),
            box("f2b", "Travel", parent: "f2"),
            box("f3", "Northfield Community Orchestra Board"),
            box("f4", "Newsletters", unread: 12),
            box("f5", "Family"),
        ]

        // id, thread, from, subject, preview, hours ago, unread, flagged, attachment
        typealias Row = (String, String, [String: Any], String, String, Double, Bool, Bool, Bool)
        let rows: [Row] = [
            ("m1b", "t1", person("Imani Okafor", "imani@fernhill.example"),
             "Re: Draft agenda for Thursday", "That works. I moved the budget item to the top so we don't run out of time again.", 0.6, true, false, false),
            ("m2", "t2", person("The Long Shelf", "editors@longshelf.example"),
             "This week: twelve books for the darkest month, and a quarrel about footnotes", "Our winter reading list, an interview with a translator, and letters from readers.", 2.2, true, false, false),
            ("m3", "t3", person("Mateo Reyes - mateo at brightwater.example", "relay-7f3k@relay.example"),
             "Quote for the kitchen cabinets", "Attached is the revised quote with the oak fronts. It is valid for thirty days.", 4.5, false, true, true),
            ("m4", "t4", person("Northfield Orchestra", "board@northfield.example"),
             "Minutes from the November board meeting and the vote on the spring programme, including the amended budget", "Minutes attached. Please reply by Friday if anything is recorded incorrectly.", 7, true, false, true),
            ("m5", "t5", person("Priya Raman", "priya@example.org"),
             "Photos from Saturday", "Finally sorted through them. The one of the dog on the pier is my favourite.", 26, false, false, true),
            ("m6", "t6", person("Lakeshore Utilities", "billing@lakeshore.example"),
             "Your November statement is ready", "Amount due: 84.20. Payment will be taken on the 28th.", 30, false, false, false),
            ("m7", "t7", person("Jonas Lindqvist", "jonas@example.net"),
             "Lunch next week?", "I'm in town Tuesday through Thursday. Is the place on Elm Street still good?", 75, false, false, false),
            ("m8", "t8", person("Fernhill Library", "noreply@fernhill.example"),
             "Two items are due soon", "The Overstory and one other item are due on 22 November.", 130, false, false, false),
            ("m9", "t9", person("Sam Whitlock", "sam@example.com"),
             "Spare key", "Left it with the neighbour at number 14. Thanks again for watering the plants.", 400, false, false, false),
        ]
        let summaries: [[String: Any]] = rows.map { r in
            var keywords: [String: Bool] = [:]
            if !r.6 { keywords["$seen"] = true }
            if r.7 { keywords["$flagged"] = true }
            return ["id": r.0, "threadId": r.1, "mailboxIds": ["inbox": true], "keywords": keywords,
                    "from": [r.2], "to": [me], "subject": r.3, "receivedAt": at(r.5),
                    "preview": r.4, "hasAttachment": r.8, "size": 2048]
        }

        func detail(_ id: String, _ thread: String, from: [String: Any], subject: String, hoursAgo: Double,
                    unread: Bool = false, text: String? = nil, html: String? = nil,
                    attachments: [[String: Any]] = [], unsubscribe: Bool = false) -> [String: Any] {
            let keywords: [String: Bool] = unread ? [:] : ["$seen": true]
            var d: [String: Any] = [
                "id": id, "threadId": thread, "mailboxIds": ["inbox": true],
                "keywords": keywords,
                "from": [from], "to": [me], "subject": subject, "receivedAt": at(hoursAgo),
                "preview": String((text ?? "A newsletter.").prefix(120)),
                "attachments": attachments,
            ]
            var values: [String: Any] = [:]
            if let text {
                d["textBody"] = [["partId": "t", "type": "text/plain"]]
                values["t"] = ["value": text]
            }
            if let html {
                d["htmlBody"] = [["partId": "h", "type": "text/html"]]
                values["h"] = ["value": html]
            }
            d["bodyValues"] = values
            if unsubscribe {
                d["header:List-Unsubscribe:asURLs"] = ["https://longshelf.example/unsubscribe"]
                d["header:List-Unsubscribe-Post:asText"] = "List-Unsubscribe=One-Click"
            }
            return d
        }

        let imani = person("Imani Okafor", "imani@fernhill.example")
        let plainThread: [[String: Any]] = [
            detail("m1a", "t1", from: me, subject: "Draft agenda for Thursday", hoursAgo: 20, text: """
            Hi Imani,

            Here is the draft agenda for Thursday. I kept it to four items so we can finish in an hour:

            1. Volunteer schedule for December
            2. Reading room hours over the holidays
            3. Budget for the spring book sale
            4. Any other business

            Could you look it over and tell me if anything is missing? I would like to send it to the group tomorrow morning.

            Thanks,
            Robin
            """),
            detail("m1b", "t1", from: imani, subject: "Re: Draft agenda for Thursday", hoursAgo: 0.6, unread: true, text: """
            Hi Robin,

            That works. I moved the budget item to the top so we don't run out of time again. Last month we spent forty minutes on the volunteer schedule and never reached the numbers.

            Two small things. Dana asked whether we can talk about the roof estimate, which could go under any other business. And the reading room question needs the caretaker's answer first, so I have asked him to reply before Wednesday: https://fernhill.example/rooms

            Send it whenever you are ready.

            Imani
            """),
        ]

        let newsletter = """
        <table width="920" cellpadding="0" cellspacing="0" style="background:#fdfaf3;font-family:Georgia,serif;">
          <tr><td style="background:#1d3b53;color:#fff;padding:28px 36px;font-size:34px;letter-spacing:1px;">THE LONG SHELF</td></tr>
          <tr><td style="padding:28px 36px;font-size:17px;line-height:1.6;color:#222;">
            <h2 style="margin:0 0 12px;font-size:26px;">Twelve books for the darkest month</h2>
            <p>Every November we ask the same question: what do you read when the light goes at four? This year's answers run from a history of lighthouses to a novel told entirely in marginal notes.</p>
            <table width="848" cellpadding="14" cellspacing="0" style="background:#f0e7d6;margin:18px 0;">
              <tr>
                <td width="33%" style="vertical-align:top;"><b>The Lamp Keepers</b><br>A century of solitary work, told through logbooks.</td>
                <td width="33%" style="vertical-align:top;"><b>Marginalia</b><br>A love story in the white space of a borrowed book.</td>
                <td width="33%" style="vertical-align:top;"><b>Salt Roads</b><br>Walking the old trade routes of the northern coast.</td>
              </tr>
            </table>
            <p>Also in this issue: a quarrel about footnotes, and <a href="https://longshelf.example/letters">letters from readers</a>.</p>
            <p style="font-size:13px;color:#666;">You are receiving this because you subscribed at longshelf.example.</p>
          </td></tr>
        </table>
        """
        let threads: [[[String: Any]]] = [
            plainThread,
            [detail("m2", "t2", from: person("The Long Shelf", "editors@longshelf.example"),
                    subject: "This week: twelve books for the darkest month, and a quarrel about footnotes",
                    hoursAgo: 2.2, unread: true, html: newsletter, unsubscribe: true)],
            [detail("m3", "t3", from: person("Mateo Reyes - mateo at brightwater.example", "relay-7f3k@relay.example"),
                    subject: "Quote for the kitchen cabinets", hoursAgo: 4.5,
                    html: "<div>Hi Robin,</div><div><br></div><div>Attached is the revised quote with the oak fronts. It is valid for thirty days. If you would like to go ahead, I can book the fitting for the second week of January.</div><div><br></div><div>Best,<br>Mateo</div>",
                    attachments: [["partId": "a1", "blobId": "demo-blob", "type": "application/pdf",
                                   "name": "Brightwater quote 1182 (revised, oak fronts).pdf", "size": 184_320,
                                   "disposition": "attachment"]])],
        ]

        func decode<T: Decodable>(_ type: T.Type, _ object: Any) -> T? {
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JMAPDate.shared.decode(T.self, from: data)
        }
        let identity: [[String: Any]] = [["id": "me", "name": "Robin Vale", "email": "robin@example.com"]]
        store.installDemo(mailboxes: decode([Mailbox].self, mailboxes) ?? [],
                          identities: decode([Identity].self, identity) ?? [],
                          messages: decode([EmailSummary].self, summaries) ?? [],
                          threads: threads.compactMap { decode([EmailDetail].self, $0) })
    }
}
