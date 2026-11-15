import Foundation

public enum JMAPError: LocalizedError {
    case notConnected
    case http(Int, String)
    case method(String, String?)
    case setFailed(String)
    case decoding(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to Fastmail."
        case .http(401, _): return "Fastmail rejected the API token. Create a new one in Fastmail → Settings → Privacy & Security → Connected apps & API tokens → Manage API tokens."
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .method(let type, let desc): return "JMAP error \(type)\(desc.map { ": \($0)" } ?? "")"
        case .setFailed(let msg): return msg
        case .decoding(let msg): return "Unexpected response: \(msg)"
        case .unsupported(let msg): return msg
        }
    }
}

/// One JMAP method invocation: [name, arguments, callId].
public struct Invocation {
    public let name: String
    public let args: [String: Any]
    public let id: String

    public init(_ name: String, _ args: [String: Any], id: String) {
        self.name = name
        self.args = args
        self.id = id
    }

    /// Back-reference to the result of a previous call (RFC 8620 §3.7).
    public static func ref(_ callId: String, _ name: String, _ path: String) -> [String: Any] {
        ["resultOf": callId, "name": name, "path": path]
    }
}

public struct InvocationResponse {
    public let name: String
    public let args: [String: Any]
    public let id: String

    public func decode<T: Decodable>(_ type: T.Type, _ key: String) throws -> T {
        guard let value = args[key] else { throw JMAPError.decoding("missing \(key) in \(name)") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        do {
            return try JMAPDate.shared.decode(T.self, from: data)
        } catch {
            throw JMAPError.decoding("\(name).\(key): \(error)")
        }
    }

    public func string(_ key: String) -> String? { args[key] as? String }
    public func int(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue }

    /// Throws if a /set call reported notCreated / notUpdated / notDestroyed.
    public func checkSet(ignoring: Set<String> = []) throws {
        for key in ["notCreated", "notUpdated", "notDestroyed"] where !ignoring.contains(key) {
            if let failures = args[key] as? [String: Any], let first = failures.first {
                let err = first.value as? [String: Any]
                let type = err?["type"] as? String ?? "error"
                let desc = err?["description"] as? String ?? ""
                throw JMAPError.setFailed("\(name) \(key) \(first.key): \(type) \(desc)")
            }
        }
    }
}

public struct QueryPage {
    public let emails: [EmailSummary]
    public let total: Int?
    public let position: Int
    public let emailState: String?
}

public struct EmailChanges {
    public let changed: [String]   // created + updated
    public let destroyed: [String]
    public let newState: String
    public let hasMoreChanges: Bool
}

/// Thin, dependency-free JMAP client tuned for Fastmail.
/// Every UI action is a single HTTP round trip: method calls are batched
/// and chained with back-references wherever possible.
public final class JMAPClient: @unchecked Sendable {
    public static let fastmailSessionURL = URL(string: "https://api.fastmail.com/jmap/session")!

    private let token: String
    private let http: URLSession
    private let sessionURL: URL
    private let lock = NSLock()
    private var _session: JMAPSession?

    public var session: JMAPSession? {
        lock.lock(); defer { lock.unlock() }
        return _session
    }

    public init(token: String, sessionURL: URL = JMAPClient.fastmailSessionURL) {
        self.token = token
        self.sessionURL = sessionURL
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        self.http = URLSession(configuration: config)
    }

    // MARK: Session

    @discardableResult
    public func connect() async throws -> JMAPSession {
        var req = URLRequest(url: sessionURL)
        authorize(&req)
        let (data, response) = try await http.data(for: req)
        try check(response, data)
        let s = try JMAPDate.shared.decode(JMAPSession.self, from: data)
        lock.lock(); _session = s; lock.unlock()
        return s
    }

    private func requireSession() throws -> (JMAPSession, String) {
        guard let s = session, let account = s.mailAccountId else { throw JMAPError.notConnected }
        return (s, account)
    }

    public var accountId: String? { session?.mailAccountId }

    // MARK: Raw requests

    public func call(_ calls: [Invocation],
                     using extra: [String] = []) async throws -> [InvocationResponse] {
        let (s, _) = try requireSession()
        let using = [JMAPCapability.core, JMAPCapability.mail] + extra
        let body: [String: Any] = [
            "using": using,
            "methodCalls": calls.map { [$0.name, $0.args, $0.id] as [Any] },
        ]
        var req = URLRequest(url: s.apiUrl)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await http.data(for: req)
        try check(response, data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = json["methodResponses"] as? [[Any]] else {
            throw JMAPError.decoding("no methodResponses")
        }
        return try responses.map { triple in
            guard triple.count == 3, let name = triple[0] as? String,
                  let args = triple[1] as? [String: Any], let id = triple[2] as? String else {
                throw JMAPError.decoding("malformed invocation")
            }
            if name == "error" {
                throw JMAPError.method(args["type"] as? String ?? "unknown", args["description"] as? String)
            }
            return InvocationResponse(name: name, args: args, id: id)
        }
    }

    private func response(_ responses: [InvocationResponse], _ id: String, _ name: String) throws -> InvocationResponse {
        guard let r = responses.last(where: { $0.id == id && $0.name == name }) else {
            throw JMAPError.decoding("missing response \(name)#\(id)")
        }
        return r
    }

    // MARK: Mailboxes

    public func mailboxes() async throws -> (mailboxes: [Mailbox], state: String?) {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Mailbox/get", ["accountId": account, "ids": NSNull(),
                                       "properties": Mailbox.properties], id: "m"),
        ])
        let res = try response(r, "m", "Mailbox/get")
        return (try res.decode([Mailbox].self, "list"), res.string("state"))
    }

    public func createMailbox(name: String, role: String? = nil) async throws -> String {
        let (_, account) = try requireSession()
        var mb: [String: Any] = ["name": name]
        if let role { mb["role"] = role }
        let r = try await call([
            Invocation("Mailbox/set", ["accountId": account, "create": ["new": mb]], id: "c"),
        ])
        let res = try response(r, "c", "Mailbox/set")
        try res.checkSet()
        guard let created = res.args["created"] as? [String: Any],
              let new = created["new"] as? [String: Any], let id = new["id"] as? String else {
            throw JMAPError.decoding("Mailbox/set created")
        }
        return id
    }

    // MARK: Email list

    /// Query + fetch in one round trip. `collapseThreads` gives a conversation list.
    public func queryEmails(filter: [String: Any],
                            position: Int = 0,
                            limit: Int = 60,
                            collapseThreads: Bool = true,
                            oldestFirst: Bool = false) async throws -> QueryPage {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/query", [
                "accountId": account,
                "filter": filter,
                "sort": [["property": "receivedAt", "isAscending": oldestFirst] as [String: Any]],
                "collapseThreads": collapseThreads,
                "position": position,
                "limit": limit,
                "calculateTotal": position == 0,
            ], id: "q"),
            Invocation("Email/get", [
                "accountId": account,
                "#ids": Invocation.ref("q", "Email/query", "/ids"),
                "properties": EmailSummary.properties,
            ], id: "g"),
        ])
        let q = try response(r, "q", "Email/query")
        let g = try response(r, "g", "Email/get")
        return QueryPage(emails: try g.decode([EmailSummary].self, "list"),
                         total: q.int("total"),
                         position: q.int("position") ?? position,
                         emailState: g.string("state"))
    }

    /// Arrival time and filing for many messages, in one round trip (for statistics).
    public func mailMeta(filter: [String: Any], limit: Int) async throws -> [MailMeta] {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/query", [
                "accountId": account, "filter": filter,
                "sort": [["property": "receivedAt", "isAscending": false] as [String: Any]],
                "collapseThreads": false, "limit": limit,
            ], id: "q"),
            Invocation("Email/get", [
                "accountId": account,
                "#ids": Invocation.ref("q", "Email/query", "/ids"),
                "properties": MailMeta.properties,
            ], id: "g"),
        ])
        return try response(r, "g", "Email/get").decode([MailMeta].self, "list")
    }

    /// Your recently sent messages plus every message in their conversations, in one round trip.
    public func sentWithThreads(sentMailboxId: String, since: Date, limit: Int = 100)
        async throws -> (sent: [EmailSummary], threadMail: [EmailSummary]) {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/query", [
                "accountId": account,
                "filter": ["inMailbox": sentMailboxId, "after": JMAPDate.string(since)],
                "sort": [["property": "receivedAt", "isAscending": false] as [String: Any]],
                "collapseThreads": false, "limit": limit,
            ], id: "q"),
            Invocation("Email/get", [
                "accountId": account,
                "#ids": Invocation.ref("q", "Email/query", "/ids"),
                "properties": EmailSummary.properties,
            ], id: "s"),
            Invocation("Thread/get", [
                "accountId": account,
                "#ids": Invocation.ref("s", "Email/get", "/list/*/threadId"),
            ], id: "t"),
            Invocation("Email/get", [
                "accountId": account,
                "#ids": Invocation.ref("t", "Thread/get", "/list/*/emailIds"),
                "properties": EmailSummary.properties,
            ], id: "g"),
        ])
        return (try response(r, "s", "Email/get").decode([EmailSummary].self, "list"),
                try response(r, "g", "Email/get").decode([EmailSummary].self, "list"))
    }

    /// Messages scheduled with Send Later that haven't gone out yet.
    public func scheduledSendCount() async throws -> Int {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("EmailSubmission/query", [
                "accountId": account, "filter": ["undoStatus": "pending"],
                "calculateTotal": true, "limit": 50,
            ], id: "q"),
        ], using: [JMAPCapability.submission])
        let q = try response(r, "q", "EmailSubmission/query")
        return q.int("total") ?? ((q.args["ids"] as? [String])?.count ?? 0)
    }

    public func summaries(ids: [String]) async throws -> [EmailSummary] {
        guard !ids.isEmpty else { return [] }
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/get", ["accountId": account, "ids": ids,
                                     "properties": EmailSummary.properties], id: "g"),
        ])
        return try response(r, "g", "Email/get").decode([EmailSummary].self, "list")
    }

    /// Every message in the given conversations, headers only, in one round trip.
    public func summaries(inThreads threadIds: [String]) async throws -> [EmailSummary] {
        guard !threadIds.isEmpty else { return [] }
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Thread/get", ["accountId": account, "ids": threadIds], id: "t"),
            Invocation("Email/get", [
                "accountId": account,
                "#ids": Invocation.ref("t", "Thread/get", "/list/*/emailIds"),
                "properties": EmailSummary.properties,
            ], id: "g"),
        ])
        return try response(r, "g", "Email/get").decode([EmailSummary].self, "list")
    }

    /// Delta sync since a known Email state (RFC 8620 §5.2).
    public func emailChanges(since state: String) async throws -> EmailChanges {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/changes", ["accountId": account, "sinceState": state,
                                         "maxChanges": 500], id: "c"),
        ])
        let c = try response(r, "c", "Email/changes")
        let created = (c.args["created"] as? [String]) ?? []
        let updated = (c.args["updated"] as? [String]) ?? []
        return EmailChanges(changed: created + updated,
                            destroyed: (c.args["destroyed"] as? [String]) ?? [],
                            newState: c.string("newState") ?? state,
                            hasMoreChanges: (c.args["hasMoreChanges"] as? Bool) ?? false)
    }

    // MARK: Reading

    /// Every message in a conversation, oldest first, with bodies.
    public func thread(_ threadId: String) async throws -> [EmailDetail] {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Thread/get", ["accountId": account, "ids": [threadId]], id: "t"),
            Invocation("Email/get", [
                "accountId": account,
                "#ids": Invocation.ref("t", "Thread/get", "/list/*/emailIds"),
                "properties": EmailDetail.properties,
                "fetchHTMLBodyValues": true,
                "fetchTextBodyValues": true,
            ], id: "g"),
        ])
        let emails = try response(r, "g", "Email/get").decode([EmailDetail].self, "list")
        return emails.sorted { $0.receivedAt < $1.receivedAt }
    }

    public func details(ids: [String]) async throws -> [EmailDetail] {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/get", [
                "accountId": account, "ids": ids,
                "properties": EmailDetail.properties,
                "fetchHTMLBodyValues": true, "fetchTextBodyValues": true,
            ], id: "g"),
        ])
        return try response(r, "g", "Email/get").decode([EmailDetail].self, "list")
    }

    // MARK: Mutations

    /// Apply JMAP patch objects, e.g. ["keywords/$seen": true] or ["mailboxIds/abc": NSNull()].
    public func updateEmails(_ patches: [String: [String: Any]]) async throws {
        guard !patches.isEmpty else { return }
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/set", ["accountId": account, "update": patches], id: "u"),
        ])
        try response(r, "u", "Email/set").checkSet()
    }

    public func destroyEmails(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/set", ["accountId": account, "destroy": ids], id: "d"),
        ])
        try response(r, "d", "Email/set").checkSet()
    }

    /// Ids of every message in the given threads (so actions apply to whole conversations).
    public func emailIds(inThreads threadIds: [String]) async throws -> [String] {
        guard !threadIds.isEmpty else { return [] }
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Thread/get", ["accountId": account, "ids": threadIds], id: "t"),
        ])
        let list = (try response(r, "t", "Thread/get").args["list"] as? [[String: Any]]) ?? []
        return list.flatMap { ($0["emailIds"] as? [String]) ?? [] }
    }

    // MARK: Identities & sending

    public func identities() async throws -> [Identity] {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Identity/get", ["accountId": account, "ids": NSNull()], id: "i"),
        ], using: [JMAPCapability.submission])
        return try response(r, "i", "Identity/get").decode([Identity].self, "list")
    }

    private func emailObject(_ m: OutgoingMessage, draftsId: String) -> [String: Any] {
        var email: [String: Any] = [
            "mailboxIds": [draftsId: true],
            "keywords": ["$draft": true, "$seen": true],
            "from": [m.from.jsonObject],
            "to": m.to.map(\.jsonObject),
            "subject": m.subject,
            "textBody": [["partId": "text", "type": "text/plain"]],
            "bodyValues": ["text": ["value": m.body]],
        ]
        if !m.cc.isEmpty { email["cc"] = m.cc.map(\.jsonObject) }
        if !m.bcc.isEmpty { email["bcc"] = m.bcc.map(\.jsonObject) }
        if let irt = m.inReplyTo { email["inReplyTo"] = [irt] }
        if !m.references.isEmpty { email["references"] = m.references }
        if !m.attachments.isEmpty {
            email["attachments"] = m.attachments.map {
                ["blobId": $0.blobId, "type": $0.type, "name": $0.name, "disposition": "attachment"]
            }
        }
        return email
    }

    /// Saves (or replaces) a draft. Returns the new draft id.
    public func saveDraft(_ m: OutgoingMessage, draftsId: String, replacing oldId: String?) async throws -> String {
        let (_, account) = try requireSession()
        var args: [String: Any] = ["accountId": account,
                                   "create": ["d": emailObject(m, draftsId: draftsId)]]
        if let oldId { args["destroy"] = [oldId] }
        let r = try await call([Invocation("Email/set", args, id: "s")])
        let res = try response(r, "s", "Email/set")
        try res.checkSet(ignoring: ["notDestroyed"])
        guard let created = res.args["created"] as? [String: Any],
              let d = created["d"] as? [String: Any], let id = d["id"] as? String else {
            throw JMAPError.decoding("draft not created")
        }
        return id
    }

    /// Creates the message and submits it in one request. On success Fastmail moves it
    /// from Drafts to Sent. `sendAt` uses SMTP FUTURERELEASE (HOLDUNTIL) for scheduled send.
    public func send(_ m: OutgoingMessage, identityId: String,
                     draftsId: String, sentId: String,
                     replacingDraft oldDraftId: String? = nil,
                     sendAt: Date? = nil) async throws {
        let (s, account) = try requireSession()
        var setArgs: [String: Any] = ["accountId": account,
                                      "create": ["msg": emailObject(m, draftsId: draftsId)]]
        if let oldDraftId { setArgs["destroy"] = [oldDraftId] }

        var submission: [String: Any] = ["identityId": identityId, "emailId": "#msg"]
        if let sendAt {
            guard s.maxDelayedSend > 0 else { throw JMAPError.unsupported("Scheduled send isn't enabled on this account.") }
            let rcpts = (m.to + m.cc + m.bcc).map { ["email": $0.email, "parameters": NSNull()] as [String: Any] }
            let mailFrom: [String: Any] = ["email": m.from.email,
                                           "parameters": ["HOLDUNTIL": JMAPDate.string(sendAt)]]
            submission["envelope"] = ["mailFrom": mailFrom, "rcptTo": rcpts] as [String: Any]
        }

        let onSuccess: [String: Any] = [
            "mailboxIds/\(draftsId)": NSNull(),
            "mailboxIds/\(sentId)": true,
            "keywords/$draft": NSNull(),
        ]
        var answered: [String: [String: Any]] = [:]
        if let original = m.replyingToEmailId {
            answered[original] = [m.isForward ? "keywords/$forwarded" : "keywords/$answered": true]
        }

        var calls = [
            Invocation("Email/set", setArgs, id: "e"),
            Invocation("EmailSubmission/set", [
                "accountId": account,
                "create": ["sub": submission],
                "onSuccessUpdateEmail": ["#sub": onSuccess],
            ], id: "s"),
        ]
        if !answered.isEmpty {
            calls.append(Invocation("Email/set", ["accountId": account, "update": answered], id: "a"))
        }
        let r = try await call(calls, using: [JMAPCapability.submission])
        try response(r, "e", "Email/set").checkSet(ignoring: ["notDestroyed"])
        try response(r, "s", "EmailSubmission/set").checkSet()
    }

    // MARK: Blobs

    public func upload(_ data: Data, type: String) async throws -> UploadResult {
        let (s, account) = try requireSession()
        guard let url = URL(string: s.uploadUrl.replacingOccurrences(of: "{accountId}", with: account)) else {
            throw JMAPError.decoding("uploadUrl")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(type, forHTTPHeaderField: "Content-Type")
        authorize(&req)
        let (body, response) = try await http.upload(for: req, from: data)
        try check(response, body)
        return try JSONDecoder().decode(UploadResult.self, from: body)
    }

    public func downloadURL(blobId: String, name: String, type: String) -> URL? {
        guard let s = session, let account = s.mailAccountId else { return nil }
        let enc: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&="))) ?? $0
        }
        let str = s.downloadUrl
            .replacingOccurrences(of: "{accountId}", with: enc(account))
            .replacingOccurrences(of: "{blobId}", with: enc(blobId))
            .replacingOccurrences(of: "{name}", with: enc(name))
            .replacingOccurrences(of: "{type}", with: enc(type))
        return URL(string: str)
    }

    public func download(blobId: String, name: String, type: String) async throws -> Data {
        guard let url = downloadURL(blobId: blobId, name: name, type: type) else { throw JMAPError.notConnected }
        var req = URLRequest(url: url)
        authorize(&req)
        let (data, response) = try await http.data(for: req)
        try check(response, data)
        return data
    }

    // MARK: Fastmail Masked Email

    public func maskedEmails() async throws -> [MaskedEmail] {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("MaskedEmail/get", ["accountId": account, "ids": NSNull()], id: "m"),
        ], using: [JMAPCapability.maskedEmail])
        return try response(r, "m", "MaskedEmail/get").decode([MaskedEmail].self, "list")
    }

    public func createMaskedEmail(forDomain: String, description: String) async throws -> MaskedEmail {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("MaskedEmail/set", ["accountId": account, "create": ["new": [
                "state": "enabled", "forDomain": forDomain, "description": description,
            ]]], id: "m"),
        ], using: [JMAPCapability.maskedEmail])
        let res = try response(r, "m", "MaskedEmail/set")
        try res.checkSet()
        guard let created = res.args["created"] as? [String: Any],
              let obj = created["new"] as? [String: Any],
              let id = obj["id"] as? String, let email = obj["email"] as? String else {
            throw JMAPError.decoding("MaskedEmail/set created")
        }
        return MaskedEmail(id: id, email: email, state: "enabled", forDomain: forDomain,
                           description: description, createdAt: Date(), lastMessageAt: nil)
    }

    public func setMaskedEmailState(id: String, state: String) async throws {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("MaskedEmail/set", ["accountId": account, "update": [id: ["state": state]]], id: "m"),
        ], using: [JMAPCapability.maskedEmail])
        try response(r, "m", "MaskedEmail/set").checkSet()
    }

    // MARK: Push (JMAP EventSource, RFC 8620 §7.3)

    /// Emits the set of changed data types ("Email", "Mailbox", ...) for the mail account.
    /// Reconnects automatically with backoff until the consuming task is cancelled.
    public func pushEvents() -> AsyncStream<Set<String>> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                var backoff: UInt64 = 1
                var connectedBefore = false
                while !Task.isCancelled {
                    guard let self, let s = self.session, let account = s.mailAccountId,
                          let url = URL(string: s.eventSourceUrl
                            .replacingOccurrences(of: "{types}", with: "*")
                            .replacingOccurrences(of: "{closeafter}", with: "no")
                            .replacingOccurrences(of: "{ping}", with: "60")) else { break }
                    do {
                        var req = URLRequest(url: url)
                        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        req.timeoutInterval = 300
                        self.authorize(&req)
                        let (bytes, response) = try await self.http.bytes(for: req)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JMAPError.http(0, "eventsource") }
                        backoff = 1
                        // After a dropped connection (sleep, network change) changes may have been
                        // missed, so ask for a sync as soon as the stream is back.
                        if connectedBefore { continuation.yield(["Email", "Mailbox"]) }
                        connectedBefore = true
                        var event = "", data = ""
                        for try await line in bytes.lines {
                            if line.hasPrefix("event:") {
                                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:") {
                                data += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            }
                            // AsyncLineSequence drops empty lines, so dispatch on each data line.
                            if !data.isEmpty, event == "state" || event.isEmpty {
                                if let types = Self.changedTypes(data, account: account), !types.isEmpty {
                                    continuation.yield(types)
                                }
                                event = ""; data = ""
                            } else if !data.isEmpty {
                                event = ""; data = "" // ping or unknown event
                            }
                        }
                    } catch {
                        if Task.isCancelled { break }
                    }
                    try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                    backoff = min(backoff * 2, 60)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func changedTypes(_ json: String, account: String) -> Set<String>? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let changed = obj["changed"] as? [String: Any],
              let types = changed[account] as? [String: Any] else { return nil }
        return Set(types.keys)
    }

    // MARK: Unsubscribe (never sends Fastmail credentials)

    public static func oneClickUnsubscribe(_ url: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) else {
            throw JMAPError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "unsubscribe failed")
        }
    }

    // MARK: Plumbing

    private func authorize(_ req: inout URLRequest) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw JMAPError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Outgoing message

public struct OutgoingAttachment: Hashable, Sendable, Identifiable {
    public var id: String { blobId }
    public let blobId: String
    public let name: String
    public let type: String
    public let size: Int

    public init(blobId: String, name: String, type: String, size: Int) {
        self.blobId = blobId; self.name = name; self.type = type; self.size = size
    }
}

public struct OutgoingMessage: Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: String
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [OutgoingAttachment]
    public var replyingToEmailId: String?
    public var isForward: Bool

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String, body: String, inReplyTo: String? = nil, references: [String] = [],
                attachments: [OutgoingAttachment] = [], replyingToEmailId: String? = nil, isForward: Bool = false) {
        self.from = from; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.body = body
        self.inReplyTo = inReplyTo; self.references = references
        self.attachments = attachments
        self.replyingToEmailId = replyingToEmailId; self.isForward = isForward
    }
}

extension EmailAddress {
    var jsonObject: [String: Any] {
        var o: [String: Any] = ["email": email]
        if let name, !name.isEmpty { o["name"] = name }
        return o
    }
}
