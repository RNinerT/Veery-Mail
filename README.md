# Veery Mail

A small, fast, native macOS mail client built only for **Fastmail**. It uses Fastmail's own protocol (JMAP), not IMAP.

- SwiftUI with small AppKit/WebKit pieces. **No third-party dependencies.**
- macOS 14 (Sonoma) or later. Builds with Swift 5.10 (Xcode 15.3 or later).
- About 3,900 lines of Swift, including tests.

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
  - **Inbox conditions card** (hide it under Settings → Summary Card): the unread count as a large numeral, a one-word condition (Clear, Light, Steady, Busy, Stormy), and a forecast-style sentence ("3 new in the last hour · 12 today").
  - A 24-hour graph of when mail arrived, with the current hour in copper.
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
- **Unsubscribe banner** for mailing lists. It uses RFC 8058 one-click unsubscribe when the list supports it, and otherwise falls back to mailto or the web page. Your Fastmail credentials are never sent to the list.
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
- **Undo** for archive, trash, spam and move.
- **Snooze**: Later Today, Tomorrow, This Weekend, Next Week.
- Smart views: **Unread** and **Flagged**.
- **⌘K command palette**: fuzzy-match any action, mailbox or "Move to…", or start a search.

**Search** (runs on Fastmail's servers and covers all mail except Trash and Spam)

```
from:alice to:bob cc:carol subject:"q3 plan" body:invoice
has:attachment is:unread is:read is:flagged in:archive
after:2026-01-01 before:2026-02-01 newer_than:7d older_than:1y
```

**Writing**
- Compose, reply, reply all and forward. Threading headers are set correctly. Forwards include the original attachments without downloading them again.
- **Undo Send**: a 5–30 second window, set in Settings.
- **Send Later**: Fastmail's scheduled send, using JMAP `HOLDUNTIL`. Choose a preset or pick a date and time.
- Multiple sending identities (your Fastmail aliases). For replies, the From address is chosen automatically from the address the message was sent to.
- Attachments by file picker or drag and drop. They upload straight to Fastmail's blob store.
- Drafts autosave every 20 seconds. Double-click a draft to keep editing it.
- Recipient autocomplete from people you've exchanged mail with. This needs no extra network calls.
- Handles `mailto:` links, so Veery Mail can be your default mail app.

**Fastmail-only**
- **Masked Email manager** (⇧⌘M): search, create and copy in one step, and block or unblock addresses.

**Mac integration**
- Notifications for new Inbox mail, shown only when the app is in the background.
- Unread count on the Dock icon.
- Dark appearance is the default; Settings → General → Appearance switches to Light or Match System.
- Native menus and standard shortcuts.
- The API token is stored in the Keychain.

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

## Setup

1. **Create a Fastmail API token.** Veery Mail signs in with a token, not your password, and you can remove the token in Fastmail at any time. API tokens are not available on Fastmail's Basic plans.
   1. Sign in to Fastmail in your browser and go to [Settings → Privacy & Security](https://app.fastmail.com/settings/security).
   2. Find **Connected apps & API tokens** and click **Manage API tokens**. Fastmail may ask for your password to verify it's you.
   3. Click **New API token** and enter a name you will recognize later, such as "Veery Mail on my Mac".
   4. Under **Type**, choose **JMAP** (not MCP).
   5. Under **Scopes**, turn on:
      - **Email**: read, change and delete mail.
      - **Email submission**: send mail. It needs **Email** turned on too.
      - **Masked Email**: for the Masked Email manager.

      Leave **Read-only access** off, because Veery Mail archives, deletes and sends.
   6. Click **Generate API token** and copy the token. Fastmail shows it only once, so copy it before you click **Done**. It starts with `fmu1-`.
   7. Keep it handy for step 3 below.

   Fastmail's own guide is [here](https://www.fastmail.help/hc/en-us/articles/5254602856719). To remove Veery Mail's access later, go back to **Manage API tokens**, click the token, and choose **Remove access**.
2. Build and run:

   ```bash
   ./scripts/build-app.sh      # produces "build/Veery Mail.app" (ad-hoc signed)
   open "build/Veery Mail.app"
   ```

   For development you can use `swift run VeeryMail`, or open `Package.swift` in Xcode and press ⌘R. When run outside an app bundle, notifications are turned off.
3. On the first screen, paste the token and choose **Sign In**. It is saved to your Keychain. The sign-in screen repeats these steps if you need them.

Run the tests (they cover the core library: search parser, models, session and push parsing):

```bash
swift test
```

## App icon

<img src="Resources/Icon/AppIcon-512.png" width="128" alt="Veery Mail icon">

The source is `Resources/Icon/AppIcon.svg`: a brushed-silver veery, a North American woodland thrush, perched upright on a branch on a black tile. It has the veery's long legs, long tail, pale eye-ring and faint spots on the upper breast. `Resources/AppIcon.icns` is rendered from it at 16–1024 px, and `scripts/build-app.sh` copies it into the app bundle. If Finder or the Dock still shows the old icon after a rebuild, run `killall Dock`.

## Layout

```
Sources/VeeryMailCore/     No UI. Can be tested on its own.
  JMAPClient.swift       Session, batching, query/get/set/changes, submission, blobs, EventSource, Masked Email
  Models.swift           Mailbox, EmailSummary (list), EmailDetail (reader), Identity, MaskedEmail
  SearchQuery.swift      Search syntax → JMAP FilterCondition
  LocalStore.swift       JSON disk cache, Keychain, snooze presets
Sources/VeeryMail/
  App/MailStore.swift    @Observable state: sync, optimistic actions with undo, snooze, undo-send, notifications
  App/VeeryMailApp.swift   App entry point, menus and shortcuts
  Views/                 Sidebar/list, reader + WKWebView renderer, compose, ⌘K palette, Masked Email, settings
```

## Known limitations (v0.1)

- **Snooze** moves the conversation to a `Later` mailbox. Veery Mail moves it back when the time comes. This happens only while Veery Mail is running, or at the next launch. Fastmail's own server-side snooze uses a vendor extension that isn't public, so it isn't used here.
- The inbox has hover buttons instead of trackpad swipe actions. The earlier Classic layout was removed.
- The app icon is still black and silver and has not been recolored to match the ink and copper theme.
- You sign in with an API token. "Sign in with Fastmail" (OAuth) would need Fastmail to register Veery Mail as a client.
- Compose sends plain text only. There is no rich-text editor yet.
- One Fastmail account.
- Message bodies are not cached for offline reading. Lists and mailboxes are.
- No calendar or contacts. Fastmail exposes those through JMAP and CalDAV/CardDAV, so they are possible later.

## Ideas for later

- AI triage and summaries with Claude: summarize a thread, draft a reply, sort the inbox.
- Rich-text compose with Markdown → HTML.
- Fastmail contacts for autocomplete (JMAP Contacts).
- Offline body cache in SQLite, with full-text search on the device.
