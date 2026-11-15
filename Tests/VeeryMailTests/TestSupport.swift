import Foundation
@testable import VeeryMailCore

/// Answers HTTP requests from a handler and records them. No network.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    typealias Handler = (URLRequest, Int) throws -> (Int, [String: String], Data)
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let index: Int = lock.withLock { requests.append(request); return requests.count - 1 }
        let (status, headers, body) = try handler(request, index)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (body, response)
    }

    func upload(for request: URLRequest, from body: Data) async throws -> (Data, URLResponse) {
        var r = request; r.httpBody = body
        return try await data(for: r)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        throw URLError(.unsupportedURL)
    }

    var count: Int { lock.withLock { requests.count } }

    static func json(_ object: Any, status: Int = 200) -> (Int, [String: String], Data) {
        (status, ["Content-Type": "application/json"], try! JSONSerialization.data(withJSONObject: object))
    }
}

func bodyJSON(_ request: URLRequest) -> [String: Any] {
    guard let data = request.httpBody else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func formBody(_ request: URLRequest) -> [String: String] {
    guard let data = request.httpBody, let text = String(data: data, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}

let sessionJSON: [String: Any] = [
    "username": "robin@example.com",
    "apiUrl": "https://api.example.test/jmap/api/",
    "downloadUrl": "https://api.example.test/dl/{accountId}/{blobId}/{name}?type={type}",
    "uploadUrl": "https://api.example.test/ul/{accountId}/",
    "eventSourceUrl": "https://api.example.test/es?types={types}",
    "state": "s1",
    "capabilities": ["urn:ietf:params:jmap:core": [:], "urn:ietf:params:jmap:contacts": [:]],
    "primaryAccounts": ["urn:ietf:params:jmap:mail": "acc", "urn:ietf:params:jmap:contacts": "acc"],
    "accounts": ["acc": ["name": "robin", "isPersonal": true,
                         "accountCapabilities": ["urn:ietf:params:jmap:submission": ["maxDelayedSend": 86400]]]],
]

/// Builds a JMAP client whose API calls are answered by `methodResponses(calls)`.
func makeClient(_ respond: @escaping ([[Any]]) -> [[Any]]) async throws -> (JMAPClient, MockTransport) {
    let transport = MockTransport { request, _ in
        if request.url!.path.hasSuffix("/session") || request.url!.absoluteString.contains("session") {
            return MockTransport.json(sessionJSON)
        }
        let calls = bodyJSON(request)["methodCalls"] as? [[Any]] ?? []
        return MockTransport.json(["methodResponses": respond(calls), "sessionState": "s1"])
    }
    let client = JMAPClient(credentials: StaticTokenCredentials(token: "t"), transport: transport,
                            sessionURL: URL(string: "https://api.example.test/jmap/session")!)
    try await client.connect()
    return (client, transport)
}

func summary(_ id: String, thread: String = "t1", boxes: [String], keywords: [String: Bool] = [:],
             from: String = "ann@example.com", date: Date = Date()) -> EmailSummary {
    EmailSummary(id: id, threadId: thread, mailboxIds: Dictionary(uniqueKeysWithValues: boxes.map { ($0, true) }),
                 keywords: keywords, from: [EmailAddress(email: from)], receivedAt: date)
}

final class MemoryOutboxStorage: OutboxStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [OutboxItem] = []
    func load() -> [OutboxItem] { lock.withLock { stored } }
    func save(_ items: [OutboxItem]) throws { lock.withLock { stored = items } }
}

/// A clock tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Never wakes on its own: tests drive due items with `fireDue()`.
let neverSleep: (TimeInterval) async throws -> Void = { _ in try await Task.sleep(nanoseconds: UInt64.max / 2) }

final class MockSender: OutboxSending, @unchecked Sendable {
    let lock = NSLock()
    var submitCalls = 0
    var completeCalls = 0
    var discarded: [String] = []
    var submitResult: () throws -> SubmitResponse = { SubmitResponse(emailId: "E1", submissionId: "S1", movedToSent: true) }
    var reconcileResult: () throws -> SendReconciliation = { SendReconciliation(emailIds: [], submissions: [], inSent: false) }
    var completeResult: () throws -> FollowUpResult = { FollowUpResult(draftRemoved: true, keywordSet: nil) }
    /// Suspends submit until released (for "quit during submission").
    var gate: CheckedContinuation<Void, Never>?
    var holdSubmit = false

    func submit(_ item: OutboxItem) async throws -> SubmitResponse {
        lock.withLock { submitCalls += 1 }
        if holdSubmit { await withCheckedContinuation { c in lock.withLock { gate = c } } }
        return try submitResult()
    }
    func reconcile(_ item: OutboxItem) async throws -> SendReconciliation { try reconcileResult() }
    func complete(_ item: OutboxItem) async throws -> FollowUpResult {
        lock.withLock { completeCalls += 1 }
        return try completeResult()
    }
    func discardCreatedCopy(_ emailId: String) async { lock.withLock { discarded.append(emailId) } }
}

func message(_ subject: String = "Hello") -> OutgoingMessage {
    OutgoingMessage(from: EmailAddress(email: "robin@example.com"), to: [EmailAddress(email: "ann@example.com")],
                    subject: subject, body: "Hi", messageId: "veerymail.\(UUID().uuidString)@example.com")
}

/// Lets queued tasks on the main actor run.
@MainActor func drain() async {
    for _ in 0..<20 { await Task.yield() }
}
