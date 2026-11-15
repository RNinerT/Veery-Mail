# Prompt: add AI drafting and replies to Veery Mail

Paste everything below the line into a Claude Code session that has the `RNinerT/Veery-Mail` repository attached.

---

Add optional AI features to Veery Mail, the native macOS Fastmail client in this repository (SwiftUI, macOS 14+, no third-party dependencies). Read `README.md` and the code under `Sources/` before you start, and keep the existing conventions: the `Theme` tokens, `MailStore` as the single store, optimistic actions with undo, the privacy defaults, and plain-language UI text.

## Goal

Users can connect their own AI provider and use it to summarize a conversation, draft a reply, and rewrite text in the compose window. AI is **off by default**, and nothing is ever sent to a provider until the user clicks an AI action.

## Accounts and keys

Consumer Claude and ChatGPT subscriptions cannot be used to sign in from a third-party app. Use each provider's API with a key the user creates, in the same way Veery Mail already uses a Fastmail API token.

1. **Settings → AI** (new tab):
   - A master switch, off by default.
   - Provider choice:
     - **Claude**: Anthropic API, `api.anthropic.com`.
     - **OpenAI**: the OpenAI API behind ChatGPT, `api.openai.com`.
     - **Local model**: an OpenAI-compatible server such as Ollama at `http://localhost:11434`, for fully private use.
   - **Model:** a model picker with a sensible default for each provider. Look up the current model names when you implement this; don't rely on memory. Read the `claude-api` skill for Anthropic details.
   - **Key:** a field to paste the API key, plus a **Test connection** button.
   - **Setup steps:** numbered steps for creating a key, in the style of the Fastmail token steps on the sign-in screen. Say plainly that API usage is billed separately from a Claude or ChatGPT subscription.
2. **Storage:** keep keys in the Keychain, one item per provider, never in UserDefaults or logs.
3. **No server in between:** calls go directly from the Mac to the provider.

## Features, in this order

1. **Summarize conversation:** a button in the reader shows a three-line summary at the top of the sheet. It can be dismissed and is cached per thread for the session.
2. **Draft reply:** a field in the compose window ("What do you want to say?") turns a short instruction into a full reply. It matches the tone of the conversation, using up to three of the user's recent sent messages as style examples. The draft goes into the body for the user to edit.
3. **Rewrite selection:** in compose: Shorter, Friendlier, More formal, Fix grammar. It replaces the selected text, with undo.
4. Optional, behind a "Labs" switch: **Needs a reply?** suggestions in the summary card. Use only data already loaded, and never scan the mailbox in the background.

Put each action in the toolbar or compose window where it fits, in the command palette (⌘K), and give each a keyboard shortcut that doesn't conflict with the existing ones.

## Safety and privacy rules (required)

- **AI never sends mail.** It only writes into the compose window, and Undo Send still applies.
- **Treat email content as untrusted.** Put it inside clearly marked delimiters in the prompt, and tell the model to ignore any instructions in it. The model gets no tools and no ability to act; it returns text only.
- **Send only what the action needs:** the open conversation, trimmed to a size limit. Strip quoted history beyond what's needed, and never send attachments.
- **Exclusions:** let users exclude folders and senders from AI. Respect those exclusions before building any request.
- **First use:** the first time each action is used, show a sheet listing exactly what will be sent and to which provider, with an estimated cost and a "Don't ask again" option.
- **Spending cap:** a monthly cap in Settings. Track usage locally from the token counts the provider returns, and block further calls once the cap is reached.
- **Off switch:** a visible "AI off" switch in the command palette, and a clear error when a key is missing, invalid or out of credit.
- **No logging:** never log prompts, responses or keys.

## Implementation notes

- Add an `AIProvider` protocol in `VeeryMailCore` with small `URLSession` clients for the Anthropic Messages API and the OpenAI Chat Completions API. The local option reuses the OpenAI client with a different base URL.
- Use streaming responses so drafts appear as they're written. Support cancel.
- Keep prompt construction in pure functions in `VeeryMailCore`, with unit tests for delimiting, trimming, exclusions and cost estimation.
- **Demo mode** (`-demo YES`) uses a fake provider that returns canned text, so the UI can be reviewed without a key or network.
- Meet the app's existing standards: VoiceOver labels, keyboard access, and WCAG AA contrast for any new UI.

## Done means

- The features above work end to end with Claude and OpenAI keys. The Local option works against an OpenAI-compatible server.
- With AI switched off (the default), the app makes no AI network calls. Verify this.
- The README gets an "AI (optional)" section covering setup, what is sent, cost and how to turn it off.
- New code has tests, and the existing tests still pass.
- Report what you verified, what you could not verify (for example, if there's no macOS toolchain), and what I should check on my Mac.
