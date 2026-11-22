# Veery Mail

Veery Mail is an independent native macOS email client for Fastmail accounts. It connects directly to Fastmail using the standard JMAP protocol.

Veery Mail is developed independently and has no affiliation with or endorsement from Fastmail. Fastmail is a trademark and service mark of Fastmail Pty Ltd.

- SwiftUI with small AppKit/WebKit pieces. **No third-party dependencies.**
- macOS 14 (Sonoma) or later. Builds with Swift 5.10 (Xcode 15.3 or later).

## Why JMAP makes it fast

| What | How |
| --- | --- |
| One round trip per action | Method calls are batched and chained with back-references. For example, `Email/query` and `Email/get` go in one request, and so do `Thread/get` and `Email/get` with the bodies. |
| Instant push | JMAP EventSource (server-sent events). There is no IMAP IDLE connection per folder and no polling. Bursts of events are combined into one sync. |
| Delta sync | `Email/changes` updates only the rows that changed. If the server can't compute changes, it falls back to a full re-query. |
| Instant launch | Mailboxes and list headers are cached as JSON in `~/Library/Application Support/Veery Mail`. The window draws from the cache before the network answers. |
| Small payloads | The list fetches only header properties. Bodies load when you open a conversation. The next two conversations are prefetched so J/K feels instant. Up to 40 threads are kept in memory. |
| Optimistic UI | Archive, delete, read and flag change the UI first, then sync in the background. If the server call fails, the change is rolled back. |

## Features

These come from looking at what Apple Mail, Mimestream, Spark, Airmail, MailMate and Superhuman do well. Each is adapted to Fastmail.

**Design** (tokens in `Sources/VeeryMail/Views/Theme.swift`; review mockups in `docs/design/`)
- An editorial look: ink-blue navigation, a slightly lighter inbox, and a warm paper reader with a copper accent. Light and dark appearances, plus a dim reader for dark rooms (Settings → General).
- **Top row**: Search / command field (⌘K) and New Message on the left; Reply, Reply All, Forward, Archive, Snooze, Flag, Read and Trash on the right. With several rows selected it shows "N selected", because the actions then apply to all of them.
- **Sidebar**, borrowing ideas from weather apps such as Acme Weather and Dark Sky:
  - **Inbox summary card** (hide it under Settings → Summary Card): the unread count as a large numeral, the number of new messages in the last 7 days with the change from the 7 days before ("▲ 12%"), and a bar for each day this week beside the same weekday last week, with today in copper. Hover a day for exact numbers. Counts come from one request of server totals, so no mail is downloaded for them.
  - A visible switch for new-mail alerts.
  - **Up to three extra stats** of your choice (Settings → Summary Card):
    - Oldest unread
    - Streak (days the Inbox reached your target)
    - Waiting on replies
    - Reply debt (read but not answered)
    - Typical response time (this week vs last)
    - Trackers blocked this week
    - Busiest hours
    - Scheduled and snoozed
    - Top senders today, with one-click Archive or Unsubscribe
    - Mail load by folder

    Only the stats you choose are fetched. The streak and tracker counts are kept on your Mac and count only while Veery Mail is running.
  - Favorites, then Archive / Spam / Trash, then a collapsible Folders section.
  - Folders holding unread mail get a thin copper intensity bar, scaled to the busiest folder.
  - Counts sit on the trailing edge, and long names truncate with the full name on hover.
  - An "Updated just now" status sits at the bottom.
- **Inbox**: every row uses one grid. The first line has the sender and the time, the second the subject with reserved slots for the attachment and flag icons, and then one preview line by default.
  - Unread mail has a dot and heavier text.
  - The open conversation has a copper tint and edge.
  - Multi-selected rows, the keyboard cursor and hover each look different.
  - Day labels scroll with the rows, so keyboard navigation always brings the whole row into view.
- **Reader**: one continuous sheet.
  - The subject is set in New York and wraps naturally. Sender, recipients and time share its left edge.
  - Plain text keeps a comfortable line length.
  - Simple HTML mail blends into the sheet. Designed mail keeps its own page and is scaled down to fit when it is wider than the reader.
  - Attachments wrap inside the reader.
- **Clean sender names**: relays such as SimpleLogin rewrite senders as "Jane Doe - jane at example.com". Veery Mail shows "Jane Doe", and the real addresses appear on hover. Sent and Drafts show who the message is to.
- **Accessibility**: default colors meet WCAG 2.2 AA contrast. Surfaces are solid, so nothing depends on transparency. Dividers and muted text strengthen under Increase Contrast, the reader transition respects Reduce Motion, and rows and controls carry VoiceOver labels.

**Demo mode** shows fictional mail with no network, for screenshots and design review:

```bash
open "build/Veery Mail.app" --args -demo YES
```

**Reading**
- Three panes: mailboxes, conversation list, reader. Messages are grouped into conversations (Fastmail threads). The newest message and any unread ones are expanded.
- Privacy-first HTML rendering:
  - JavaScript is off.
  - Remote images and tracking pixels are blocked until you click **Load**.
  - Inline `cid:` images are served from Fastmail.
  - Links open in your browser.
  - Web data is kept in memory only.
- Plain-text messages show clickable links.
- If the remote-content blocking rule can't be installed, the message is shown as plain text instead (the reader fails closed). A Content-Security-Policy on every message page is a second barrier.
- **Unsubscribe** for mailing lists. One-click (RFC 8058) is offered only when the List-Unsubscribe-Post header is covered by a DKIM signature that Fastmail verified; it asks first, then sends one POST with no cookies, credentials or redirects. Otherwise it opens the list's page in your browser or starts an unsubscribe email.
- Attachments: click to open, or right-click and choose **Save As…**.

**Message list formatting** (Settings → Message List, with a live preview)
- Sender, Subject, Preview and Date each have their own style:
  - Font: the system font (Default, Serif, Rounded or Monospaced) or any installed font family.
  - Size: 9–24 pt.
  - Separate weights for read and unread messages: Ultralight to Black.
  - Italic and underline.
  - Color: primary, gray, dim gray, silver, or any custom color.
  - Letter case (UPPERCASE or lowercase) and letter spacing.
  - Each element has its own reset button.
- Layout: the first line shows the sender or the subject; 0–3 preview lines; compact, standard or roomy spacing; three date formats; optional sender avatars and unread dot.
- ⌘= and ⌘− resize all list text together. ⌘0 restores the default sizes and keeps your other choices.

**Sidebar**
- Folders that have subfolders collapse and expand with the arrow, and Veery Mail remembers which ones you collapsed.
- A collapsed folder's badge adds the unread count of its subfolders, shown in silver.
- Right-click the sidebar for Expand All Folders or Collapse All Folders.

**Triage**
- Single-key shortcuts in the style of Gmail and Superhuman (see below).
- Swipe actions with the trackpad: archive or trash on one side, read/unread on the other.
- Drag conversations onto a mailbox in the sidebar.
- **Undo** for archive, trash, spam and move. Changes are applied per message: if some fail, the toast says so ("2 of 3 conversations archived") and Undo reverts only what actually changed, without touching labels you added elsewhere.
- **Delete Permanently…** (⌥⌘⌫, or right-click in Trash) is a separate, confirmed action. Delete and # in Trash never destroy mail. If a message in Trash is also filed in another mailbox, you choose whether to delete only the Trash copy.
- Mailboxes light up while you drag conversations over them.
- **Snooze**: Later Today, Tomorrow, This Weekend, Next Week. Each snooze is recorded on disk before anything moves, so a quit, crash or failed wake-up is picked up at the next launch and retried.
- Smart views: **Unread** and **Flagged**.
- **⌘K command palette**: fuzzy-match any action, mailbox or "Move to…", or start a search.

**Search** (runs on Fastmail's servers and covers all mail except Trash and Spam)

```
from:alice to:bob cc:carol subject:"q3 plan" body:invoice
has:attachment is:unread is:read is:flagged in:archive
after:2026-01-01 before:2026-02-01 newer_than:7d older_than:1y
```

**Writing**
- Each message opens in **its own window**, which you can move anywhere and keep beside the inbox.
- **Formatting**: bold, italic, underline, strikethrough, size, color, bulleted and numbered lists, quotes and links. Messages are sent as HTML with a plain-text alternative by default; Settings → General → Sending can switch to plain text only.
- **Emoji**: a searchable picker with every emoji category, country flags and recents, plus the full system Character Viewer.
- **Signatures** per sending address (Settings → Signatures), for new messages and/or replies. Changing the From address swaps the signature.
- **Save Draft** (⌘S) saves to Fastmail and closes the window. If the save fails, the window stays open with your text and the error. Closing a window with unsaved edits saves first. Drafts also autosave every 20 seconds, including recipient-only or attachment-only drafts.
- **Recipients** are checked as you type: names with commas, quoted names, pasted lists across several lines and Bcc-only messages all work, and Send is disabled while any entry isn't a valid address.
- **Contacts** shows your Fastmail address book, recent correspondence, and quick access to composing a message. Add a contact from this tab or from the message reader.
- **Calendar** shows today's schedule and the next seven days. Connect calendars already configured on your Mac, then create events directly or from a message. Links back to mail are kept on this Mac.

- **Autocomplete** from your Fastmail contacts (JMAP Contacts) and people you've exchanged mail with.
- **Undo Send** (5–30 seconds). Each message has its own countdown, so sending two messages close together keeps both undoable. Messages wait in an on-disk outbox, so quitting or crashing never loses one: at the next launch it is held for you to send or edit, and a send that was in progress is checked against your Sent mailbox before anything is sent again (no duplicates).
- **Send Later**: Fastmail's scheduled send, using JMAP `HOLDUNTIL`.
- Multiple sending identities. Forwards include the original attachments without downloading them again. Handles `mailto:` links.

**Optional AI** (off by default; Settings → AI)
- Summarize a conversation (⌥⌘Y), draft a reply from a short instruction, or rewrite selected text (shorter, friendlier, more formal, fix grammar).
- Uses your own key with Anthropic (default model Claude Opus 5.5) or OpenAI, or a local OpenAI-compatible server such as Ollama. Nothing is sent until you click an AI action, and each action shows exactly what will be sent the first time.
- A monthly spending limit, mailboxes and senders that are never sent, and keys stored in the Keychain.

**Optional Fastmail account feature**
- **Masked Email manager** (⇧⌘M): search, create, copy, block or unblock masked addresses when available to the account and authorized by the user. Standard mail features work without this permission.

**Mac integration**
- Notifications for new Inbox mail, shown only when the app is in the background.
- Unread count on the Dock icon.
- Dark appearance is the default; Settings → General → Appearance switches to Light or Match System.
- Native menus and standard shortcuts.
- Sign-in tokens are stored in the Keychain, available only on this Mac.

## Keyboard shortcuts

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `J` / `K` | Next / previous | `C` / ⌘N | Compose |
| `E` or `Y` | Archive | `R` / `A` / `F` | Reply / Reply all / Forward |
| `#` or ⌫ | Trash | `S` | Flag |
| `!` | Spam | `U` | Toggle read |
| `H` | Snooze until tomorrow | `I` | Move to Inbox |
| `/` or ⌘K | Command palette | Esc | Clear selection |
| ⌘↩ | Send | ⌘Z | Undo (after an action or send) |
| ⌘S | Save draft and close | ⌥⌘⌫ | Delete permanently (asks first) |
| ⌥⌘Y | Summarize with AI | ⌥⌘D | Draft reply with AI (compose) |

## Download and install

Support: <SUPPORT_EMAIL_PLACEHOLDER>

1. Download `Veery-Mail.zip` from the latest release and double-click it to unzip.
2. Drag **Veery Mail** into your **Applications** folder.
3. Open it from Applications. Signed and notarized releases open normally. If you were given an unsigned test build, right-click the app, choose **Open**, then **Open** again (needed only the first time).
4. Choose **Sign in with Fastmail**. Your browser opens Fastmail's own sign-in page; approve access there, then return to Veery Mail. Veery Mail never sees your password.
5. To remove Veery Mail's access later: Fastmail **Settings → Privacy & Security → Connected apps & API tokens**, then remove Veery Mail. Signing out in Veery Mail (Settings → General) also revokes its sign-in and deletes its cached mail from your Mac.

Requires macOS 14 (Sonoma) or later. Privacy policy: [docs/PRIVACY.md](docs/PRIVACY.md). User agreement: [docs/TERMS.md](docs/TERMS.md).

## Development setup

```bash
./scripts/build-app.sh      # produces "build/Veery Mail.app" (ad-hoc signed)
open "build/Veery Mail.app"
swift test                  # core library tests
```

For development you can also use `swift run VeeryMail`, or open `Package.swift` in Xcode and press ⌘R. When run outside an app bundle, notifications are turned off. Signed, notarized releases: see [docs/RELEASING.md](docs/RELEASING.md). CI (`.github/workflows/ci.yml`) builds, tests and bundles on macOS runners for every push.

**Sign in with an API token (development alternative).** The sign-in screen has a "Use an API token instead" section with these steps. Fastmail's Basic plans do not include API tokens.
1. In Fastmail go to [Settings → Privacy & Security](https://app.fastmail.com/settings/security), find **Connected apps & API tokens** and click **Manage API tokens**.
2. Click **New API token**, name it (for example "Veery Mail on my Mac"), and under **Type** choose **JMAP**.
3. Under **Scopes**, turn on **Email**, **Email submission**, **Contacts** (for autocomplete) and, if you use it, **Masked Email**. Leave **Read-only access** off.
4. Click **Generate API token**, copy it (it starts with `fmu1-` and is shown once), paste it into Veery Mail and choose **Sign In with Token**. Keep it out of source control, screenshots and issue reports.

Masked Email is only offered when the account grants it (API-token sign-in). Fastmail's public OAuth scopes don't include it.

## App icon

<img src="Resources/Icon/AppIcon-512.png" width="128" alt="Veery Mail icon">

The source is `Resources/Icon/AppIcon.svg`: a brushed-silver veery, a North American woodland thrush, perched upright on a branch on a black tile. It has the veery's long legs, long tail, pale eye-ring and faint spots on the upper breast. `Resources/AppIcon.icns` is rendered from it at 16–1024 px, and `scripts/build-app.sh` copies it into the app bundle. If Finder or the Dock still shows the old icon after a rebuild, run `killall Dock`.

## Layout

```
Sources/VeeryMailCore/     No UI. Tested on its own with a mock transport, a controllable clock and temporary storage.
  JMAPClient.swift       Session, batching, query/get/set/changes, submission, blobs, EventSource, contacts
  Outbox.swift           Durable outbox: undo windows, submission, reconciliation after a quit or timeout
  DraftSaving.swift      Serialized draft saves that never lose edits made during a save
  Mutations.swift        Per-message moves with exact Undo, permanent-delete plans, snooze records
  Recipients.swift       Address parsing and validation
  Privacy.swift          One-click unsubscribe policy and request, fail-closed HTML rendering
  OAuth.swift            Fastmail OAuth (discovery, registration, PKCE, refresh rotation, revoke)
  AI.swift               Providers, prompt building, streaming parsers, spending ledger
  Models.swift, SearchQuery.swift, LocalStore.swift
Sources/VeeryMail/
  App/                   MailStore (+Actions, +Compose), AI service, app entry point and quit handling
  Views/                 Sidebar/list, reader, compose window, rich text editor, emoji picker, settings
```

## Known limitations

- **Snooze** moves the conversation to a `Later` mailbox and back again. That happens while Veery Mail is running or at the next launch on this Mac; Fastmail's server-side snooze uses a vendor extension that isn't public.
- One Fastmail account at a time. Message bodies are not cached for offline reading.
- Calendar uses the calendars configured on this Mac. To see Fastmail events, add Fastmail to macOS Calendar first.
