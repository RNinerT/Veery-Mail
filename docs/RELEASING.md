# Releasing Veery Mail

Everyday builds: `./scripts/build-app.sh` (ad-hoc signed, for your own Mac). CI (`.github/workflows/ci.yml`) builds, runs `swift test`, bundles and verifies the app on macOS 15 and the latest macOS runner for every push.

## Signed, notarized download

Requires an Apple Developer Program membership (the account holder enrolls and creates the certificate; that step is yours).

1. In Xcode → Settings → Accounts, or developer.apple.com → Certificates, create a **Developer ID Application** certificate and install it in your login keychain.
2. Store notarization credentials once (prompts for an app-specific password from appleid.apple.com):

   ```bash
   xcrun notarytool store-credentials "veery-notary" --apple-id "<APPLE_ID>" --team-id "<TEAM_ID>"
   ```

3. Build, sign, notarize and staple:

   ```bash
   DEVELOPER_ID="Developer ID Application: <NAME> (<TEAM_ID>)" NOTARY_PROFILE=veery-notary ./scripts/release.sh
   ```

   The result is `build/Veery-Mail.zip`, a universal (Apple silicon + Intel) app with hardened runtime, a stapled notarization ticket and a passing `spctl` assessment.

Or run **Actions → Release → Run workflow** after adding the secrets listed at the top of `.github/workflows/release.yml`. It uploads the zip as a workflow artifact; publishing a GitHub release is left to you.

## Before a public release

- [ ] Fill in `<SUPPORT_EMAIL_PLACEHOLDER>`, `<DATE_PLACEHOLDER>` and `<JURISDICTION_PLACEHOLDER>` in `README.md`, `docs/PRIVACY.md` and `docs/TERMS.md`, and have them reviewed.
- [ ] Host the privacy policy and user agreement at public URLs (the repository is private, so the in-app links to GitHub only work for collaborators), then set `OAuthClientInfo.policyURI`/`tosURI`/`clientURI` in `Sources/VeeryMailCore/OAuth.swift` so Fastmail's consent screen shows them.
- [ ] Sign in with a real Fastmail account through **Sign in with Fastmail**: consent, cancel, refresh after an hour, sign out (revocation). The OAuth flow is covered by tests against a mock server only.
- [ ] Confirm on a live account that Fastmail's `Authentication-Results` header uses an authserv-id ending in `.messagingengine.com` (`UnsubscribePolicy.trustedAuthServSuffix`). If it differs, one-click unsubscribe falls back to opening the page in the browser (safe, but less convenient).
- [ ] Launch the release build on a Mac running macOS 14 (Sonoma). CI compiles with a macOS 14 deployment target but GitHub no longer offers macOS 14 runners.
- [ ] If you plan to offer Masked Email in public builds, confirm with Fastmail partnerships first; public OAuth scopes don't include it, so it currently appears only with API-token sign-in.
- [ ] Update the version in `Resources/Info.plist` and `OAuthClientInfo.softwareVersion`.
