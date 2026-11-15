# Veery Mail Privacy Policy (draft)

_Draft for review. Last updated: <DATE_PLACEHOLDER>. Contact: <SUPPORT_EMAIL_PLACEHOLDER>._

Veery Mail is an independent Mac app for reading and sending your Fastmail email. It is not made, endorsed or supported by Fastmail Pty Ltd. This policy explains what the app does with your data. In short: your mail goes between your Mac and Fastmail, and the developer of Veery Mail never receives it.

## Who processes your data

- **You and your Mac.** Veery Mail runs entirely on your Mac. There is no Veery Mail server, account or analytics service.
- **Fastmail.** Veery Mail connects directly to Fastmail's JMAP API to read, organize and send your mail and to read your contacts. Fastmail's own [privacy policy](https://www.fastmail.com/policies/privacy/) applies to that data.
- **An AI provider you choose (optional, off by default).** See "Optional AI features" below.

The developer of Veery Mail does not collect, receive, sell or share your mail, contacts, sign-in tokens or usage.

## What Veery Mail accesses, and why

Veery Mail asks Fastmail only for the access it needs for features you use:

| Access | Used for |
| --- | --- |
| Mail (`urn:ietf:params:oauth:scope:mail`) | Showing, searching, organizing, deleting and sending your mail, drafts and scheduled mail |
| Contacts (`urn:ietf:params:oauth:scope:contacts`, optional) | Suggesting addresses while you type. Turn off in Settings → General → Contacts |
| Offline access (`offline_access`) | Staying signed in without asking again every hour |

Data is used only to provide the features you ask for in the app.

## What is stored on your Mac

- **Sign-in tokens** in the macOS Keychain, available only on this Mac, never synced.
- **A cache** of mailbox names, message lists (headers and previews) and the open conversation, in `~/Library/Application Support/Veery Mail`, kept separately for each account.
- **Unsent mail** waiting in the outbox (for Undo Send, or after a quit), and **snooze records** (which conversations to return and where), in the same folder with file protection.
- **Preferences** (signatures, appearance, AI settings, spending totals) in the app's preferences.
- **AI keys** you enter, in the Keychain.

Remote images in messages are blocked by default, and messages are displayed with JavaScript off and web data kept in memory only.

## Notifications

If you turn on notifications, macOS shows new-mail alerts that include the sender and subject unless you turn that off (Settings → General → Notifications). Notification content is handled by macOS on your Mac.

## Unsubscribe requests

When you choose Unsubscribe on a mailing-list message, Veery Mail either opens the list's page in your browser, starts an unsubscribe email, or (after asking you) sends a single one-click request to the address the list provides. That request contains no cookies, sign-in details or other information about you.

## Optional AI features

AI features are off until you turn them on and add your own key. When you click an AI action (summarize, draft a reply, rewrite), Veery Mail sends the text needed for that action directly from your Mac to the provider you chose: Anthropic, OpenAI, or a server you run yourself. The first time you use each action, the app shows exactly what will be sent. Nothing is sent in the background. Mailboxes and senders you exclude are never sent. That provider's terms and privacy policy apply to what it receives; Veery Mail does not receive a copy.

## Signing out and deleting your data

- **Sign out** (Settings → General) revokes Veery Mail's sign-in with Fastmail, deletes the tokens from the Keychain, and deletes the cached mail for that account. Before signing out you choose whether unsent messages are sent or kept in your Fastmail Drafts, and whether snoozed conversations go back to their mailboxes now. Snooze records you choose to keep stay on your Mac so those conversations can be returned the next time you sign in to that account; delete `~/Library/Application Support/Veery Mail` to remove them.
- **Uninstalling**: delete the app and `~/Library/Application Support/Veery Mail`, and remove "Veery Mail" items from Keychain Access.
- **Revoking access from Fastmail**: Fastmail Settings → Privacy & Security → Connected apps & API tokens.

Because the developer holds none of your data, there is nothing for the developer to delete. If you ask us to delete data related to Veery Mail (for example support emails you sent), we will do so within 14 business days.

## Children

Veery Mail is not directed to children under 13 (or the minimum age in your country).

## Changes

We will update this page and its date when the app's data handling changes.

## Contact

<SUPPORT_EMAIL_PLACEHOLDER>
