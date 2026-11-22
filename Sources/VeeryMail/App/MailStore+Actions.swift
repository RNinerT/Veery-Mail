import AppKit
import Foundation
import VeeryMailCore

/// A permanent deletion waiting for the user's confirmation.
struct PendingPermanentDelete: Identifiable {
    let id = UUID()
    let rows: [EmailSummary]
    let plan: PermanentDeletePlan
    /// Names of the other mailboxes that hold some of these messages.
    let otherMailboxNames: [String]
}

extension MailStore {
    // MARK: Row bookkeeping

    func targets(_ rows: [EmailSummary]?) -> [EmailSummary] {
        rows ?? selectedRows
    }

    /// Removes rows from the list and advances selection to the next message.
    func removeRows(_ rows: [EmailSummary]) {
        let ids = Set(rows.map(\.id))
        let firstIdx = messages.firstIndex { ids.contains($0.id) } ?? 0
        let originallySelected = !selection.isDisjoint(with: ids)
        messages.removeAll { ids.contains($0.id) }
        for r in rows { threadCache[r.threadId] = nil }
        if originallySelected {
            if messages.indices.contains(firstIdx) {
                selection = [messages[firstIdx].id]
                selectionChanged()
            } else {
                selection = []
                thread = []
            }
        }
    }

    func restoreRows(_ rows: [EmailSummary]) {
        let known = Set(messages.map(\.id))
        messages = (messages + rows.filter { !known.contains($0.id) }).sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Mailboxes each visible conversation was seen in (used when moving from Unread, Flagged or search).
    private func visibleMailboxes(_ rows: [EmailSummary]) -> [String: Set<String>] {
        Dictionary(rows.map { ($0.threadId, Set($0.mailboxIds.filter(\.value).keys)) }, uniquingKeysWith: { $0.union($1) })
    }

    // MARK: Moves (archive, trash, spam, folders)

    /// Moves conversations. Each message's result is reconciled on its own: confirmed changes
    /// stay, failed ones are put back, and Undo reverses only what was confirmed — using
    /// patches that touch just the mailboxes this move changed.
    func move(_ rows: [EmailSummary]? = nil, to target: String, verb: String) {
        let rows = targets(rows)
        guard !rows.isEmpty, let client else { return }
        let scope = currentMailboxId
        guard scope != target else { return }
        let gen = generation
        let visible = visibleMailboxes(rows)
        removeRows(rows)
        Task {
            let all: [EmailSummary]
            do {
                all = try await client.summaries(inThreads: Array(Set(rows.map(\.threadId))))
            } catch {
                guard isLive(gen) else { return }
                restoreRows(rows)
                return report(error)
            }
            let plan = MailMutation.move(all, scope: scope, visibleMailboxes: visible, to: target)
            await apply(plan, rows: rows, mail: all, verb: verb, gen: gen)
        }
    }

    /// Sends a plan, reconciles per message, puts back what failed and offers Undo for what succeeded.
    private func apply(_ plan: [PlannedChange], rows: [EmailSummary], mail: [EmailSummary], verb: String, gen: Int,
                       restoreIntoList: Bool = true) async {
        guard let client else { return }
        guard !plan.isEmpty else {
            if isLive(gen), restoreIntoList { restoreRows(rows) }
            return
        }
        let outcome: SetOutcome
        do {
            outcome = try await client.updateEmails(MailMutation.patches(plan))
        } catch {
            // The outcome is unknown: show what the server now has.
            guard isLive(gen) else { return }
            report(error)
            reloadList()
            return
        }
        guard isLive(gen) else { return }
        let confirmed = MailMutation.confirmed(plan, outcome)
        let threadOf = Dictionary(mail.map { ($0.id, $0.threadId) }, uniquingKeysWith: { a, _ in a })
        let failedThreads = Set(outcome.failed.keys.compactMap { threadOf[$0] })
        let confirmedThreads = Set(confirmed.compactMap { threadOf[$0.emailId] }).subtracting(failedThreads)
        let totalThreads = Set(rows.map(\.threadId)).count
        let keepVisible = rows.filter { !confirmedThreads.contains($0.threadId) }
        if restoreIntoList, !keepVisible.isEmpty { restoreRows(keepVisible) }
        if !failedThreads.isEmpty { reloadList() }

        let text = MailMutation.summary(verb: verb, confirmedThreads: confirmedThreads.count, totalThreads: totalThreads)
        guard !confirmed.isEmpty else { return showToast(text, undo: nil) }
        let movedRows = rows.filter { confirmedThreads.contains($0.threadId) }
        showToast(text) { [weak self] in
            self?.undo(confirmed, rows: restoreIntoList ? movedRows : [], gen: gen)
        }
    }

    private func undo(_ changes: [PlannedChange], rows: [EmailSummary], gen: Int) {
        guard isLive(gen), let client else { return }
        restoreRows(rows)
        Task {
            do {
                let outcome = try await client.updateEmails(MailMutation.patches(changes, inverse: true))
                guard isLive(gen) else { return }
                if !outcome.allSucceeded {
                    showToast("Couldn’t undo \(outcome.failed.count) message(s); they may have been changed elsewhere.", undo: nil)
                    reloadList()
                }
            } catch {
                guard isLive(gen) else { return }
                report(error)
                reloadList()
            }
        }
    }

    func archive(_ rows: [EmailSummary]? = nil) {
        guard let archive = mailbox(role: "archive") else { return report(JMAPError.unsupported("No Archive folder.")) }
        move(rows, to: archive.id, verb: "archived")
    }

    /// Moves to Trash. In Trash itself this never deletes: permanent deletion is its own
    /// action with a confirmation, so pressing Delete again can't destroy mail.
    func trash(_ rows: [EmailSummary]? = nil) {
        guard let trash = mailbox(role: "trash") else { return }
        if currentMailboxId == trash.id {
            showToast("Already in Trash. To delete forever, choose Delete Permanently… (⌥⌘⌫).", undo: nil)
            return
        }
        move(rows, to: trash.id, verb: "moved to Trash")
    }

    func markSpam(_ rows: [EmailSummary]? = nil) {
        guard let junk = mailbox(role: "junk") else { return }
        move(rows, to: junk.id, verb: "marked as spam")
    }

    func moveToInbox(_ rows: [EmailSummary]? = nil) {
        guard let inbox = mailbox(role: "inbox") else { return }
        move(rows, to: inbox.id, verb: "moved to the Inbox")
    }

    // MARK: Permanent deletion

    /// Works out exactly which messages would be destroyed, then asks.
    func requestPermanentDelete(_ rows: [EmailSummary]? = nil) {
        let rows = targets(rows)
        guard !rows.isEmpty, let client, let trash = mailbox(role: "trash") else { return }
        let gen = generation
        Task {
            do {
                let all = try await client.summaries(inThreads: Array(Set(rows.map(\.threadId))))
                guard isLive(gen) else { return }
                let plan = PermanentDeletePlan.make(threadMail: all, trashId: trash.id)
                guard plan.count > 0 else {
                    return showToast("Nothing to delete: these messages aren’t in Trash.", undo: nil)
                }
                let others = Set(plan.alsoElsewhere.values.flatMap { $0 }).compactMap { mailbox(id: $0)?.name }.sorted()
                pendingPermanentDelete = PendingPermanentDelete(rows: rows, plan: plan, otherMailboxNames: others)
            } catch {
                if isLive(gen) { report(error) }
            }
        }
    }

    /// `keepFiledCopies`: messages also filed elsewhere are only removed from Trash, not destroyed.
    func confirmPermanentDelete(_ pending: PendingPermanentDelete, keepFiledCopies: Bool) {
        pendingPermanentDelete = nil
        guard let client, let trash = mailbox(role: "trash") else { return }
        let gen = generation
        let destroyIds = keepFiledCopies ? pending.plan.trashOnlyIds : pending.plan.messageIds
        let unfileIds = keepFiledCopies ? Array(pending.plan.alsoElsewhere.keys) : []
        removeRows(pending.rows)
        Task {
            do {
                async let destroyed = client.destroyEmails(destroyIds)
                async let unfiled = client.updateEmails(Dictionary(uniqueKeysWithValues: unfileIds.map {
                    ($0, ["mailboxIds/\(trash.id)": NSNull()] as [String: Any])
                }))
                let (d, u) = try await (destroyed, unfiled)
                guard isLive(gen) else { return }
                let failed = d.failed.filter { $0.value != "notFound" }.count + u.failed.count
                var parts: [String] = []
                if !d.succeeded.isEmpty { parts.append("Deleted \(d.succeeded.count) permanently") }
                if !u.succeeded.isEmpty { parts.append("removed \(u.succeeded.count) from Trash") }
                if failed > 0 { parts.append("\(failed) couldn’t be changed") }
                showToast(parts.joined(separator: "; ") + ".", undo: nil)
                if failed > 0 { reloadList() }
            } catch {
                guard isLive(gen) else { return }
                report(error)
                reloadList()
            }
        }
    }

    // MARK: Keywords

    private func setKeyword(_ keyword: String, _ on: Bool, ids: Set<String>, threads: Set<String>) {
        for i in messages.indices where ids.contains(messages[i].id) || threads.contains(messages[i].threadId) {
            messages[i].keywords[keyword] = on ? true : nil
        }
        for i in thread.indices where threads.contains(thread[i].threadId) || ids.contains(thread[i].id) {
            thread[i].keywords[keyword] = on ? true : nil
        }
    }

    /// Read state applies to whole conversations. Only messages whose state actually changes
    /// are patched, and only confirmed ones are reflected.
    func setRead(_ read: Bool, rows: [EmailSummary]? = nil, showToast toast: Bool = true) {
        let rows = targets(rows)
        guard !rows.isEmpty, let client else { return }
        let gen = generation
        let threads = Set(rows.map(\.threadId))
        setKeyword("$seen", read, ids: [], threads: threads)
        Task {
            do {
                let all = try await client.summaries(inThreads: Array(threads))
                let plan = MailMutation.keyword(all, "$seen", on: read)
                let outcome = try await client.updateEmails(MailMutation.patches(plan))
                guard isLive(gen) else { return }
                if !outcome.allSucceeded {
                    showToast("Couldn’t mark \(outcome.failed.count) message(s) \(read ? "read" : "unread").", undo: nil)
                    reloadList()
                } else if toast {
                    showToast(read ? "Marked as read" : "Marked as unread", undo: nil)
                }
            } catch {
                guard isLive(gen) else { return }
                setKeyword("$seen", !read, ids: [], threads: threads)
                report(error)
            }
        }
    }

    func toggleRead() {
        let rows = selectedRows
        setRead(rows.contains { $0.isUnread }, rows: rows)
    }

    /// Flags the visible (latest) message of each conversation, like Fastmail's web client.
    func toggleFlag() {
        let rows = selectedRows
        guard let client, !rows.isEmpty else { return }
        let gen = generation
        let flag = !rows.allSatisfy(\.isFlagged)
        let plan = MailMutation.keyword(rows, "$flagged", on: flag)
        let ids = Set(plan.map(\.emailId))
        setKeyword("$flagged", flag, ids: ids, threads: [])
        Task {
            do {
                let outcome = try await client.updateEmails(MailMutation.patches(plan))
                guard isLive(gen) else { return }
                let failed = Set(outcome.failed.keys)
                if !failed.isEmpty {
                    setKeyword("$flagged", !flag, ids: failed, threads: [])
                    showToast("Couldn’t change the flag on \(failed.count) message(s).", undo: nil)
                }
            } catch {
                guard isLive(gen) else { return }
                setKeyword("$flagged", !flag, ids: ids, threads: [])
                report(error)
            }
        }
    }

    // MARK: Snooze

    private func snoozeMailboxId() async throws -> String {
        let name = "Later"
        if let existing = mailboxes.first(where: { $0.name == name && $0.parentId == nil }) { return existing.id }
        guard let client else { throw JMAPError.notConnected }
        let id = try await client.createMailbox(name: name)
        let (mbs, _) = try await client.mailboxes()
        applyMailboxes(mbs)
        return id
    }

    private func persistSnoozes() {
        do { try snoozeStorage?.save(snoozeRecords) } catch { report(error) }
    }

    /// The record is saved before any mail moves, with each message's original mailboxes,
    /// so a restart at any point can finish or undo the snooze cleanly.
    func snooze(until date: Date, rows: [EmailSummary]? = nil) {
        let rows = targets(rows)
        guard !rows.isEmpty, let client, let key = accountKey else { return }
        let scope = currentMailboxId
        let gen = generation
        let visible = visibleMailboxes(rows)
        removeRows(rows)
        Task {
            do {
                let later = try await snoozeMailboxId()
                guard isLive(gen) else { return }
                guard scope != later else {
                    restoreRows(rows)
                    return showToast("Already snoozed", undo: nil)
                }
                let all = try await client.summaries(inThreads: Array(Set(rows.map(\.threadId))))
                guard isLive(gen) else { return }
                let (record, plan) = SnoozePlanner.plan(all, scope: scope, visibleMailboxes: visible,
                                                        later: later, until: date, accountKey: key)
                guard !plan.isEmpty else { restoreRows(rows); return }
                snoozeRecords.append(record)
                persistSnoozes()   // on disk before the move

                let outcome: SetOutcome
                do {
                    outcome = try await client.updateEmails(MailMutation.patches(plan))
                } catch {
                    // Unknown outcome: the record stays "planned" and is checked against the server.
                    guard isLive(gen) else { return }
                    report(error)
                    await resolvePlannedSnoozes(gen)
                    reloadList()
                    return
                }
                guard isLive(gen) else { return }
                let applied = SnoozePlanner.applyMove(record, outcome)
                snoozeRecords.removeAll { $0.id == record.id }
                if !applied.entries.isEmpty { snoozeRecords.append(applied) }
                persistSnoozes()

                let threadOf = Dictionary(all.map { ($0.id, $0.threadId) }, uniquingKeysWith: { a, _ in a })
                let moved = Set(applied.entries.compactMap { threadOf[$0.emailId] })
                let back = rows.filter { !moved.contains($0.threadId) }
                if !back.isEmpty { restoreRows(back) }
                let f = DateFormatter()
                f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
                let total = Set(rows.map(\.threadId)).count
                showToast(moved.count == total
                          ? "Snoozed until \(f.string(from: date))"
                          : "Snoozed \(moved.count) of \(total) conversations until \(f.string(from: date)). The rest couldn’t be moved.",
                          undo: nil)
            } catch {
                guard isLive(gen) else { return }
                restoreRows(rows)
                report(error)
            }
        }
    }

    /// At launch: migrate old records, settle unconfirmed moves, wake anything overdue, then check every minute.
    func startSnoozes(_ gen: Int) {
        migrateLegacySnoozes()
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLive(gen) else { return }
                await self.wakeDueSnoozes(gen)
            }
        }
        Task {
            await resolvePlannedSnoozes(gen)
            await wakeDueSnoozes(gen)
        }
    }

    /// Converts snoozes saved by earlier versions (one return mailbox per record).
    private func migrateLegacySnoozes() {
        guard let key = accountKey, let laterId = mailboxes.first(where: { $0.name == "Later" && $0.parentId == nil })?.id,
              let legacy = cache.load([SnoozeEntry].self, "snoozes"), !legacy.isEmpty else { return }
        for old in legacy {
            snoozeRecords.append(SnoozeRecord(
                id: UUID(), accountKey: key, laterMailboxId: laterId, until: old.until, phase: .active,
                entries: old.emailIds.map { .init(emailId: $0, originalMailboxIds: [old.returnMailboxId], state: .moved) },
                failedWakeAttempts: 0, lastError: nil, nextAttempt: nil))
        }
        cache.save([SnoozeEntry](), "snoozes")
        persistSnoozes()
    }

    private func resolvePlannedSnoozes(_ gen: Int) async {
        guard let client else { return }
        for record in snoozeRecords where record.phase == .planned {
            guard let current = try? await client.summaries(ids: record.entries.map(\.emailId)), isLive(gen) else { continue }
            let resolved = SnoozePlanner.resolvePlanned(record, current: current)
            snoozeRecords.removeAll { $0.id == record.id }
            if !resolved.isFinished { snoozeRecords.append(resolved) }
        }
        persistSnoozes()
    }

    func wakeDueSnoozes(_ gen: Int, force: Bool = false) async {
        guard let client else { return }
        let now = Date()
        for record in snoozeRecords where record.phase == .active
            && (force || (record.until <= now && (record.nextAttempt ?? .distantPast) <= now)) {
            do {
                let current = try await client.summaries(ids: record.entries.filter { $0.state == .moved }.map(\.emailId))
                guard isLive(gen) else { return }
                let (prepared, patches) = SnoozePlanner.wake(record, current: current)
                var result = prepared
                if !patches.isEmpty {
                    let outcome = try await client.updateEmails(patches.mapValues { MailMutation.encode($0) })
                    guard isLive(gen) else { return }
                    result = SnoozePlanner.applyWake(prepared, outcome, now: now)
                }
                snoozeRecords.removeAll { $0.id == record.id }
                if !result.isFinished { snoozeRecords.append(result) }
            } catch {
                guard isLive(gen) else { return }
                if let i = snoozeRecords.firstIndex(where: { $0.id == record.id }) {
                    snoozeRecords[i].failedWakeAttempts += 1
                    snoozeRecords[i].lastError = error.localizedDescription
                    snoozeRecords[i].nextAttempt = now.addingTimeInterval(min(60 * pow(2, Double(snoozeRecords[i].failedWakeAttempts - 1)), 3600))
                }
            }
        }
        persistSnoozes()
        if !snoozeRecords.isEmpty || force { reloadList() }
    }

    /// Returns every snoozed conversation now (used before signing out, on request).
    func wakeAllSnoozesNow() async {
        await wakeDueSnoozes(generation, force: true)
    }

    /// Snoozed conversations and when the next one comes back.
    var snoozeSummary: (count: Int, next: Date?) {
        let active = snoozeRecords.filter { !$0.isFinished }
        return (active.count, active.map(\.until).min())
    }

    // MARK: Sidebar data

    /// Loads the summary card's data: daily new-mail counts for two weeks (one request of
    /// counts only, at most every 5 minutes unless forced) and today's Inbox mail for the
    /// "Top senders" stat. Failures are ignored: the card is a summary, not data you act on.
    func refreshArrivals(force: Bool = false) {
        guard !isDemo, defaults.object(forKey: "sidebar.showConditions") as? Bool ?? true,
              let client, let inbox = mailbox(role: "inbox") else { return }
        let gen = generation
        let now = Date()
        let dayChanged = mailVolume.map { !Calendar.current.isDate($0.days.last?.start ?? .distantPast, inSameDayAs: now) } ?? true
        if force || dayChanged || now.timeIntervalSince(volumeRefreshedAt) > 300 {
            volumeRefreshedAt = now
            let excluded = ["sent", "drafts", "junk", "trash"].compactMap { mailbox(role: $0)?.id }
            Task {
                if let volume = try? await client.mailVolume(now: now, excluding: excluded), isLive(gen) {
                    mailVolume = volume
                }
            }
        }
        let since = JMAPDate.string(now.addingTimeInterval(-24 * 3600))
        Task {
            if let page = try? await client.queryEmails(filter: ["inMailbox": inbox.id, "after": since],
                                                        limit: 250, collapseThreads: false), isLive(gen) {
                inboxRecent = page.emails
            }
        }
    }

    /// Fetches the chosen stats. Cheap stats refresh at most every 5 minutes; the 4-week
    /// history used by "Busiest hours" and "Mail load by folder" at most every 6 hours.
    func refreshStats(force: Bool = false) {
        let chosen = Set(CardStat.selected())
        guard !isDemo, let client, !chosen.isEmpty,
              defaults.object(forKey: "sidebar.showConditions") as? Bool ?? true else { return }
        guard force || Date().timeIntervalSince(statsRefreshedAt) > 300 else { return }
        statsRefreshedAt = Date()
        let gen = generation
        let inbox = mailbox(role: "inbox"), sent = mailbox(role: "sent")
        let mine = Set(identities.map { $0.email.lowercased() })
        let waitDays = Double(defaults.object(forKey: "card.waitingDays") as? Int ?? 3)
        let now = Date()

        Task {
            if chosen.contains(.oldestUnread), let inbox {
                let page = try? await client.queryEmails(filter: ["inMailbox": inbox.id, "notKeyword": "$seen"],
                                                         limit: 1, collapseThreads: false, oldestFirst: true)
                guard isLive(gen) else { return }
                if let page {
                    cardStats.oldestUnread = page.emails.first
                    cardStats.oldestUnreadLoaded = true
                }
            }
            if chosen.contains(.replyDebt), let inbox {
                let base: [String: Any] = ["inMailbox": inbox.id, "hasKeyword": "$seen", "notKeyword": "$answered",
                                           "after": JMAPDate.string(now.addingTimeInterval(-14 * 86_400))]
                // Leave out mailing lists: they're read, but nobody expects an answer.
                let personal: [String: Any] = ["operator": "AND", "conditions": [
                    base, ["operator": "NOT", "conditions": [["header": ["List-Id"]]]] as [String: Any],
                ]]
                var total = try? await client.queryEmails(filter: personal, limit: 1).total
                if total == nil { total = try? await client.queryEmails(filter: base, limit: 1).total }
                guard isLive(gen) else { return }
                if let total { cardStats.replyDebt = total }
            }
            if chosen.contains(.waiting) || chosen.contains(.responseTime), let sent,
               let r = try? await client.sentWithThreads(sentMailboxId: sent.id,
                                                         since: now.addingTimeInterval(-14 * 86_400), limit: 150) {
                guard isLive(gen) else { return }
                cardStats.waiting = MailStats.waitingThreads(sent: r.sent, threadMail: r.threadMail,
                                                             sentMailboxId: sent.id, myAddresses: mine,
                                                             olderThan: waitDays * 86_400, now: now)
                let delays = MailStats.replyDelays(sent: r.sent, threadMail: r.threadMail,
                                                   sentMailboxId: sent.id, myAddresses: mine)
                let weekAgo = now.addingTimeInterval(-7 * 86_400)
                cardStats.replyThisWeek = MailStats.median(delays.filter { $0.sentAt > weekAgo }.map(\.delay))
                cardStats.replyLastWeek = MailStats.median(delays.filter { $0.sentAt <= weekAgo }.map(\.delay))
                cardStats.replyLoaded = true
            }
            if chosen.contains(.scheduled), let count = try? await client.scheduledSendCount() {
                guard isLive(gen) else { return }
                cardStats.scheduledSends = count
            }
            if chosen.contains(.busiestHours) || chosen.contains(.folderLoad) {
                if force || now.timeIntervalSince(metaRefreshedAt) > 6 * 3600 {
                    let skip = ["trash", "junk", "drafts", "sent"].compactMap { mailbox(role: $0)?.id }
                    if let meta = try? await client.mailMeta(filter: ["after": JMAPDate.string(now.addingTimeInterval(-28 * 86_400)),
                                                                      "inMailboxOtherThan": skip], limit: 1500) {
                        guard isLive(gen) else { return }
                        recentMeta = meta
                        metaRefreshedAt = now
                    }
                }
                guard isLive(gen) else { return }
                cardStats.busiest = MailStats.busiestWindow(recentMeta.map(\.receivedAt))
                let order = ["inbox", "archive"].compactMap { mailbox(role: $0)?.id }
                cardStats.folderLoad = MailStats.folderLoad(recentMeta.filter { $0.receivedAt > now.addingTimeInterval(-7 * 86_400) },
                                                            preferredOrder: order)
            }
        }
    }

    /// "Top senders today" → archive what that sender put in the Inbox (undoable).
    func archiveFromSender(_ rows: [EmailSummary], name: String) {
        guard let archive = mailbox(role: "archive"), let inbox = mailbox(role: "inbox"), !rows.isEmpty,
              let client else { return }
        let gen = generation
        let ids = Set(rows.map(\.id))
        inboxRecent.removeAll { ids.contains($0.id) }
        if currentMailboxId == inbox.id { removeRows(messages.filter { ids.contains($0.id) }) }
        Task {
            guard let all = try? await client.summaries(inThreads: Array(Set(rows.map(\.threadId)))), isLive(gen) else { return }
            let plan = MailMutation.move(all.filter { ids.contains($0.id) }, scope: inbox.id, visibleMailboxes: [:], to: archive.id)
            await apply(plan, rows: rows, mail: all, verb: "from \(name) archived", gen: gen,
                        restoreIntoList: currentMailboxId == inbox.id)
            refreshArrivals()
        }
    }
}
