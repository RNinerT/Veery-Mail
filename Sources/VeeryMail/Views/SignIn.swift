import AppKit
import Observation
import SwiftUI
import VeeryMailCore

/// "Sign in with Fastmail": OAuth 2.0 authorization code + PKCE in the user's browser, with a
/// one-time loopback redirect to this Mac. Veery Mail never sees the Fastmail password.
@MainActor
@Observable
final class FastmailSignIn {
    enum Stage: Equatable { case idle, preparing, waitingForBrowser, finishing, failed(String) }

    private(set) var stage: Stage = .idle
    @ObservationIgnored private var listener: LoopbackRedirectListener?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let oauth = FastmailOAuth()

    var isBusy: Bool {
        switch stage {
        case .preparing, .waitingForBrowser, .finishing: return true
        default: return false
        }
    }

    func start(store: MailStore, includeContacts: Bool) {
        cancel()
        stage = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let metadata = try await oauth.discover()
                let scopes = FastmailOAuth.scopes(for: metadata, includeContacts: includeContacts)
                let registration = try await registration(metadata, scopes: scopes)
                let listener = LoopbackRedirectListener(path: FastmailOAuth.redirectPath)
                self.listener = listener
                let port = try await listener.start()
                let pending = oauth.beginAuthorization(metadata, registration: registration, port: port, scopes: scopes)
                try Task.checkCancellation()
                stage = .waitingForBrowser
                NSWorkspace.shared.open(pending.authorizationURL)
                let callback = try await listener.waitForCallback(timeout: 600)
                listener.stop()
                NSApp.activate(ignoringOtherApps: true)
                stage = .finishing
                let code = try oauth.code(from: callback, for: pending,
                                          expectIssuer: metadata.authorizationResponseIssParameterSupported == true)
                let tokens = try await oauth.exchange(code: code, pending: pending, metadata: metadata)
                try AuthStore.saveOAuth(tokens: tokens, metadata: metadata)
                stage = .idle
                store.startOAuth(tokens: tokens, metadata: metadata)
            } catch is CancellationError {
                stage = .idle
            } catch let error as OAuthError where error == .canceled {
                stage = .failed(error.localizedDescription)
            } catch {
                stage = .failed(error.localizedDescription)
            }
            self.listener?.stop()
            self.listener = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        listener?.stop()
        listener = nil
        if isBusy { stage = .idle }
    }

    /// The registration is reused while its scopes still cover what's asked for.
    private func registration(_ metadata: OAuthServerMetadata, scopes: [String]) async throws -> OAuthRegistration {
        let key = "oauth.registration"
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(OAuthRegistration.self, from: data),
           saved.issuer == metadata.issuer,
           Set(scopes).subtracting(["offline_access"]).isSubset(of: Set(saved.scope.split(separator: " ").map(String.init))) {
            return saved
        }
        let fresh = try await oauth.register(metadata, scopes: scopes)
        UserDefaults.standard.set(try? JSONEncoder().encode(fresh), forKey: key)
        return fresh
    }
}
