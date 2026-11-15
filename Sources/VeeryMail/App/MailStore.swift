import AppKit
import Foundation
import VeeryMailCore
import Observation
import UserNotifications

enum ListSource: Hashable {
    case mailbox(String)
    case flagged
    case unread
    case search(String)
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let undo: (@MainActor () -> Void)?
}

struct PendingSend: Identifiable {
    let id = UUID()
    let message: OutgoingMessage
    let deadline: Date
    let sendAt: Date?
    let draftId: String?
    let identity: Identity
}

/// Single source of truth for the UI. All network calls go through `client`;
/// every user action updates local state first (optimistic) so the UI never waits.
@MainActor
@Observable
final class MailStore {
    enum Phase { case signedOut, connecting, ready }

    /// Fictional mail, no network. See `DemoMail`.
    private(set) var isDemo = false
    @ObservationIgnored private var demoMessages: [EmailSummary] = []

    func installDemo(mailboxes: [Mailbox], identities: [Identity], messages: [EmailSummary], threads: [[EmailDetail]]) {
        isDemo = true
        self.mailboxes = mailboxes
        self.identities = identities
        demoMessages = messages
        for thread in threads {
            if let id = thread.first?.threadId { threadCache[id] = thread }
        }
        totalInSource = messages.count
        lastSync = Date().addingTimeInterval(-90)
        // A believable day of arrivals: the demo rows plus a few more spread over the day.
        let extra = [0.3, 1.2, 1.4, 2.6, 3.1, 3.3, 5.2, 6.8, 9.5, 10.1, 13.4, 15.8, 22.0]
        inboxArrivals = messages.map(\.receivedAt).filter { $0 > Date().addingTimeInterval(-86_400) }
            + extra.map { Date().addingTimeInterval(-$0 * 3600) }
        inboxRecent = messages.filter { $0.receivedAt > Date().addingTimeInterval(-86_400) }
        cardStats = CardStatValues.demo(messages: messages)
        if let inbox = mailbox(role: "inbox") { source = .mailbox(inbox.id) }
        phase = .ready
    }

    /// The app's single store, so the app delegate can flush a pending send before quitting.
    static weak var current: MailStore?

    // Connection
    var phase: Phase = .signedOut
    var lastError: String?
    var isOnline = true
    private(set) var client: JMAPClient?

    // Data
    var mailboxes: [Mailbox] = []
    var identities: [Identity] = []
    private(set) var sourceStorage: ListSource = .mailbox("")
    /// Setting this switches the message list (computed so it works cleanly with @Observable).
    var source: ListSource {
        get { sourceStorage }
        set {
            guard newValue != sourceStorage else { return }
            sourceStorage = newValue
            sourceChanged()
        }
    }
    var messages: [EmailSummary] = []
    var totalInSource: Int?
    var isLoadingList = false
    var selection: Set<String> = []
    var thread: [EmailDetail] = []
    /// Messages that were unread when the conversation was opened (shown expanded).
    var expandedOnOpen: Set<String> = []
    var isLoadingThread = false

    // UI state
    var toast: Toast?
    var pendingSend: PendingSend?
    var composer: ComposeDraft?
    var showCommandPalette = false
    var showMaskedEmail = false
    var searchText = ""

    @ObservationIgnored private var emailState: String?
    @ObservationIgnored private var threadCache: [String: [EmailDetail]] = [:]
    @ObservationIgnored private var threadCacheOrder: [String] = []
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var threadTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var snoozeTimer: Timer?
    @ObservationIgnored private var cache = DiskCache(namespace: "default")
    @ObservationIgnored private var snoozes: [SnoozeEntry] = []
    @ObservationIgnored private var notifiedIds: Set<String> = []
    @ObservationIgnored private var launchedAt = Date()
    /// When mail was last confirmed up to date (shown as "Updated …" in the sidebar).
    private(set) var lastSync = Date.distantPast
    /// Arrival times of Inbox mail in the last 24 hours, for the sidebar's activity graph.
    private(set) var inboxArrivals: [Date] = []
    /// Inbox mail from the last 24 hours (headers only), for "Top senders today".
    private(set) var inboxRecent: [EmailSummary] = []
    /// Values for the optional stats on the sidebar card. Only the stats you've chosen are fetched.
    var cardStats = CardStatValues()
    @ObservationIgnored private var statsRefreshedAt = Date.distantPast
    @ObservationIgnored private var metaRefreshedAt = Date.distantPast
    @ObservationIgnored private var recentMeta: [MailMeta] = []
    @ObservationIgnored private var openedRowId: String?

    private var defaults: UserDefaults { .standard }

    // MARK: Lifecycle

    init() {
        MailStore.current = self
        // `open "Veery Mail.app" --args -demo YES` shows fictional mail (for screenshots and design review).
        if UserDefaults.standard.bool(forKey: "demo") {
            DemoMail.install(in: self)
            return
        }
        if let token = Keychain.token() {
            start(token: token)
        }
    }

    func signIn(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        start(token: trimmed, persist: true)
    }

    func signOut() {
        pushTask?.cancel(); refreshTask?.cancel(); listTask?.cancel(); snoozeTimer?.invalidate()
        Keychain.delete()
        cache.clear()
        client = nil
        mailboxes = []; messages = []; thread = []; identities = []; selection = []
        emailState = nil; threadCache = [:]; threadCacheOrder = []
        phase = .signedOut
        NSApp.dockTile.badgeLabel = nil
    }

    private func start(token: String, persist: Bool = false) {
        let client = JMAPClient(token: token)
        self.client = client
        phase = .connecting
        lastError = nil

        // Paint instantly from cache.
        if let cachedBoxes = cache.load([Mailbox].self, "mailboxes"), !cachedBoxes.isEmpty {
            mailboxes = cachedBoxes
            if let inbox = mailbox(role: "inbox") {
                source = .mailbox(inbox.id)
                messages = cache.load([EmailSummary].self, "list-\(inbox.id)") ?? []
            }
            phase = .ready
        }
        snoozes = cache.load([SnoozeEntry].self, "snoozes") ?? []
        connect(client, token: token, persist: persist, attempt: 0)
    }

    /// Connects to Fastmail. With a saved token it keeps retrying with backoff, so launching
    /// offline (or before Wi-Fi is up) recovers on its own.
    private func connect(_ client: JMAPClient, token: String, persist: Bool, attempt: Int) {
        Task {
            do {
                try await client.connect()
                guard self.client === client else { return }
                if persist { try Keychain.save(token: token) }
                async let boxes = client.mailboxes()
                async let ids = client.identities()
                let (mbs, _) = try await boxes
                applyMailboxes(mbs)
                identities = (try? await ids) ?? []
                if case .mailbox(let id) = source, mailboxes.contains(where: { $0.id == id }) {
                    reloadList()
                } else if let inbox = mailbox(role: "inbox") {
                    source = .mailbox(inbox.id)
                }
                phase = .ready
                isOnline = true
                lastError = nil
                lastSync = Date()
                refreshArrivals()
                refreshStats(force: true)
                requestNotificationPermission()
                startPush()
                startSnoozeTimer()
            } catch {
                guard self.client === client else { return }
                lastError = error.localizedDescription
                isOnline = false
                if case JMAPError.http(401, _) = error {
                    Keychain.delete()
                    phase = .signedOut
                    return
                }
                if phase == .connecting { phase = mailboxes.isEmpty ? .signedOut : .ready }
                guard !persist else { return }   // a fresh sign-in shows its error instead of retrying
                let delay = min(5 * pow(2, Double(attempt)), 120)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if self.client === client, client.session == nil {
                    connect(client, token: token, persist: persist, attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: Mailboxes

    func mailbox(role: String) -> Mailbox? { mailboxes.first { $0.role == role } }
    func mailbox(id: String) -> Mailbox? { mailboxes.first { $0.id == id } }

    var currentMailboxId: String? {
        if case .mailbox(let id) = source { return id }
        return nil
    }

    var sourceTitle: String {
        switch source {
        case .mailbox(let id): return mailbox(id: id)?.name ?? "Mail"
        case .flagged: return "Flagged"
        case .unread: return "Unread"
        case .search(let q): return "Search: \(q)"
        }
    }

    /// Mailboxes as a depth-annotated tree, system folders first.
    var mailboxTree: [(mailbox: Mailbox, depth: Int)] {
        let children = Dictionary(grouping: mailboxes, by: { $0.parentId ?? "" })
        func sorted(_ list: [Mailbox]) -> [Mailbox] {
            list.sorted { ($0.roleRank, $0.sortOrder, $0.name.lowercased()) < ($1.roleRank, $1.sortOrder, $1.name.lowercased()) }
        }
        var out: [(mailbox: Mailbox, depth: Int)] = []
        func walk(_ parent: String, _ depth: Int) {
            for mb in sorted(children[parent] ?? []) {
                out.append((mailbox: mb, depth: depth))
                walk(mb.id, depth + 1)
            }
        }
        walk("", 0)
        return out
    }

    private func applyMailboxes(_ list: [Mailbox]) {
        mailboxes = list
        cache.save(list, "mailboxes")
        let unread = mailbox(role: "inbox")?.unreadThreads ?? 0
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
        if !isDemo, let inbox = mailbox(role: "inbox") { StreakLedger.record(inboxCount: inbox.totalThreads) }
    }

    // MARK: List loading

    private func sourceChanged() {
        selection = []
        openedRowId = nil
        thread = []
        if isDemo {
            messages = currentMailboxId == mailbox(role: "inbox")?.id ? demoMessages : []
            return
        }
        if case .mailbox(let id) = source {
            messages = cache.load([EmailSummary].self, "list-\(id)") ?? []
        } else {
            messages = []
        }
        reloadList()
    }

    private var excludedFromSearch: [String] {
        ["trash", "junk"].compactMap { mailbox(role: $0)?.id }
    }

    private func currentFilter() -> [String: Any] {
        switch source {
        case .mailbox(let id):
            return ["inMailbox": id]
        case .flagged:
            return ["hasKeyword": "$flagged", "inMailboxOtherThan": excludedFromSearch]
        case .unread:
            var f: [String: Any] = ["notKeyword": "$seen"]
            if let inbox = mailbox(role: "inbox") { f["inMailbox"] = inbox.id }
            return f
        case .search(let text):
            let q = SearchQuery.parse(text)
            return q.filter(defaultMailboxId: nil, excludedMailboxIds: excludedFromSearch) { name in
                let lower = name.lowercased()
                return self.mailboxes.first { $0.role == lower || $0.name.lowercased() == lower }?.id
            }
        }
    }

    func reloadList() {
        guard let client, client.session != nil else { return }
        listTask?.cancel()
        let filter = currentFilter()
        let src = source
        let limit = max(60, min(messages.count, 250))
        isLoadingList = true
        listTask = Task {
            defer { if self.source == src { self.isLoadingList = false } }
            do {
                let page = try await client.queryEmails(filter: filter, limit: limit)
                guard !Task.isCancelled, self.source == src else { return }
                self.messages = page.emails
                self.totalInSource = page.total
                if let s = page.emailState { self.emailState = s }
                self.lastSync = Date()
                if case .mailbox(let id) = src { self.cache.save(page.emails, "list-\(id)") }
                self.isOnline = true
                self.notifyNew(page.emails)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.report(error) }
            }
        }
    }

    func loadMoreIfNeeded(current row: EmailSummary) {
        guard let client, !isLoadingList,
              row.id == messages.last?.id,
              messages.count < (totalInSource ?? Int.max) else { return }
        let filter = currentFilter()
        let src = source
        let position = messages.count
        isLoadingList = true
        Task {
            defer { self.isLoadingList = false }
            do {
                let page = try await client.queryEmails(filter: filter, position: position, limit: 80)
                guard self.source == src else { return }
                let known = Set(self.messages.map(\.id))
                self.messages += page.emails.filter { !known.contains($0.id) }
            } catch { self.report(error) }
        }
    }

    // MARK: Push sync

    private func startPush() {
        pushTask?.cancel()
        guard let client else { return }
        pushTask = Task {
            for await types in client.pushEvents() {
                if types.contains("Email") || types.contains("Mailbox") || types.contains("Thread") {
                    self.scheduleRefresh()
                }
            }
        }
    }

    /// Coalesces bursts of push events into a single round trip.
    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self.syncNow()
        }
    }

    func syncNow() async {
        guard let client, client.session != nil else { return }
        lastSync = Date()
        do {
            async let boxes = client.mailboxes()   // runs alongside the delta sync
            if let state = emailState {
                var since = state
                var changedThreads = Set<String>()
                var more = true
                while more {
                    let changes = try await client.emailChanges(since: since)
                    let changed = try await client.summaries(ids: changes.changed)
                    changedThreads.formUnion(changed.map(\.threadId))
                    let destroyed = Set(changes.destroyed)
                    if !destroyed.isEmpty || !changed.isEmpty {
                        let byId = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                        messages = messages.compactMap { row in
                            if destroyed.contains(row.id) { return nil }
                            return byId[row.id] ?? row
                        }
                    }
                    notifyNew(changed)
                    since = changes.newState
                    more = changes.hasMoreChanges
                }
                emailState = since
                for t in changedThreads { threadCache[t] = nil }
                if let open = thread.first?.threadId, changedThreads.contains(open) {
                    refreshOpenThread()
                }
            }
            let (mbs, _) = try await boxes
            applyMailboxes(mbs)
            isOnline = true
            lastSync = Date()
            reloadList()
            refreshArrivals()
            refreshStats()
        } catch JMAPError.method("cannotCalculateChanges", _) {
            emailState = nil
            reloadList()
        } catch {
            report(error)
        }
    }

    /// Loads when Inbox mail arrived over the last day. One small request; failures are ignored
    /// because the graph is decoration, not data the user acts on.
    func refreshArrivals() {
        guard !isDemo, UserDefaults.standard.object(forKey: "sidebar.showConditions") as? Bool ?? true,
              let client, let inbox = mailbox(role: "inbox") else { return }
        let since = JMAPDate.string(Date().addingTimeInterval(-24 * 3600))
        Task {
            if let page = try? await client.queryEmails(filter: ["inMailbox": inbox.id, "after": since],
                                                        limit: 250, collapseThreads: false) {
                inboxArrivals = page.emails.map(\.receivedAt)
                inboxRecent = page.emails
            }
        }
    }

    // MARK: Sidebar card stats

    /// Fetches the chosen stats. Cheap stats refresh at most every 5 minutes; the 4-week
    /// history used by "Busiest hours" and "Mail load by folder" at most every 6 hours.
    func refreshStats(force: Bool = false) {
        let chosen = Set(CardStat.selected())
        guard !isDemo, let client, !chosen.isEmpty,
              UserDefaults.standard.object(forKey: "sidebar.showConditions") as? Bool ?? true else { return }
        guard force || Date().timeIntervalSince(statsRefreshedAt) > 300 else { return }
        statsRefreshedAt = Date()
        let inbox = mailbox(role: "inbox"), sent = mailbox(role: "sent")
        let mine = Set(identities.map { $0.email.lowercased() })
        let waitDays = Double(defaults.object(forKey: "card.waitingDays") as? Int ?? 3)
        let now = Date()

        Task {
            if chosen.contains(.oldestUnread), let inbox {
                let page = try? await client.queryEmails(filter: ["inMailbox": inbox.id, "notKeyword": "$seen"],
                                                         limit: 1, collapseThreads: false, oldestFirst: true)
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
                if let total { cardStats.replyDebt = total }
            }
            if chosen.contains(.waiting) || chosen.contains(.responseTime), let sent,
               let r = try? await client.sentWithThreads(sentMailboxId: sent.id,
                                                         since: now.addingTimeInterval(-14 * 86_400), limit: 150) {
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
                cardStats.scheduledSends = count
            }
            if chosen.contains(.busiestHours) || chosen.contains(.folderLoad) {
                if force || now.timeIntervalSince(metaRefreshedAt) > 6 * 3600 {
                    let skip = ["trash", "junk", "drafts", "sent"].compactMap { mailbox(role: $0)?.id }
                    if let meta = try? await client.mailMeta(filter: ["after": JMAPDate.string(now.addingTimeInterval(-28 * 86_400)),
                                                                      "inMailboxOtherThan": skip], limit: 1500) {
                        recentMeta = meta
                        metaRefreshedAt = now
                    }
                }
                cardStats.busiest = MailStats.busiestWindow(recentMeta.map(\.receivedAt))
                let order = ["inbox", "archive"].compactMap { mailbox(role: $0)?.id }
                cardStats.folderLoad = MailStats.folderLoad(recentMeta.filter { $0.receivedAt > now.addingTimeInterval(-7 * 86_400) },
                                                            preferredOrder: order)
            }
        }
    }

    /// Snoozed conversations and when the next one comes back.
    var snoozeSummary: (count: Int, next: Date?) {
        (Set(snoozes.map(\.threadId)).count, snoozes.map(\.until).min())
    }

    /// "Top senders today" → archive what that sender put in the Inbox (undoable).
    func archiveFromSender(_ rows: [EmailSummary], name: String) {
        guard let archive = mailbox(role: "archive"), let inbox = mailbox(role: "inbox"), !rows.isEmpty else { return }
        let ids = Set(rows.map(\.id))
        let viewingInbox = currentMailboxId == inbox.id
        removeRows(rows)
        inboxRecent.removeAll { ids.contains($0.id) }
        Task {
            do {
                let originals = try await relocate(rows, to: archive.id, from: inbox.id)
                showToast("Archived \(rows.count) from \(name)") { [weak self] in
                    guard let self else { return }
                    if self.currentMailboxId == inbox.id { self.restoreRows(rows) }
                    Task {
                        try? await self.client?.updateEmails(originals.mapValues { ["mailboxIds": $0] as [String: Any] })
                        self.refreshArrivals()
                    }
                }
            } catch {
                if viewingInbox { restoreRows(rows) }
                report(error)
            }
            refreshArrivals()
        }
    }

    /// "Top senders today" → unsubscribe using that sender's newest message.
    func unsubscribeFromSender(_ rows: [EmailSummary]) {
        guard let latest = rows.max(by: { $0.receivedAt < $1.receivedAt }), let client else { return }
        Task {
            guard let detail = try? await client.details(ids: [latest.id]).first else {
                return report(JMAPError.notConnected)
            }
            if detail.unsubscribeURL != nil {
                unsubscribe(detail)
            } else {
                showToast("This sender's mail has no unsubscribe link", undo: nil)
            }
        }
    }

    /// Called when the app comes to the front: catch up if push has been quiet for a while.
    func refreshIfStale() {
        guard phase == .ready, Date().timeIntervalSince(lastSync) > 60 else { return }
        scheduleRefresh()
    }

    // MARK: Reading

    var selectedRows: [EmailSummary] { messages.filter { selection.contains($0.id) } }

    func selectionChanged() {
        guard selection.count == 1, let row = selectedRows.first else {
            openedRowId = nil
            if selection.isEmpty { thread = [] }
            return
        }
        // The list view and keyboard navigation can both report the same change;
        // opening twice would cancel and repeat the network request.
        guard row.id != openedRowId else { return }
        openedRowId = row.id
        open(row)
    }

    /// True in Sent and Drafts, where rows should show who the message is to.
    var showsRecipients: Bool {
        guard let id = currentMailboxId, let role = mailbox(id: id)?.role else { return false }
        return role == "sent" || role == "drafts"
    }

    func clearSearch() {
        searchText = ""
        if case .search = source, let inbox = mailbox(role: "inbox") { source = .mailbox(inbox.id) }
    }

    /// Opens a saved draft in the composer.
    func openDraft(_ row: EmailSummary) {
        guard row.isDraft, let client else { return }
        Task {
            guard let detail = try? await client.details(ids: [row.id]).first else { return }
            var d = ComposeDraft(identityId: identities.first {
                $0.email.lowercased() == detail.from?.first?.email.lowercased()
            }?.id ?? defaultIdentity?.id)
            d.to = detail.to?.map(\.formatted).joined(separator: ", ") ?? ""
            d.cc = detail.cc?.map(\.formatted).joined(separator: ", ") ?? ""
            d.bcc = detail.bcc?.map(\.formatted).joined(separator: ", ") ?? ""
            d.showCc = !d.cc.isEmpty || !d.bcc.isEmpty
            d.subject = detail.subject ?? ""
            d.body = detail.plainTextFallback
            d.inReplyTo = detail.inReplyTo?.first
            d.references = detail.references ?? []
            d.savedDraftId = detail.id
            d.forwardedAttachments = detail.visibleAttachments.compactMap { p in
                p.blobId.map { OutgoingAttachment(blobId: $0, name: p.name ?? "attachment", type: p.type, size: p.size ?? 0) }
            }
            composer = d
        }
    }

    func open(_ row: EmailSummary) {
        threadTask?.cancel()
        if let cached = threadCache[row.threadId] {
            showThread(cached)
        } else {
            thread = []
            isLoadingThread = true
        }
        let tid = row.threadId
        threadTask = Task {
            if threadCache[tid] == nil {
                do {
                    let emails = try await client?.thread(tid) ?? []
                    guard !Task.isCancelled else { return }
                    remember(thread: emails, id: tid)
                    if selectedRows.first?.threadId == tid { showThread(emails) }
                } catch {
                    if !Task.isCancelled {
                        openedRowId = nil   // allow a retry by selecting the row again
                        report(error)
                    }
                }
                isLoadingThread = false
            }
            let delay = defaults.double(forKey: "markReadDelay")
            if row.isUnread, delay >= 0 {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled, selection.contains(row.id) else { return }
                setRead(true, rows: [row], showToast: false)
            }
            prefetch(after: row)
        }
    }

    private func showThread(_ emails: [EmailDetail]) {
        expandedOnOpen = Set(emails.filter(\.isUnread).map(\.id))
        thread = emails
    }

    private func refreshOpenThread() {
        guard let tid = thread.first?.threadId, let client else { return }
        Task {
            if let emails = try? await client.thread(tid) {
                remember(thread: emails, id: tid)
                if thread.first?.threadId == tid { thread = emails }
            }
        }
    }

    /// Warm the next two conversations so j/k feels instant.
    private func prefetch(after row: EmailSummary) {
        guard let idx = messages.firstIndex(where: { $0.id == row.id }), let client else { return }
        let next = messages.dropFirst(idx + 1).prefix(2).map(\.threadId).filter { threadCache[$0] == nil }
        for tid in next {
            Task(priority: .utility) {
                if let emails = try? await client.thread(tid) { remember(thread: emails, id: tid) }
            }
        }
    }

    private func remember(thread emails: [EmailDetail], id: String) {
        threadCache[id] = emails
        threadCacheOrder.removeAll { $0 == id }
        threadCacheOrder.append(id)
        while threadCacheOrder.count > 40 {
            threadCache[threadCacheOrder.removeFirst()] = nil
        }
    }

    func moveSelection(_ delta: Int) {
        guard !messages.isEmpty else { return }
        let current = messages.firstIndex { selection.contains($0.id) } ?? (delta > 0 ? -1 : messages.count)
        let next = min(max(current + delta, 0), messages.count - 1)
        selection = [messages[next].id]
        selectionChanged()
    }

    // MARK: Actions (optimistic, undoable)

    private func targets(_ rows: [EmailSummary]?) -> [EmailSummary] {
        rows ?? selectedRows
    }

    /// Removes rows from the list and advances selection to the next message.
    private func removeRows(_ rows: [EmailSummary]) {
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

    private func restoreRows(_ rows: [EmailSummary]) {
        let known = Set(messages.map(\.id))
        messages = (messages + rows.filter { !known.contains($0.id) }).sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Applies a patch to every message in the given conversations.
    private func patchThreads(_ rows: [EmailSummary], patch: [String: Any]) async throws {
        guard let client else { return }
        let ids = try await client.emailIds(inThreads: Array(Set(rows.map(\.threadId))))
        try await client.updateEmails(Dictionary(uniqueKeysWithValues: ids.map { ($0, patch) }))
    }

    /// Moves conversations to `targetId` and returns each moved message's previous mailboxes (for undo).
    /// In a mailbox view only the messages in that mailbox move (Sent copies stay put).
    /// In Unread, Flagged and search views, the messages filed alongside the visible row move.
    private func relocate(_ rows: [EmailSummary], to targetId: String,
                          from scopeId: String?) async throws -> [String: [String: Bool]] {
        guard let client else { throw JMAPError.notConnected }
        let all = try await client.summaries(inThreads: Array(Set(rows.map(\.threadId))))
        let rowBoxes = Dictionary(rows.map { ($0.threadId, Set($0.mailboxIds.keys)) },
                                  uniquingKeysWith: { $0.union($1) })
        var originals: [String: [String: Bool]] = [:]
        var patches: [String: [String: Any]] = [:]
        for email in all {
            if let scopeId {
                guard email.mailboxIds[scopeId] == true else { continue }
                patches[email.id] = ["mailboxIds/\(scopeId)": NSNull(), "mailboxIds/\(targetId)": true]
            } else {
                guard let boxes = rowBoxes[email.threadId],
                      !boxes.isDisjoint(with: email.mailboxIds.keys),
                      email.mailboxIds[targetId] != true else { continue }
                patches[email.id] = ["mailboxIds": [targetId: true]]
            }
            originals[email.id] = email.mailboxIds
        }
        try await client.updateEmails(patches)
        return originals
    }

    func move(_ rows: [EmailSummary]? = nil, to targetId: String, label: String) {
        let rows = targets(rows)
        guard !rows.isEmpty, let client else { return }
        let scope = currentMailboxId
        guard scope != targetId else { return }
        removeRows(rows)
        Task {
            do {
                let originals = try await relocate(rows, to: targetId, from: scope)
                showToast("\(label) \(rows.count == 1 ? "conversation" : "\(rows.count) conversations")") { [weak self] in
                    self?.restoreRows(rows)
                    Task {
                        do {
                            try await client.updateEmails(originals.mapValues { ["mailboxIds": $0] as [String: Any] })
                        } catch {
                            self?.report(error)
                        }
                    }
                }
            } catch {
                restoreRows(rows)
                report(error)
            }
        }
    }

    func archive(_ rows: [EmailSummary]? = nil) {
        guard let archive = mailbox(role: "archive") else { return report(JMAPError.unsupported("No Archive folder.")) }
        move(rows, to: archive.id, label: "Archived")
    }

    func trash(_ rows: [EmailSummary]? = nil) {
        guard let trash = mailbox(role: "trash") else { return }
        if currentMailboxId == trash.id {
            let rows = targets(rows)
            guard !rows.isEmpty, let client else { return }
            removeRows(rows)
            Task {
                do {
                    // Only the copies that are in Trash: other messages of the conversation are kept.
                    let all = try await client.summaries(inThreads: Array(Set(rows.map(\.threadId))))
                    try await client.destroyEmails(all.filter { $0.mailboxIds[trash.id] == true }.map(\.id))
                    showToast("Deleted permanently", undo: nil)
                } catch { restoreRows(rows); report(error) }
            }
        } else {
            move(rows, to: trash.id, label: "Moved to Trash")
        }
    }

    func markSpam(_ rows: [EmailSummary]? = nil) {
        guard let junk = mailbox(role: "junk") else { return }
        move(rows, to: junk.id, label: "Marked as spam")
    }

    func moveToInbox(_ rows: [EmailSummary]? = nil) {
        guard let inbox = mailbox(role: "inbox") else { return }
        move(rows, to: inbox.id, label: "Moved to Inbox")
    }

    private func setKeyword(_ keyword: String, _ on: Bool, rows: [EmailSummary]) {
        let ids = Set(rows.map(\.id))
        for i in messages.indices where ids.contains(messages[i].id) {
            messages[i].keywords[keyword] = on ? true : nil
        }
        for i in thread.indices where rows.contains(where: { $0.threadId == thread[i].threadId }) {
            thread[i].keywords[keyword] = on ? true : nil
        }
    }

    func setRead(_ read: Bool, rows: [EmailSummary]? = nil, showToast toast: Bool = true) {
        let rows = targets(rows)
        guard !rows.isEmpty else { return }
        setKeyword("$seen", read, rows: rows)
        Task {
            do {
                try await patchThreads(rows, patch: ["keywords/$seen": read ? true : NSNull()])
                if toast { showToast(read ? "Marked as read" : "Marked as unread", undo: nil) }
            } catch {
                setKeyword("$seen", !read, rows: rows)
                report(error)
            }
        }
    }

    func toggleRead() {
        let rows = selectedRows
        setRead(rows.contains { $0.isUnread }, rows: rows)
    }

    func toggleFlag() {
        let rows = selectedRows
        guard let client, !rows.isEmpty else { return }
        let flag = !rows.allSatisfy(\.isFlagged)
        setKeyword("$flagged", flag, rows: rows)
        // Flag only the latest message of each conversation, like Fastmail's web client.
        Task {
            do {
                try await client.updateEmails(Dictionary(uniqueKeysWithValues: rows.map {
                    ($0.id, ["keywords/$flagged": flag ? true : NSNull()] as [String: Any])
                }))
            } catch {
                setKeyword("$flagged", !flag, rows: rows)
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

    func snooze(until date: Date, rows: [EmailSummary]? = nil) {
        let rows = targets(rows)
        guard !rows.isEmpty else { return }
        let scope = currentMailboxId
        let returnTo = scope ?? mailbox(role: "inbox")?.id ?? ""
        removeRows(rows)
        Task {
            do {
                let laterId = try await snoozeMailboxId()
                guard scope != laterId else {
                    restoreRows(rows)
                    return showToast("Already snoozed", undo: nil)
                }
                let originals = try await relocate(rows, to: laterId, from: scope)
                snoozes.append(SnoozeEntry(emailIds: Array(originals.keys), threadId: rows[0].threadId,
                                           until: date, returnMailboxId: returnTo))
                cache.save(snoozes, "snoozes")
                let f = DateFormatter()
                f.dateStyle = .medium; f.timeStyle = .short; f.doesRelativeDateFormatting = true
                showToast("Snoozed until \(f.string(from: date))", undo: nil)
            } catch {
                restoreRows(rows)
                report(error)
            }
        }
    }

    private func startSnoozeTimer() {
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.wakeDueSnoozes() }
        }
        wakeDueSnoozes()
    }

    private func wakeDueSnoozes() {
        let now = Date()
        let due = snoozes.filter { $0.until <= now }
        guard !due.isEmpty, let client,
              let laterId = mailboxes.first(where: { $0.name == "Later" && $0.parentId == nil })?.id else { return }
        snoozes.removeAll { $0.until <= now }
        cache.save(snoozes, "snoozes")
        Task {
            var patches: [String: [String: Any]] = [:]
            for entry in due {
                for id in entry.emailIds {
                    patches[id] = ["mailboxIds/\(laterId)": NSNull(),
                                   "mailboxIds/\(entry.returnMailboxId)": true,
                                   "keywords/$seen": NSNull()]
                }
            }
            do { try await client.updateEmails(patches) } catch {
                // Re-queue on failure so nothing is lost.
                snoozes.append(contentsOf: due)
                cache.save(snoozes, "snoozes")
            }
        }
    }

    // MARK: Compose & send

    var defaultIdentity: Identity? {
        let preferred = defaults.string(forKey: "defaultIdentityId")
        return identities.first { $0.id == preferred } ?? identities.first
    }

    func compose() {
        composer = ComposeDraft(identityId: defaultIdentity?.id)
    }

    func reply(all: Bool, to email: EmailDetail? = nil) {
        guard let original = email ?? thread.last else { return }
        let me = Set(identities.map { $0.email.lowercased() })
        var to = original.replyTo ?? original.from ?? []
        var cc: [EmailAddress] = []
        if all {
            let others = ((original.to ?? []) + (original.cc ?? [])).filter { !me.contains($0.email.lowercased()) }
            if to.allSatisfy({ me.contains($0.email.lowercased()) }) { to = original.to ?? [] }
            cc = others.filter { o in !to.contains { $0.email.lowercased() == o.email.lowercased() } }
        }
        let identity = identities.first { id in
            ((original.to ?? []) + (original.cc ?? [])).contains { $0.email.lowercased() == id.email.lowercased() }
        } ?? defaultIdentity
        var d = ComposeDraft(identityId: identity?.id)
        d.to = to.map(\.formatted).joined(separator: ", ")
        d.cc = cc.map(\.formatted).joined(separator: ", ")
        d.showCc = !cc.isEmpty
        d.subject = Self.prefixed("Re:", original.subject)
        d.body = "\n\n" + Self.quote(original)
        d.inReplyTo = original.messageId?.first
        d.references = (original.references ?? []) + (original.messageId ?? [])
        d.replyingToEmailId = original.id
        composer = d
    }

    func forward(_ email: EmailDetail? = nil) {
        guard let original = email ?? thread.last else { return }
        var d = ComposeDraft(identityId: defaultIdentity?.id)
        d.subject = Self.prefixed("Fwd:", original.subject)
        let header = """
        ---------- Forwarded message ----------
        From: \(original.from?.map(\.formatted).joined(separator: ", ") ?? "")
        Date: \(original.receivedAt.formatted(date: .abbreviated, time: .shortened))
        Subject: \(original.subject ?? "")
        To: \(original.to?.map(\.formatted).joined(separator: ", ") ?? "")
        """
        d.body = "\n\n\(header)\n\n\(original.plainTextFallback)"
        d.replyingToEmailId = original.id
        d.isForward = true
        d.forwardedAttachments = original.visibleAttachments.compactMap { part in
            guard let blob = part.blobId else { return nil }
            return OutgoingAttachment(blobId: blob, name: part.name ?? "attachment",
                                      type: part.type, size: part.size ?? 0)
        }
        composer = d
    }

    static func prefixed(_ prefix: String, _ subject: String?) -> String {
        let s = subject ?? ""
        return s.lowercased().hasPrefix(prefix.lowercased()) ? s : "\(prefix) \(s)"
    }

    static func quote(_ email: EmailDetail) -> String {
        let who = email.from?.first?.formatted ?? "someone"
        let when = email.receivedAt.formatted(date: .abbreviated, time: .shortened)
        let quoted = email.plainTextFallback
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> \($0)" }.joined(separator: "\n")
        return "On \(when), \(who) wrote:\n\(quoted)"
    }

    /// Queues a send with an undo window (Gmail/Superhuman-style "Undo Send").
    func send(_ draft: ComposeDraft, sendAt: Date? = nil) {
        guard let identity = identities.first(where: { $0.id == draft.identityId }) ?? defaultIdentity else {
            return report(JMAPError.unsupported("No sending identity available."))
        }
        let message = draft.outgoing(from: identity.address)
        guard !message.to.isEmpty || !message.cc.isEmpty || !message.bcc.isEmpty else {
            return report(JMAPError.unsupported("Add at least one recipient."))
        }
        composer = nil
        flushPendingSend()   // a message still in its undo window goes out now instead of being dropped
        let delay = defaults.object(forKey: "undoSendSeconds") as? Double ?? 10
        let pending = PendingSend(message: message, deadline: Date().addingTimeInterval(delay), sendAt: sendAt,
                                  draftId: draft.savedDraftId, identity: identity)
        pendingSend = pending
        sendTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, pendingSend?.id == pending.id else { return }
            pendingSend = nil
            await deliver(pending)
        }
    }

    /// Sends the queued message immediately. Returns the delivery task (nil if nothing was queued).
    @discardableResult
    func flushPendingSend() -> Task<Bool, Never>? {
        guard let pending = pendingSend else { return nil }
        sendTask?.cancel()
        pendingSend = nil
        return Task { await deliver(pending) }
    }

    func undoSend() {
        guard let pending = pendingSend else { return }
        sendTask?.cancel()
        pendingSend = nil
        reopen(pending)
    }

    private func reopen(_ pending: PendingSend) {
        var d = ComposeDraft(identityId: pending.identity.id)
        d.restore(from: pending.message)
        d.savedDraftId = pending.draftId
        composer = d
    }

    @discardableResult
    private func deliver(_ pending: PendingSend) async -> Bool {
        guard let client, let drafts = mailbox(role: "drafts"), let sent = mailbox(role: "sent") else {
            report(JMAPError.notConnected)
            reopen(pending)
            return false
        }
        do {
            try await client.send(pending.message, identityId: pending.identity.id,
                                  draftsId: drafts.id, sentId: sent.id,
                                  replacingDraft: pending.draftId, sendAt: pending.sendAt)
            if let at = pending.sendAt {
                showToast("Scheduled for \(at.formatted(date: .abbreviated, time: .shortened))", undo: nil)
            } else {
                showToast("Message sent", undo: nil)
            }
            return true
        } catch {
            report(error)
            reopen(pending)
            return false
        }
    }

    func saveDraft(_ draft: ComposeDraft) async -> String? {
        guard let client, let drafts = mailbox(role: "drafts") else { return nil }
        let identity = identities.first { $0.id == draft.identityId } ?? defaultIdentity
        let from = identity?.address ?? EmailAddress(email: client.session?.username ?? "")
        do {
            return try await client.saveDraft(draft.outgoing(from: from), draftsId: drafts.id,
                                              replacing: draft.savedDraftId)
        } catch {
            report(error)
            return nil
        }
    }

    /// People you've corresponded with, for recipient autocomplete (no extra network calls).
    var knownAddresses: [EmailAddress] {
        let mine = Set(identities.map { $0.email.lowercased() })
        var seen = Set<String>()
        var out: [EmailAddress] = []
        let fromThread = thread.flatMap { ($0.from ?? []) + ($0.to ?? []) + ($0.cc ?? []) }
        for addr in fromThread + messages.flatMap({ ($0.from ?? []) + ($0.to ?? []) }) {
            let key = addr.email.lowercased()
            if mine.contains(key) || key.contains("noreply") || key.contains("no-reply") { continue }
            if seen.insert(key).inserted { out.append(addr) }
        }
        return out
    }

    var supportsScheduledSend: Bool { (client?.session?.maxDelayedSend ?? 0) > 0 }

    // MARK: Unsubscribe

    func unsubscribe(_ email: EmailDetail) {
        guard let url = email.unsubscribeURL else { return }
        if email.supportsOneClickUnsubscribe {
            Task {
                do {
                    try await JMAPClient.oneClickUnsubscribe(url)
                    showToast("Unsubscribed", undo: nil)
                } catch { report(error) }
            }
        } else if url.scheme == "mailto" {
            composeMailto(url, defaultSubject: "unsubscribe")
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// Handles mailto: links (Veery Mail can be set as the default mail app).
    func composeMailto(_ url: URL, defaultSubject: String = "") {
        guard url.scheme?.lowercased() == "mailto" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        func item(_ name: String) -> String? {
            comps?.queryItems?.first { $0.name.lowercased() == name }?.value
        }
        var d = ComposeDraft(identityId: defaultIdentity?.id)
        d.to = [comps?.path, item("to")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        d.cc = item("cc") ?? ""
        d.bcc = item("bcc") ?? ""
        d.showCc = !d.cc.isEmpty || !d.bcc.isEmpty
        d.subject = item("subject") ?? defaultSubject
        d.body = item("body") ?? ""
        composer = d
    }

    // MARK: Notifications

    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notifyNew(_ emails: [EmailSummary]) {
        guard notificationsAvailable, defaults.object(forKey: "notifications") as? Bool ?? true,
              let inbox = mailbox(role: "inbox") else { return }
        let fresh = emails.filter {
            $0.mailboxIds[inbox.id] == true && $0.isUnread && $0.receivedAt > launchedAt
                && !notifiedIds.contains($0.id)
        }
        guard !fresh.isEmpty else { return }
        notifiedIds.formUnion(fresh.map(\.id))
        if NSApp.isActive { return }
        for email in fresh.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = email.from?.first?.cleaned.name ?? email.sender
            content.subtitle = email.displaySubject
            content.body = email.preview ?? ""
            content.threadIdentifier = email.threadId
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: email.id, content: content, trigger: nil))
        }
    }

    // MARK: Feedback

    func showToast(_ message: String, undo: (@MainActor () -> Void)?) {
        let t = Toast(message: message, undo: undo)
        toast = t
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if toast?.id == t.id { toast = nil }
        }
    }

    func report(_ error: Error) {
        if error is CancellationError { return }
        if let url = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(url.code) {
            isOnline = false
        }
        lastError = error.localizedDescription
        showToast(error.localizedDescription, undo: nil)
    }
}

extension EmailDetail {
    /// Plain text for quoting: text part if present, otherwise HTML stripped of tags.
    var plainTextFallback: String {
        let text = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        guard let html, let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else { return preview ?? "" }
        return attributed.string
    }
}
