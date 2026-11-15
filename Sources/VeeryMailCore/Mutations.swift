import Foundation

/// One message's change: a JMAP patch and the patch that reverses exactly that change.
/// Values: true = add (mailbox or keyword), false = remove. Only the keys the operation
/// touched appear, so undo never disturbs labels or flags changed elsewhere since.
public struct PlannedChange: Equatable, Sendable {
    public let emailId: String
    public let forward: [String: Bool]
    public let inverse: [String: Bool]

    public init(emailId: String, forward: [String: Bool], inverse: [String: Bool]) {
        self.emailId = emailId; self.forward = forward; self.inverse = inverse
    }
}

public enum MailMutation {
    /// Moves messages into `target`.
    /// - With a `scope` (a mailbox view), only messages in that mailbox move, out of it.
    /// - Without one (Unread, Flagged, search), each message leaves the mailboxes listed for
    ///   its conversation in `visibleMailboxes` (where the user saw it).
    public static func move(_ mail: [EmailSummary], scope: String?, visibleMailboxes: [String: Set<String>],
                            to target: String) -> [PlannedChange] {
        mail.compactMap { email in
            let current = Set(email.mailboxIds.filter(\.value).keys)
            let leaving: Set<String>
            if let scope {
                guard current.contains(scope) else { return nil }
                leaving = [scope]
            } else {
                leaving = current.intersection(visibleMailboxes[email.threadId] ?? []).subtracting([target])
                guard !leaving.isEmpty else { return nil }
            }
            guard !current.contains(target) || !leaving.isEmpty else { return nil }
            var forward: [String: Bool] = [:], inverse: [String: Bool] = [:]
            for box in leaving.subtracting([target]) {
                forward["mailboxIds/\(box)"] = false
                inverse["mailboxIds/\(box)"] = true
            }
            if !current.contains(target) {
                forward["mailboxIds/\(target)"] = true
                inverse["mailboxIds/\(target)"] = false
            }
            return forward.isEmpty ? nil : PlannedChange(emailId: email.id, forward: forward, inverse: inverse)
        }
    }

    /// Sets or clears a keyword, only on messages where it actually changes.
    public static func keyword(_ mail: [EmailSummary], _ keyword: String, on: Bool) -> [PlannedChange] {
        mail.compactMap { email in
            let has = email.keywords[keyword] == true
            guard has != on else { return nil }
            return PlannedChange(emailId: email.id, forward: ["keywords/\(keyword)": on],
                                 inverse: ["keywords/\(keyword)": !on])
        }
    }

    /// Changes the server confirmed. Undo is registered only for these.
    public static func confirmed(_ plan: [PlannedChange], _ outcome: SetOutcome) -> [PlannedChange] {
        plan.filter { outcome.succeeded.contains($0.emailId) }
    }

    /// JMAP patch objects (removals become null).
    public static func patches(_ plan: [PlannedChange], inverse: Bool = false) -> [String: [String: Any]] {
        Dictionary(uniqueKeysWithValues: plan.map { change in
            (change.emailId, encode(inverse ? change.inverse : change.forward))
        })
    }

    public static func encode(_ patch: [String: Bool]) -> [String: Any] {
        patch.mapValues { $0 ? true as Any : NSNull() as Any }
    }

    /// "3 conversations archived", "2 of 3 conversations archived. 1 couldn’t be changed." and similar.
    /// `verb` is a past participle phrase: "archived", "moved to Trash".
    public static func summary(verb: String, confirmedThreads: Int, totalThreads: Int) -> String {
        let noun = totalThreads == 1 ? "conversation" : "conversations"
        if confirmedThreads == totalThreads { return "\(totalThreads) \(noun) \(verb)" }
        if confirmedThreads == 0 { return "Couldn’t change \(totalThreads == 1 ? "the conversation" : "these \(totalThreads) \(noun)")" }
        return "\(confirmedThreads) of \(totalThreads) \(noun) \(verb). \(totalThreads - confirmedThreads) couldn’t be changed."
    }
}

// MARK: - Permanent deletion

/// What "Delete Permanently…" will do, worked out before the confirmation is shown.
public struct PermanentDeletePlan: Equatable, Sendable {
    /// Every message in Trash for the selected conversations.
    public let messageIds: [String]
    /// Messages that are also filed in another mailbox → those other mailbox ids.
    public let alsoElsewhere: [String: [String]]

    public var count: Int { messageIds.count }
    public var trashOnlyIds: [String] { messageIds.filter { alsoElsewhere[$0] == nil } }

    /// Messages in the selected conversations that are *not* in Trash are never included.
    public static func make(threadMail: [EmailSummary], trashId: String) -> PermanentDeletePlan {
        var ids: [String] = []
        var elsewhere: [String: [String]] = [:]
        for email in threadMail where email.mailboxIds[trashId] == true {
            ids.append(email.id)
            let others = email.mailboxIds.filter { $0.value && $0.key != trashId }.map(\.key).sorted()
            if !others.isEmpty { elsewhere[email.id] = others }
        }
        return PermanentDeletePlan(messageIds: ids, alsoElsewhere: elsewhere)
    }
}

// MARK: - Snooze records

/// A snooze, persisted before any mail moves so it can be resumed or undone after a restart.
public struct SnoozeRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case planned   // saved, mail not yet moved (or not yet confirmed)
        case active    // mail is in Later, waiting for its time
    }
    public enum EntryState: String, Codable, Sendable {
        case pending, moved, returned, gone
    }
    public struct Entry: Codable, Equatable, Sendable {
        public let emailId: String
        /// Mailboxes the message was taken out of (restored on wake-up).
        public let originalMailboxIds: [String]
        public var state: EntryState
    }

    public let id: UUID
    public let accountKey: String
    public let laterMailboxId: String
    public let until: Date
    public var phase: Phase
    public var entries: [Entry]
    public var failedWakeAttempts: Int
    public var lastError: String?
    public var nextAttempt: Date?

    public var isFinished: Bool { entries.allSatisfy { $0.state == .returned || $0.state == .gone } }
}

public enum SnoozePlanner {
    public static func plan(_ mail: [EmailSummary], scope: String?, visibleMailboxes: [String: Set<String>],
                            later: String, until: Date, accountKey: String) -> (SnoozeRecord, [PlannedChange]) {
        let changes = MailMutation.move(mail, scope: scope, visibleMailboxes: visibleMailboxes, to: later)
        let entries = changes.map { change in
            SnoozeRecord.Entry(emailId: change.emailId,
                               originalMailboxIds: change.forward.filter { !$0.value }
                                   .map { String($0.key.dropFirst("mailboxIds/".count)) }.sorted(),
                               state: .pending)
        }
        let record = SnoozeRecord(id: UUID(), accountKey: accountKey, laterMailboxId: later, until: until,
                                  phase: .planned, entries: entries, failedWakeAttempts: 0, lastError: nil, nextAttempt: nil)
        return (record, changes)
    }

    /// After the move request: confirmed entries are moved, the rest are dropped.
    public static func applyMove(_ record: SnoozeRecord, _ outcome: SetOutcome) -> SnoozeRecord {
        var r = record
        r.entries = r.entries.compactMap { e in
            guard outcome.succeeded.contains(e.emailId) else { return nil }
            var e = e; e.state = .moved; return e
        }
        r.phase = .active
        return r
    }

    /// At launch, for a record saved before the move was confirmed: look at the server.
    public static func resolvePlanned(_ record: SnoozeRecord, current: [EmailSummary]) -> SnoozeRecord {
        let byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var r = record
        r.entries = r.entries.compactMap { e in
            guard let email = byId[e.emailId], email.mailboxIds[record.laterMailboxId] == true else { return nil }
            var e = e; e.state = .moved; return e
        }
        r.phase = .active
        return r
    }

    /// Patches that return snoozed mail. Messages the user already moved out of Later
    /// (or deleted) are left alone and marked done.
    public static func wake(_ record: SnoozeRecord, current: [EmailSummary]) -> (SnoozeRecord, [String: [String: Bool]]) {
        let byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var r = record
        var patches: [String: [String: Bool]] = [:]
        for i in r.entries.indices where r.entries[i].state == .moved {
            let e = r.entries[i]
            guard let email = byId[e.emailId], email.mailboxIds[record.laterMailboxId] == true else {
                r.entries[i].state = .gone
                continue
            }
            var patch: [String: Bool] = ["mailboxIds/\(record.laterMailboxId)": false, "keywords/$seen": false]
            for box in e.originalMailboxIds { patch["mailboxIds/\(box)"] = true }
            patches[e.emailId] = patch
        }
        return (r, patches)
    }

    public static func applyWake(_ record: SnoozeRecord, _ outcome: SetOutcome, now: Date) -> SnoozeRecord {
        var r = record
        for i in r.entries.indices where r.entries[i].state == .moved {
            let id = r.entries[i].emailId
            if outcome.succeeded.contains(id) {
                r.entries[i].state = .returned
            } else if outcome.failed[id] == "notFound" {
                r.entries[i].state = .gone
            }
        }
        if r.isFinished {
            r.lastError = nil
        } else {
            r.failedWakeAttempts += 1
            r.lastError = "Couldn’t return \(r.entries.filter { $0.state == .moved }.count) snoozed message(s)."
            r.nextAttempt = now.addingTimeInterval(min(60 * pow(2, Double(r.failedWakeAttempts - 1)), 3600))
        }
        return r
    }
}

public protocol SnoozeStorage: Sendable {
    func load() -> [SnoozeRecord]
    func save(_ records: [SnoozeRecord]) throws
}

public struct FileSnoozeStorage: SnoozeStorage {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> [SnoozeRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? FileOutboxStorage.decoder.decode([SnoozeRecord].self, from: data)) ?? []
    }
    public func save(_ records: [SnoozeRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileOutboxStorage.encoder.encode(records).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
