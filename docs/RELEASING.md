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
   DEVELOPER_ID="Developer ID Application: <NAME> (<TEAM_ID>)" NOTARY_PROFILE=veery-notary SPARKLE_PUBLIC_ED_KEY="<PUBLIC_KEY>" ./scripts/release.sh
   ```

   The result is `build/Veery-Mail.zip`, a universal (Apple silicon + Intel) app with hardened runtime, a stapled notarization ticket and a passing `spctl` assessment.

## Automatic updates

Veery Mail uses Sparkle to check for signed updates and installs them when the app quits. The first release with Sparkle must be installed manually. Development builds do not enable update checks.

1. Download the Sparkle 2.10.1 distribution from its official GitHub release and run `bin/generate_keys` on your Mac. Keep the private key in your Keychain and back it up securely. Record the public key it prints.
2. In GitHub repository settings, add the public key as the Actions variable `SPARKLE_PUBLIC_ED_KEY`. Export the private key with Sparkle's `generate_keys -x` and add its contents as the Actions secret `SPARKLE_PRIVATE_ED_KEY`. Delete the exported file securely after adding it. Never commit the private key.
3. Configure the Apple signing and notarization secrets listed in `.github/workflows/release.yml`.
4. Increase both `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`. Create a Git tag matching the version, such as `v0.2.0`, and push it to GitHub.
5. Run **Actions → Release → Run workflow** and enter the existing tag. The workflow signs and notarizes the app, generates a signed update feed, and publishes both as release assets. The feed points to the latest GitHub release.

The update signing key must stay the same across releases. Verify updates on a test Mac, including a quit canceled by an unsaved draft, before distributing a release.

## Before a public release

- [ ] Fill in `<SUPPORT_EMAIL_PLACEHOLDER>`, `<DATE_PLACEHOLDER>` and `<JURISDICTION_PLACEHOLDER>` in `README.md`, `docs/PRIVACY.md` and `docs/TERMS.md`, and have them reviewed.
- [ ] Host the privacy policy and user agreement at public URLs (the repository is private, so the in-app links to GitHub only work for collaborators), then set `OAuthClientInfo.policyURI`/`tosURI`/`clientURI` in `Sources/VeeryMailCore/OAuth.swift` so Fastmail's consent screen shows them.
- [ ] Sign in with a real Fastmail account through **Sign in with Fastmail**: consent, cancel, refresh after an hour, sign out (revocation). The OAuth flow is covered by tests against a mock server only.
- [ ] Confirm on a live account that Fastmail's `Authentication-Results` header uses an authserv-id ending in `.messagingengine.com` (`UnsubscribePolicy.trustedAuthServSuffix`). If it differs, one-click unsubscribe falls back to opening the page in the browser (safe, but less convenient).
- [ ] Launch the release build on a Mac running macOS 14 (Sonoma). CI compiles with a macOS 14 deployment target but GitHub no longer offers macOS 14 runners.
- [ ] If you plan to offer Masked Email in public builds, confirm with Fastmail partnerships first; public OAuth scopes don't include it, so it currently appears only with API-token sign-in.
- [ ] Update the version in `Resources/Info.plist` and `OAuthClientInfo.softwareVersion`.
