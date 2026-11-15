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

extension Error {
    /// True only when the request certainly never reached the server (no connection was made),
    /// so retrying cannot duplicate an action. Timeouts and dropped connections are *not* in
    /// this set: the server may have processed the request.
    public var requestCertainlyNotSent: Bool {
        guard let url = self as? URLError else { return false }
        switch url.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .appTransportSecurityRequiresSecureConnection:
            return true
        default:
            return false
        }
    }

    /// True when the server answered with a definite rejection (HTTP 4xx other than 408/429).
    public var isDefiniteRejection: Bool {
        guard let jmap = self as? JMAPError, case .http(let code, _) = jmap else { return false }
        return (400..<500).contains(code) && code != 408 && code != 429
    }
}

// MARK: - Transport and credentials (injectable for tests)

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse)
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession
    public init(session: URLSession) { self.session = session }

    public static func standard() -> URLSessionTransport {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSessionTransport(session: URLSession(configuration: config))
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
    public func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        try await session.upload(for: request, from: body)
    }
    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }
}

/// Supplies the bearer token for Fastmail requests: a personal API token, or OAuth tokens that refresh.
public protocol CredentialProvider: Sendable {
    func accessToken() async throws -> String
    /// Called once after a 401. Return true if a new token is now available and the request should be retried.
    func refreshAfterUnauthorized() async -> Bool
}

/// A developer API token. It never refreshes.
public struct StaticTokenCredentials: CredentialProvider {
    let token: String
    public init(token: String) { self.token = token }
    public func accessToken() async throws -> String { token }
    public func refreshAfterUnauthorized() async -> Bool { false }
}

/// Per-item outcome of a bulk Email/set update or destroy.
public struct SetOutcome: Sendable, Equatable {
    public var succeeded: Set<String> = []
    /// id → JMAP SetError type (e.g. "notFound", "forbidden").
    public var failed: [String: String] = [:]

    public init(succeeded: Set<String> = [], failed: [String: String] = [:]) {
        self.succeeded = succeeded; self.failed = failed
    }

    public var allSucceeded: Bool { failed.isEmpty }
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

    private let credentials: CredentialProvider
    private let transport: HTTPTransport
    private let sessionURL: URL
    private let lock = NSLock()
    private var _session: JMAPSession?

    public var session: JMAPSession? {
        lock.withLock { _session }
    }

    public init(credentials: CredentialProvider,
                transport: HTTPTransport = URLSessionTransport.standard(),
                sessionURL: URL = JMAPClient.fastmailSessionURL) {
        self.credentials = credentials
        self.transport = transport
        self.sessionURL = sessionURL
    }

    public convenience init(token: String, sessionURL: URL = JMAPClient.fastmailSessionURL) {
        self.init(credentials: StaticTokenCredentials(token: token), sessionURL: sessionURL)
    }

    // MARK: Session

    @discardableResult
    public func connect() async throws -> JMAPSession {
        let data = try await perform(URLRequest(url: sessionURL))
        let s = try JMAPDate.shared.decode(JMAPSession.self, from: data)
        lock.withLock { _session = s }
        return s
    }

    /// A stable identity for the signed-in account, used to namespace local storage.
    public var accountKey: String? {
        guard let s = session, let id = s.mailAccountId else { return nil }
        return "\(s.username.lowercased())|\(id)"
    }

    private func requireSession() throws -> (JMAPSession, String) {
        guard let s = session, let account = s.mailAccountId else { throw JMAPError.notConnected }
        return (s, account)
    }

    public var accountId: String? { session?.mailAccountId }

    // MARK: Raw requests

    /// Sends one JMAP request. With `throwOnMethodError` false, method-level errors come back as
    /// responses named "error" so callers can tell which part of a batch failed.
    public func call(_ calls: [Invocation],
                     using extra: [String] = [],
                     throwOnMethodError: Bool = true) async throws -> [InvocationResponse] {
        let (s, _) = try requireSession()
        let using = [JMAPCapability.core, JMAPCapability.mail] + extra
        let body: [String: Any] = [
            "using": using,
            "methodCalls": calls.map { [$0.name, $0.args, $0.id] as [Any] },
        ]
        var req = URLRequest(url: s.apiUrl)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data = try await perform(req)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = json["methodResponses"] as? [[Any]] else {
            throw JMAPError.decoding("no methodResponses")
        }
        return try responses.map { triple in
            guard triple.count == 3, let name = triple[0] as? String,
                  let args = triple[1] as? [String: Any], let id = triple[2] as? String else {
                throw JMAPError.decoding("malformed invocation")
            }
            if name == "error" && throwOnMethodError {
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
    /// Returns which messages changed and which didn't; throws only if the request itself failed.
    @discardableResult
    public func updateEmails(_ patches: [String: [String: Any]]) async throws -> SetOutcome {
        guard !patches.isEmpty else { return SetOutcome() }
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/set", ["accountId": account, "update": patches], id: "u"),
        ])
        return Self.outcome(try response(r, "u", "Email/set"), updated: true)
    }

    @discardableResult
    public func destroyEmails(_ ids: [String]) async throws -> SetOutcome {
        guard !ids.isEmpty else { return SetOutcome() }
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/set", ["accountId": account, "destroy": ids], id: "d"),
        ])
        return Self.outcome(try response(r, "d", "Email/set"), updated: false)
    }

    static func outcome(_ res: InvocationResponse, updated: Bool) -> SetOutcome {
        var o = SetOutcome()
        if updated {
            if let ok = res.args["updated"] as? [String: Any] { o.succeeded = Set(ok.keys) }
        } else if let ok = res.args["destroyed"] as? [String] {
            o.succeeded = Set(ok)
        }
        let failures = res.args[updated ? "notUpdated" : "notDestroyed"] as? [String: Any] ?? [:]
        for (id, err) in failures {
            o.failed[id] = (err as? [String: Any])?["type"] as? String ?? "error"
        }
        return o
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

    func emailObject(_ m: OutgoingMessage, draftsId: String) -> [String: Any] {
        var email: [String: Any] = [
            "mailboxIds": [draftsId: true],
            "keywords": ["$draft": true, "$seen": true],
            "from": [m.from.jsonObject],
            "to": m.to.map(\.jsonObject),
            "subject": m.subject,
            "textBody": [["partId": "text", "type": "text/plain"]],
        ]
        var values: [String: Any] = ["text": ["value": m.body]]
        if let html = m.htmlBody, !html.isEmpty {
            // With both a text and an HTML body the server builds multipart/alternative.
            email["htmlBody"] = [["partId": "html", "type": "text/html"]]
            values["html"] = ["value": html]
        }
        email["bodyValues"] = values
        if let id = m.messageId { email["messageId"] = [id] }
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

    /// Creates a draft and returns its id. It never touches an older draft: the caller removes
    /// that only after this succeeds, so a failed save can't lose the user's work.
    public func createDraft(_ m: OutgoingMessage, draftsId: String) async throws -> String {
        let (_, account) = try requireSession()
        let r = try await call([Invocation("Email/set", ["accountId": account,
                                                        "create": ["d": emailObject(m, draftsId: draftsId)]], id: "s")])
        let res = try response(r, "s", "Email/set")
        try res.checkSet()
        guard let created = res.args["created"] as? [String: Any],
              let d = created["d"] as? [String: Any], let id = d["id"] as? String else {
            throw JMAPError.decoding("draft not created")
        }
        return id
    }

    func submissionObject(_ m: OutgoingMessage, identityId: String, emailRef: String, sendAt: Date?) throws -> [String: Any] {
        var submission: [String: Any] = ["identityId": identityId, "emailId": emailRef]
        if let sendAt {
            guard (session?.maxDelayedSend ?? 0) > 0 else {
                throw JMAPError.unsupported("Scheduled send isn't enabled on this account.")
            }
            let rcpts = (m.to + m.cc + m.bcc).map { ["email": $0.email, "parameters": NSNull()] as [String: Any] }
            let mailFrom: [String: Any] = ["email": m.from.email,
                                           "parameters": ["HOLDUNTIL": JMAPDate.string(sendAt)]]
            submission["envelope"] = ["mailFrom": mailFrom, "rcptTo": rcpts] as [String: Any]
        }
        return submission
    }

    /// Creates the message (unless `existingEmailId` is given) and submits it in one request.
    /// The three results (email created, submission accepted, moved to Sent) are reported
    /// separately. Nothing else is touched: the old draft and reply keywords are follow-ups.
    public func createAndSubmit(_ m: OutgoingMessage, identityId: String, draftsId: String, sentId: String,
                                sendAt: Date?, existingEmailId: String? = nil) async throws -> SubmitResponse {
        let (_, account) = try requireSession()
        let onSuccess: [String: Any] = [
            "mailboxIds/\(draftsId)": NSNull(),
            "mailboxIds/\(sentId)": true,
            "keywords/$draft": NSNull(),
        ]
        var calls: [Invocation] = []
        if existingEmailId == nil {
            calls.append(Invocation("Email/set", ["accountId": account,
                                                  "create": ["msg": emailObject(m, draftsId: draftsId)]], id: "e"))
        }
        let ref = existingEmailId ?? "#msg"
        calls.append(Invocation("EmailSubmission/set", [
            "accountId": account,
            "create": ["sub": try submissionObject(m, identityId: identityId, emailRef: ref, sendAt: sendAt)],
            "onSuccessUpdateEmail": ["#sub": onSuccess],
        ], id: "s"))
        let r = try await call(calls, using: [JMAPCapability.submission], throwOnMethodError: false)
        return SubmitResponse.parse(r, existingEmailId: existingEmailId)
    }

    /// Looks for a message we created, by the Message-ID we gave it, and any submission of it.
    public func findSent(messageId: String) async throws -> SendReconciliation {
        let (_, account) = try requireSession()
        let r = try await call([
            Invocation("Email/query", ["accountId": account,
                                       "filter": ["header": ["Message-ID", messageId]],
                                       "limit": 5], id: "q"),
            Invocation("Email/get", ["accountId": account,
                                     "#ids": Invocation.ref("q", "Email/query", "/ids"),
                                     "properties": ["id", "mailboxIds", "keywords"]], id: "g"),
        ])
        let found = (try response(r, "g", "Email/get").args["list"] as? [[String: Any]]) ?? []
        let emailIds = found.compactMap { $0["id"] as? String }
        guard !emailIds.isEmpty else { return SendReconciliation(emailIds: [], submissions: [], inSent: false) }
        let r2 = try await call([
            Invocation("EmailSubmission/query", ["accountId": account,
                                                 "filter": ["emailIds": emailIds], "limit": 10], id: "sq"),
            Invocation("EmailSubmission/get", ["accountId": account,
                                               "#ids": Invocation.ref("sq", "EmailSubmission/query", "/ids"),
                                               "properties": ["id", "emailId", "undoStatus"]], id: "sg"),
        ], using: [JMAPCapability.submission])
        let subs = (try response(r2, "sg", "EmailSubmission/get").args["list"] as? [[String: Any]]) ?? []
        let isDraft = found.contains { (($0["keywords"] as? [String: Bool])?["$draft"]) == true }
        return SendReconciliation(
            emailIds: emailIds,
            submissions: subs.compactMap { s in
                guard let id = s["id"] as? String else { return nil }
                return SendReconciliation.Submission(id: id, undoStatus: s["undoStatus"] as? String ?? "unknown")
            },
            inSent: !isDraft)
    }

    /// After a confirmed submission: remove the user's old draft and mark the original
    /// message answered or forwarded. Each part is reported on its own.
    public func completeSend(oldDraftId: String?, originalEmailId: String?, keyword: String?) async throws -> FollowUpResult {
        let (_, account) = try requireSession()
        var args: [String: Any] = ["accountId": account]
        if let oldDraftId { args["destroy"] = [oldDraftId] }
        if let originalEmailId, let keyword { args["update"] = [originalEmailId: ["keywords/\(keyword)": true]] }
        guard args.count > 1 else { return FollowUpResult(draftRemoved: nil, keywordSet: nil) }
        let r = try await call([Invocation("Email/set", args, id: "f")])
        let res = try response(r, "f", "Email/set")
        let destroyed = Set((res.args["destroyed"] as? [String]) ?? [])
        let updated = Set(((res.args["updated"] as? [String: Any]) ?? [:]).keys)
        let draftGone = oldDraftId.map { id in
            destroyed.contains(id) || ((res.args["notDestroyed"] as? [String: Any])?[id] as? [String: Any])?["type"] as? String == "notFound"
        }
        return FollowUpResult(draftRemoved: draftGone,
                              keywordSet: originalEmailId.map { updated.contains($0) })
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
        let body = try await perform(req, uploading: data)
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
        return try await perform(URLRequest(url: url))
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
                        req.setValue("Bearer \(try await self.credentials.accessToken())", forHTTPHeaderField: "Authorization")
                        let (bytes, response) = try await self.transport.bytes(for: req)
                        if (response as? HTTPURLResponse)?.statusCode == 401 {
                            _ = await self.credentials.refreshAfterUnauthorized()
                        }
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

    // MARK: Contacts (JMAP for Contacts, RFC 9610)

    /// Every name and address in the user's Fastmail address books. Empty when the session
    /// doesn't offer contacts (for example, a token without the contacts scope).
    public func contacts() async throws -> [EmailAddress] {
        guard let s = session, s.capabilities[JMAPCapability.contacts] != nil,
              let account = s.primaryAccounts[JMAPCapability.contacts] ?? s.mailAccountId else { return [] }
        let r = try await call([
            Invocation("ContactCard/get", ["accountId": account, "ids": NSNull(),
                                           "properties": ["id", "name", "emails"]], id: "c"),
        ], using: [JMAPCapability.contacts])
        let list = (try response(r, "c", "ContactCard/get").args["list"] as? [[String: Any]]) ?? []
        return ContactCards.addresses(from: list)
    }

    // MARK: Plumbing

    /// Adds the bearer token, sends, and retries once after a 401 if the credentials refreshed.
    private func perform(_ request: URLRequest, uploading body: Data? = nil) async throws -> Data {
        var attempt = 0
        while true {
            var req = request
            req.setValue("Bearer \(try await credentials.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = body == nil
                ? try await transport.data(for: req)
                : try await transport.upload(for: req, from: body!)
            if let http = response as? HTTPURLResponse, http.statusCode == 401, attempt == 0,
               await credentials.refreshAfterUnauthorized() {
                attempt += 1
                continue
            }
            try check(response, data)
            return data
        }
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw JMAPError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - Send results

public struct SubmitResponse: Sendable, Equatable {
    public var emailId: String?
    public var emailError: String?
    public var submissionId: String?
    public var submissionError: String?
    /// nil when the server didn't report the follow-up move.
    public var movedToSent: Bool?

    public var accepted: Bool { submissionId != nil }

    public init(emailId: String? = nil, emailError: String? = nil, submissionId: String? = nil,
                submissionError: String? = nil, movedToSent: Bool? = nil) {
        self.emailId = emailId; self.emailError = emailError; self.submissionId = submissionId
        self.submissionError = submissionError; self.movedToSent = movedToSent
    }

    static func parse(_ r: [InvocationResponse], existingEmailId: String?) -> SubmitResponse {
        var out = SubmitResponse(emailId: existingEmailId)
        func setError(_ res: InvocationResponse, _ key: String, _ cid: String) -> String? {
            guard let failures = res.args[key] as? [String: Any], let err = failures[cid] as? [String: Any] else { return nil }
            return [err["type"] as? String, err["description"] as? String].compactMap { $0 }.joined(separator: ": ")
        }
        for res in r {
            switch (res.name, res.id) {
            case ("Email/set", "e"):
                out.emailId = ((res.args["created"] as? [String: Any])?["msg"] as? [String: Any])?["id"] as? String
                out.emailError = setError(res, "notCreated", "msg")
            case ("EmailSubmission/set", "s"):
                out.submissionId = ((res.args["created"] as? [String: Any])?["sub"] as? [String: Any])?["id"] as? String
                out.submissionError = setError(res, "notCreated", "sub")
            case ("Email/set", "s"):
                // The implicit update from onSuccessUpdateEmail.
                let updated = (res.args["updated"] as? [String: Any]) ?? [:]
                out.movedToSent = out.emailId.map { updated.keys.contains($0) } ?? !updated.isEmpty
            case ("error", "e"):
                out.emailError = res.args["type"] as? String ?? "error"
            case ("error", "s"):
                out.submissionError = res.args["type"] as? String ?? "error"
            default:
                break
            }
        }
        if out.accepted, out.movedToSent == nil { out.movedToSent = false }
        return out
    }
}

public struct SendReconciliation: Sendable, Equatable {
    public struct Submission: Sendable, Equatable {
        public let id: String
        public let undoStatus: String   // "pending" (scheduled or in its undo window), "final", "canceled"
    }
    public let emailIds: [String]
    public let submissions: [Submission]
    public let inSent: Bool

    public init(emailIds: [String], submissions: [Submission], inSent: Bool) {
        self.emailIds = emailIds; self.submissions = submissions; self.inSent = inSent
    }

    /// A live submission exists: the message was sent (or is scheduled to be).
    public var wasSubmitted: Bool { submissions.contains { $0.undoStatus != "canceled" } || inSent }
}

public struct FollowUpResult: Sendable, Equatable {
    /// nil = nothing to do.
    public let draftRemoved: Bool?
    public let keywordSet: Bool?

    public var allOK: Bool { draftRemoved != false && keywordSet != false }

    public init(draftRemoved: Bool?, keywordSet: Bool?) {
        self.draftRemoved = draftRemoved; self.keywordSet = keywordSet
    }
}

/// Reads names and addresses out of JSContact cards (RFC 9553).
public enum ContactCards {
    public static func addresses(from cards: [[String: Any]]) -> [EmailAddress] {
        var out: [EmailAddress] = []
        var seen = Set<String>()
        for card in cards {
            let name = displayName(card["name"] as? [String: Any])
            let emails = (card["emails"] as? [String: Any]) ?? [:]
            for (_, value) in emails.sorted(by: { $0.key < $1.key }) {
                guard let address = (value as? [String: Any])?["address"] as? String,
                      address.contains("@") else { continue }
                if seen.insert(address.lowercased()).inserted {
                    out.append(EmailAddress(name: name, email: address))
                }
            }
        }
        return out
    }

    static func displayName(_ name: [String: Any]?) -> String? {
        guard let name else { return nil }
        if let full = name["full"] as? String, !full.isEmpty { return full }
        let parts = (name["components"] as? [[String: Any]] ?? []).filter {
            ["given", "surname", "given2"].contains($0["kind"] as? String ?? "")
        }.compactMap { $0["value"] as? String }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Outgoing message

public struct OutgoingAttachment: Codable, Hashable, Sendable, Identifiable {
    public var id: String { blobId }
    public let blobId: String
    public let name: String
    public let type: String
    public let size: Int

    public init(blobId: String, name: String, type: String, size: Int) {
        self.blobId = blobId; self.name = name; self.type = type; self.size = size
    }
}

public struct OutgoingMessage: Codable, Sendable, Equatable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    /// Plain-text body (always sent).
    public var body: String
    /// Formatted body, sent alongside the plain text when present.
    public var htmlBody: String?
    public var inReplyTo: String?
    public var references: [String]
    public var attachments: [OutgoingAttachment]
    public var replyingToEmailId: String?
    public var isForward: Bool
    /// A Message-ID (without angle brackets) chosen by the app, so a send can be found again
    /// on the server if the connection drops.
    public var messageId: String?

    public init(from: EmailAddress, to: [EmailAddress], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String, body: String, htmlBody: String? = nil, inReplyTo: String? = nil,
                references: [String] = [], attachments: [OutgoingAttachment] = [],
                replyingToEmailId: String? = nil, isForward: Bool = false, messageId: String? = nil) {
        self.from = from; self.to = to; self.cc = cc; self.bcc = bcc
        self.subject = subject; self.body = body; self.htmlBody = htmlBody
        self.inReplyTo = inReplyTo; self.references = references
        self.attachments = attachments
        self.replyingToEmailId = replyingToEmailId; self.isForward = isForward
        self.messageId = messageId
    }

    public static func makeMessageId(senderDomain: String) -> String {
        "veerymail.\(UUID().uuidString.lowercased())@\(senderDomain.isEmpty ? "veerymail.local" : senderDomain)"
    }
}

extension EmailAddress {
    var jsonObject: [String: Any] {
        var o: [String: Any] = ["email": email]
        if let name, !name.isEmpty { o["name"] = name }
        return o
    }
}
