import AppKit
import Foundation
import Observation
import UserNotifications
import VeeryMailCore

enum ListSource: Hashable {
    case mailbox(String)
    case flagged
    case unread
    case search(String)
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    /// Button shown next to the message ("Undo", "Edit", …).
    var actionTitle: String? = nil
    var action: (@MainActor () -> Void)? = nil

    init(message: String, undo: (@MainActor () -> Void)?) {
        self.message = message
        if let undo { actionTitle = "Undo"; action = undo }
    }

    init(message: String, actionTitle: String, action: @escaping @MainActor () -> Void) {
        self.message = message; self.actionTitle = actionTitle; self.action = action
    }
}

enum AuthMethod: String { case oauth, developerToken }

/// What signing out will leave behind, shown before the user confirms.
struct SignOutReview: Identifiable {
    let id = UUID()
    let unsent: Int
    let snoozed: Int
    let openDrafts: Int
}

/// Single source of truth for the UI. All network calls go through `client`.
///
/// Every signed-in session has a `generation`. Background work captures it and checks it after
/// each suspension point, so work started for a previous session (or account) can never write
/// into the current one.
@MainActor
@Observable
final class MailStore {
    enum Phase { case signedOut, connecting, ready }

    /// The app's single store, for the app delegate and web views.
    static weak var current: MailStore?

    // MARK: Session

    var phase: Phase = .signedOut
    var lastError: String?
    var isOnline = true
    private(set) var client: JMAPClient?
    private(set) var authMethod: AuthMethod?
    private(set) var accountKey: String?
    @ObservationIgnored private(set) var generation = 0

    func isLive(_ gen: Int) -> Bool { gen == generation }

    // MARK: Demo

    private(set) var isDemo = false
    @ObservationIgnored var demoMessages: [EmailSummary] = []

    // MARK: Data

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
    /// Addresses from the user's Fastmail contacts, for recipient autocomplete.
    private(set) var contacts: [EmailAddress] = []

    // MARK: UI state

    var toast: Toast?
    var showCommandPalette = false
    var showMaskedEmail = false
    var searchText = ""
    var pendingPermanentDelete: PendingPermanentDelete?
    var signOutReview: SignOutReview?

    // MARK: Compose and send

    /// Open compose windows, by window id.
    var composeDrafts: [UUID: ComposeDraft] = [:]
    @ObservationIgnored var draftSavers: [UUID: DraftSaveCoordinator] = [:]
    /// Opens a compose window (set by the main window, which has `openWindow`).
    @ObservationIgnored var openComposeWindow: ((UUID) -> Void)?
    /// Compose windows requested before the main window was ready.
    var pendingComposeIds: [UUID] = []
    private(set) var outbox = OutboxController(storage: NullOutboxStorage())

    // MARK: AI

    let ai = AIService()

    // MARK: Internal state

    @ObservationIgnored var emailState: String?
    @ObservationIgnored var threadCache: [String: [EmailDetail]] = [:]
    @ObservationIgnored var threadCacheOrder: [String] = []
    @ObservationIgnored var pushTask: Task<Void, Never>?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var listTask: Task<Void, Never>?
    @ObservationIgnored var threadTask: Task<Void, Never>?
    @ObservationIgnored var connectTask: Task<Void, Never>?
    @ObservationIgnored var snoozeTimer: Timer?
    @ObservationIgnored var cache = DiskCache(namespace: "signed-out")
    @ObservationIgnored var snoozeRecords: [SnoozeRecord] = []
    @ObservationIgnored var snoozeStorage: SnoozeStorage?
    @ObservationIgnored var notifiedIds: Set<String> = []
    @ObservationIgnored var launchedAt = Date()
    /// Increments for every list request; only the newest may apply results or clear the spinner.
    @ObservationIgnored var listRequest = 0
    /// When mail was last confirmed up to date (shown as "Updated …" in the sidebar).
    var lastSync = Date.distantPast
    /// Arrival times of Inbox mail in the last 24 hours, for the sidebar's activity graph.
    /// New mail per day for the summary card's two-week chart.
    var mailVolume: MailVolume?
    @ObservationIgnored var volumeRefreshedAt = Date.distantPast
    /// Inbox mail from the last 24 hours (headers only), for "Top senders today".
    var inboxRecent: [EmailSummary] = []
    /// Values for the optional stats on the sidebar card. Only the stats you've chosen are fetched.
    var cardStats = CardStatValues()
    @ObservationIgnored var statsRefreshedAt = Date.distantPast
    @ObservationIgnored var metaRefreshedAt = Date.distantPast
    @ObservationIgnored var recentMeta: [MailMeta] = []
    @ObservationIgnored var openedRowId: String?

    var defaults: UserDefaults { .standard }

    // MARK: Lifecycle

    init() {
        MailStore.current = self
        // `open "Veery Mail.app" --args -demo YES` shows fictional mail (for screenshots and design review).
        if UserDefaults.standard.bool(forKey: "demo") {
            DemoMail.install(in: self)
            return
        }
        if let saved = AuthStore.loadOAuth() {
            startOAuth(tokens: saved.tokens, metadata: saved.metadata)
        } else if let token = Keychain.token() {
            start(credentials: StaticTokenCredentials(token: token), method: .developerToken, persistToken: nil)
        }
    }

    func installDemo(mailboxes: [Mailbox], identities: [Identity], messages: [EmailSummary], threads: [[EmailDetail]]) {
        isDemo = true
        adoptAccount("demo", paintFromCache: false)
        self.mailboxes = mailboxes
        self.identities = identities
        demoMessages = messages
        for thread in threads {
            if let id = thread.first?.threadId { threadCache[id] = thread }
        }
        totalInSource = messages.count
        lastSync = Date().addingTimeInterval(-90)
        mailVolume = MailVolume.demo()
        inboxRecent = messages.filter { $0.receivedAt > Date().addingTimeInterval(-86_400) }
        cardStats = CardStatValues.demo(messages: messages)
        outbox.sender = DemoOutboxSender()
        if let inbox = mailbox(role: "inbox") { source = .mailbox(inbox.id) }
        phase = .ready
    }

    /// Developer path: a personal API token.
    func signIn(token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        start(credentials: StaticTokenCredentials(token: trimmed), method: .developerToken, persistToken: trimmed)
    }

    /// After "Sign in with Fastmail" completes.
    func startOAuth(tokens: OAuthTokens, metadata: OAuthServerMetadata) {
        let credentials = OAuthCredentials(
            tokens: tokens, metadata: metadata, oauth: FastmailOAuth(), store: KeychainTokenStore(),
            onSignedOut: { [weak self] error in
                Task { @MainActor in self?.authorizationExpired(error) }
            })
        start(credentials: credentials, method: .oauth, persistToken: nil)
    }

    private func start(credentials: CredentialProvider, method: AuthMethod, persistToken: String?) {
        generation += 1
        let gen = generation
        resetAccountState()
        let client = JMAPClient(credentials: credentials)
        self.client = client
        authMethod = method
        phase = .connecting
        lastError = nil
        // Paint instantly from the last account's cache. If the server reports a different
        // account, everything is cleared before anything from it is shown.
        if let last = defaults.string(forKey: "lastAccountKey") {
            adoptAccount(last, paintFromCache: true)
        }
        connect(client, gen: gen, persistToken: persistToken, attempt: 0)
    }

    /// Connects to Fastmail. With saved credentials it retries with backoff, so launching
    /// offline (or before Wi-Fi is up) recovers on its own.
    private func connect(_ client: JMAPClient, gen: Int, persistToken: String?, attempt: Int) {
        connectTask?.cancel()
        connectTask = Task {
            do {
                try await client.connect()
                guard isLive(gen) else { return }
                guard let key = client.accountKey else {
                    throw JMAPError.unsupported("This Fastmail sign-in doesn’t include access to mail.")
                }
                if key != accountKey {
                    // Don't cancel this task: it is the connection that just succeeded.
                    resetAccountState(keepConnection: true)
                    adoptAccount(key, paintFromCache: false)
                }
                defaults.set(key, forKey: "lastAccountKey")
                if let persistToken { try Keychain.save(token: persistToken) }
                async let boxes = client.mailboxes()
                async let ids = client.identities()
                let (mbs, _) = try await boxes
                let identityList = (try? await ids) ?? []
                guard isLive(gen) else { return }
                applyMailboxes(mbs)
                identities = identityList
                if case .mailbox(let id) = source, mailboxes.contains(where: { $0.id == id }) {
                    reloadList()
                } else if let inbox = mailbox(role: "inbox") {
                    source = .mailbox(inbox.id)
                }
                phase = .ready
                isOnline = true
                lastError = nil
                lastSync = Date()
                configureOutboxSender()
                outbox.resume()
                refreshArrivals(force: true)
                refreshStats(force: true)
                requestNotificationPermission()
                startPush(gen)
                startSnoozes(gen)
                loadContacts(gen)
            } catch {
                guard isLive(gen), !Task.isCancelled else { return }
                lastError = error.localizedDescription
                isOnline = false
                if case JMAPError.http(401, _) = error {
                    if authMethod == .developerToken { Keychain.delete() }
                    phase = .signedOut
                    return
                }
                if phase == .connecting { phase = mailboxes.isEmpty ? .signedOut : .ready }
                guard persistToken == nil else { return }   // a fresh sign-in shows its error instead of retrying
                let delay = min(5 * pow(2, Double(attempt)), 120)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if isLive(gen), client.session == nil {
                    connect(client, gen: gen, persistToken: persistToken, attempt: attempt + 1)
                }
            }
        }
    }

    /// Switches local storage to an account: cache, outbox, snoozes, contacts.
    func adoptAccount(_ key: String, paintFromCache: Bool) {
        accountKey = key
        cache = DiskCache(namespace: AccountStorage.namespace(for: key))
        let records = AccountStorage.recordsDirectory(for: key)
        outbox = OutboxController(storage: isDemo ? NullOutboxStorage() : FileOutboxStorage(url: records.appendingPathComponent("outbox.json")))
        outbox.onEvent = { [weak self] event in self?.handleOutboxEvent(event) }
        if !isDemo { outbox.load() }
        let snoozeStore = FileSnoozeStorage(url: records.appendingPathComponent("snoozes.json"))
        snoozeStorage = isDemo ? nil : snoozeStore
        snoozeRecords = isDemo ? [] : snoozeStore.load()
        contacts = cache.load([EmailAddress].self, "contacts") ?? []
        guard paintFromCache, let cachedBoxes = cache.load([Mailbox].self, "mailboxes"), !cachedBoxes.isEmpty else { return }
        mailboxes = cachedBoxes
        if let inbox = mailbox(role: "inbox") {
            source = .mailbox(inbox.id)
            messages = cache.load([EmailSummary].self, "list-\(inbox.id)") ?? []
        }
        phase = .ready
    }

    /// Cancels all background work and forgets everything derived from the current account.
    private func resetAccountState(keepConnection: Bool = false) {
        for task in [pushTask, refreshTask, listTask, threadTask] { task?.cancel() }
        if !keepConnection { connectTask?.cancel() }
        pushTask = nil; refreshTask = nil; listTask = nil; threadTask = nil
        snoozeTimer?.invalidate(); snoozeTimer = nil
        outbox.shutdown()
        mailboxes = []; identities = []; messages = []; thread = []; selection = []; contacts = []
        sourceStorage = .mailbox("")
        totalInSource = nil; isLoadingList = false; isLoadingThread = false
        emailState = nil; threadCache = [:]; threadCacheOrder = []; openedRowId = nil
        mailVolume = nil; volumeRefreshedAt = .distantPast; inboxRecent = []; cardStats = CardStatValues(); recentMeta = []
        statsRefreshedAt = .distantPast; metaRefreshedAt = .distantPast
        notifiedIds = []; snoozeRecords = []; snoozeStorage = nil
        pendingPermanentDelete = nil
        accountKey = nil
        BodyCache.clear()
        ai.clearAccountState()
    }

    // MARK: Sign-out

    /// Asks first when signing out would leave unsent mail, snoozes or open drafts.
    func requestSignOut() {
        let unsent = outbox.items.filter {
            switch $0.state { case .sentWithProblem: return false; default: return true }
        }.count
        let snoozed = snoozeRecords.filter { !$0.isFinished }.count
        let open = composeDrafts.count
        if unsent == 0 && snoozed == 0 && open == 0 {
            Task { await performSignOut(sendUnsent: false, returnSnoozed: false) }
        } else {
            signOutReview = SignOutReview(unsent: unsent, snoozed: snoozed, openDrafts: open)
        }
    }

    /// - Unsent messages are either sent now or kept as drafts on Fastmail (never dropped).
    /// - Snoozed mail is either returned now or stays in Later; its records are kept on this
    ///   Mac so signing back in to the same account returns it on time.
    /// - Open compose windows are saved as drafts and closed.
    func performSignOut(sendUnsent: Bool, returnSnoozed: Bool) async {
        let gen = generation
        if sendUnsent {
            for item in outbox.items where item.state == .held || item.isInUndoWindow { outbox.sendNow(item.id) }
            _ = await outbox.waitForInFlight(timeout: 20)
        }
        await keepUnsentAsDrafts()
        if returnSnoozed { await wakeAllSnoozesNow() }
        for id in Array(composeDrafts.keys) {
            _ = await saveDraft(id)
            closeComposer(id)
        }
        guard isLive(gen) else { return }
        if authMethod == .oauth, let saved = AuthStore.loadOAuth() {
            await FastmailOAuth().revoke(saved.tokens, metadata: saved.metadata)
        }
        AuthStore.clearOAuth()
        Keychain.delete()
        cache.clear()
        if let key = accountKey {
            try? FileManager.default.removeItem(at: AccountStorage.recordsDirectory(for: key).appendingPathComponent("outbox.json"))
        }
        generation += 1
        resetAccountState()
        client = nil
        authMethod = nil
        defaults.removeObject(forKey: "lastAccountKey")
        phase = .signedOut
        signOutReview = nil
        NSApp.dockTile.badgeLabel = nil
    }

    /// Unsent outbox items without a server draft get one, so signing out never loses them.
    private func keepUnsentAsDrafts() async {
        guard let client, let drafts = mailbox(role: "drafts") else { return }
        for item in outbox.items {
            switch item.state {
            case .queued, .held, .failed:
                if item.serverDraftId == nil {
                    _ = try? await client.createDraft(item.message, draftsId: drafts.id)
                }
                _ = outbox.takeBack(item.id)
            default:
                break
            }
        }
    }

    private func authorizationExpired(_ error: OAuthError) {
        lastError = error.localizedDescription
        outbox.suspendForQuit()
        phase = .signedOut
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

    func applyMailboxes(_ list: [Mailbox]) {
        mailboxes = list
        cache.save(list, "mailboxes")
        let unread = mailbox(role: "inbox")?.unreadThreads ?? 0
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
        if !isDemo, let inbox = mailbox(role: "inbox") { StreakLedger.record(inboxCount: inbox.totalThreads) }
        configureOutboxSender()
    }

    func configureOutboxSender() {
        guard !isDemo, let client, let drafts = mailbox(role: "drafts"), let sent = mailbox(role: "sent") else { return }
        outbox.sender = JMAPOutboxSender(client: client, draftsId: drafts.id, sentId: sent.id)
    }

    var supportsMaskedEmail: Bool { client?.session?.supportsMaskedEmail ?? false }

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

    var excludedFromSearch: [String] {
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

    /// Reloads the visible list. A newer request (or another view) always wins: an older
    /// response can't replace the list or clear the newer request's spinner.
    func reloadList() {
        guard let client, client.session != nil else { return }
        listTask?.cancel()
        listRequest += 1
        let req = listRequest, gen = generation
        let filter = currentFilter()
        let src = source
        let limit = max(60, min(messages.count, 250))
        isLoadingList = true
        listTask = Task {
            defer { if self.listRequest == req { self.isLoadingList = false } }
            do {
                let page = try await client.queryEmails(filter: filter, limit: limit)
                guard isLive(gen), listRequest == req, source == src, !Task.isCancelled else { return }
                messages = page.emails
                totalInSource = page.total
                if let s = page.emailState { emailState = s }
                lastSync = Date()
                if case .mailbox(let id) = src { cache.save(page.emails, "list-\(id)") }
                isOnline = true
                notifyNew(page.emails)
            } catch is CancellationError {
            } catch {
                if isLive(gen), listRequest == req, !Task.isCancelled { report(error) }
            }
        }
    }

    func loadMoreIfNeeded(current row: EmailSummary) {
        guard let client, !isLoadingList,
              row.id == messages.last?.id,
              messages.count < (totalInSource ?? Int.max) else { return }
        listRequest += 1
        let req = listRequest, gen = generation
        let filter = currentFilter()
        let src = source
        let position = messages.count
        isLoadingList = true
        listTask = Task {
            defer { if self.listRequest == req { self.isLoadingList = false } }
            do {
                let page = try await client.queryEmails(filter: filter, position: position, limit: 80)
                // Only append to the exact list this page continues.
                guard isLive(gen), listRequest == req, source == src, messages.count == position else { return }
                let known = Set(messages.map(\.id))
                messages += page.emails.filter { !known.contains($0.id) }
            } catch {
                if isLive(gen), listRequest == req { report(error) }
            }
        }
    }

    // MARK: Push sync

    private func startPush(_ gen: Int) {
        pushTask?.cancel()
        guard let client else { return }
        pushTask = Task {
            for await types in client.pushEvents() {
                guard isLive(gen) else { break }
                if types.contains("Email") || types.contains("Mailbox") || types.contains("Thread") {
                    scheduleRefresh()
                }
            }
        }
    }

    /// Coalesces bursts of push events into a single round trip.
    func scheduleRefresh() {
        refreshTask?.cancel()
        let gen = generation
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, isLive(gen) else { return }
            await syncNow()
        }
    }

    func syncNow() async {
        guard let client, client.session != nil else { return }
        let gen = generation
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
                    guard isLive(gen) else { return }
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
            guard isLive(gen) else { return }
            applyMailboxes(mbs)
            isOnline = true
            lastSync = Date()
            reloadList()
            refreshArrivals()
            refreshStats()
        } catch JMAPError.method("cannotCalculateChanges", _) {
            guard isLive(gen) else { return }
            emailState = nil
            reloadList()
        } catch {
            if isLive(gen) { report(error) }
        }
    }

    /// Called when the app comes to the front: catch up if push has been quiet for a while.
    func refreshIfStale() {
        guard phase == .ready, !isDemo, Date().timeIntervalSince(lastSync) > 60 else { return }
        scheduleRefresh()
    }

    // MARK: Contacts

    private func loadContacts(_ gen: Int) {
        guard let client, defaults.object(forKey: "contacts.enabled") as? Bool ?? true else { return }
        Task {
            guard let list = try? await client.contacts(), isLive(gen) else { return }
            contacts = list
            cache.save(list, "contacts")
        }
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

    func open(_ row: EmailSummary) {
        threadTask?.cancel()
        if let cached = threadCache[row.threadId] {
            showThread(cached)
        } else {
            thread = []
            isLoadingThread = true
        }
        let tid = row.threadId, gen = generation
        threadTask = Task {
            if threadCache[tid] == nil {
                do {
                    let emails = try await client?.thread(tid) ?? []
                    guard !Task.isCancelled, isLive(gen) else { return }
                    remember(thread: emails, id: tid)
                    if selectedRows.first?.threadId == tid { showThread(emails) }
                } catch {
                    if !Task.isCancelled, isLive(gen) {
                        openedRowId = nil   // allow a retry by selecting the row again
                        report(error)
                    }
                }
                if isLive(gen) { isLoadingThread = false }
            }
            let delay = defaults.double(forKey: "markReadDelay")
            if row.isUnread, delay >= 0 {
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled, isLive(gen), selection.contains(row.id) else { return }
                setRead(true, rows: [row], showToast: false)
            }
            prefetch(after: row, gen: gen)
        }
    }

    private func showThread(_ emails: [EmailDetail]) {
        expandedOnOpen = Set(emails.filter(\.isUnread).map(\.id))
        thread = emails
    }

    func refreshOpenThread() {
        guard let tid = thread.first?.threadId, let client else { return }
        let gen = generation
        Task {
            if let emails = try? await client.thread(tid), isLive(gen) {
                remember(thread: emails, id: tid)
                if thread.first?.threadId == tid { thread = emails }
            }
        }
    }

    /// Warm the next two conversations so j/k feels instant.
    private func prefetch(after row: EmailSummary, gen: Int) {
        guard let idx = messages.firstIndex(where: { $0.id == row.id }), let client else { return }
        let next = messages.dropFirst(idx + 1).prefix(2).map(\.threadId).filter { threadCache[$0] == nil }
        for tid in next {
            Task(priority: .utility) {
                if let emails = try? await client.thread(tid), isLive(gen) { remember(thread: emails, id: tid) }
            }
        }
    }

    func remember(thread emails: [EmailDetail], id: String) {
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

    // MARK: Unsubscribe

    /// Only ever called from an explicit user action. One-click additionally asks for confirmation
    /// in the reader before calling `confirmOneClickUnsubscribe`.
    func unsubscribe(_ email: EmailDetail) {
        switch UnsubscribePolicy.option(for: email) {
        case .oneClick(let url):
            let alert = NSAlert()
            alert.messageText = "Unsubscribe from \(email.from?.first?.displayName ?? url.host ?? "this list")?"
            alert.informativeText = "Veery Mail will send one unsubscribe request to \(url.host ?? "the sender"). "
                + "No cookies, account details or other information are sent with it."
            alert.addButton(withTitle: "Unsubscribe")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { confirmOneClickUnsubscribe(url) }
        case .browser(let url):
            NSWorkspace.shared.open(url)
        case .mailto(let url):
            composeMailto(url, defaultSubject: "unsubscribe")
        case .none:
            showToast("This message has no unsubscribe link.", undo: nil)
        }
    }

    func confirmOneClickUnsubscribe(_ url: URL) {
        Task {
            do {
                try await OneClickUnsubscriber().post(url)
                showToast("Unsubscribed", undo: nil)
            } catch {
                report(error)
            }
        }
    }

    /// "Top senders today" → unsubscribe using that sender's newest message.
    func unsubscribeFromSender(_ rows: [EmailSummary]) {
        guard let latest = rows.max(by: { $0.receivedAt < $1.receivedAt }), let client else { return }
        let gen = generation
        Task {
            guard let detail = try? await client.details(ids: [latest.id]).first, isLive(gen) else {
                return report(JMAPError.notConnected)
            }
            unsubscribe(detail)
        }
    }

    // MARK: Notifications

    private var notificationsAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationPermission() {
        guard notificationsAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyNew(_ emails: [EmailSummary]) {
        guard notificationsAvailable, defaults.object(forKey: "notifications") as? Bool ?? true,
              let inbox = mailbox(role: "inbox") else { return }
        let fresh = emails.filter {
            $0.mailboxIds[inbox.id] == true && $0.isUnread && $0.receivedAt > launchedAt
                && !notifiedIds.contains($0.id)
        }
        guard !fresh.isEmpty else { return }
        notifiedIds.formUnion(fresh.map(\.id))
        if NSApp.isActive { return }
        let showPreview = defaults.object(forKey: "notifications.preview") as? Bool ?? true
        for email in fresh.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = email.from?.first?.cleaned.name ?? email.sender
            if showPreview {
                content.subtitle = email.displaySubject
                content.body = email.preview ?? ""
            } else {
                content.body = "New message"
            }
            content.threadIdentifier = email.threadId
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: email.id, content: content, trigger: nil))
        }
    }

    // MARK: Feedback

    func showToast(_ message: String, undo: (@MainActor () -> Void)?) {
        present(Toast(message: message, undo: undo))
    }

    func present(_ t: Toast) {
        toast = t
        Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
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

/// Used before an account is known (and in demo mode): keeps nothing on disk.
struct NullOutboxStorage: OutboxStorage {
    func load() -> [OutboxItem] { [] }
    func save(_ items: [OutboxItem]) throws {}
}

/// Saved OAuth sign-in: tokens in the Keychain, server metadata (not secret) in preferences.
enum AuthStore {
    static func loadOAuth() -> (tokens: OAuthTokens, metadata: OAuthServerMetadata)? {
        guard let tokens = KeychainTokenStore().load(),
              let data = UserDefaults.standard.data(forKey: "oauth.metadata"),
              let metadata = try? JSONDecoder().decode(OAuthServerMetadata.self, from: data) else { return nil }
        return (tokens, metadata)
    }

    static func saveOAuth(tokens: OAuthTokens, metadata: OAuthServerMetadata) throws {
        try KeychainTokenStore().save(tokens)
        UserDefaults.standard.set(try JSONEncoder().encode(metadata), forKey: "oauth.metadata")
    }

    static func clearOAuth() {
        KeychainTokenStore().clear()
        UserDefaults.standard.removeObject(forKey: "oauth.metadata")
    }
}

extension EmailDetail {
    /// Plain text for quoting and drafts: the text part, or the HTML with tags removed.
    /// Deliberately avoids NSAttributedString's HTML import, which can load remote images.
    var plainTextFallback: String { plainTextFallbackForAI }
}
