import Foundation

// MARK: - One-click unsubscribe (RFC 8058)

public enum UnsubscribeOption: Equatable, Sendable {
    /// RFC 8058 one-click: a single POST, after the user confirms.
    case oneClick(URL)
    /// Opens the list's unsubscribe page in the browser.
    case browser(URL)
    /// Starts an unsubscribe email in the composer.
    case mailto(URL)
    case none
}

public enum UnsubscribePolicy {
    /// The authserv-id suffix of Authentication-Results headers that Fastmail's own mail servers add.
    /// Only the topmost such header is trusted; senders can forge headers lower down.
    /// (Observed value; confirm against live mail before release. See docs/RELEASING.md.)
    public static let trustedAuthServSuffix = ".messagingengine.com"

    /// Chooses how to unsubscribe. One-click is offered only when all of RFC 8058's conditions
    /// can be verified:
    /// 1. List-Unsubscribe has an HTTPS URI.
    /// 2. List-Unsubscribe-Post is exactly "List-Unsubscribe=One-Click".
    /// 3. A DKIM signature covers both headers, and Fastmail's receiving server recorded a
    ///    passing DKIM result for that signature's domain.
    /// Anything less falls back to the browser or an email.
    public static func option(for email: EmailDetail) -> UnsubscribeOption {
        let urls = (email.listUnsubscribe ?? []).compactMap { URL(string: $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))) }
        let https = urls.first { $0.scheme?.lowercased() == "https" && $0.host != nil }
        let mailto = urls.first { $0.scheme?.lowercased() == "mailto" }

        if let https, isOneClickPost(email.listUnsubscribePost), hasVerifiedSignature(email) {
            return .oneClick(https)
        }
        if let https { return .browser(https) }
        if let mailto { return .mailto(mailto) }
        return .none
    }

    static func isOneClickPost(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) == "List-Unsubscribe=One-Click"
    }

    static func hasVerifiedSignature(_ email: EmailDetail) -> Bool {
        guard let topAuth = (email.authenticationResults ?? []).first,
              let passing = passingDKIMDomains(topAuth) else { return false }
        for raw in email.dkimSignatures ?? [] {
            let tags = dkimTags(raw)
            guard let domain = tags["d"]?.lowercased(), passing.contains(domain),
                  let signed = tags["h"]?.lowercased().split(separator: ":").map({ $0.trimmingCharacters(in: .whitespaces) })
            else { continue }
            if signed.contains("list-unsubscribe") && signed.contains("list-unsubscribe-post") { return true }
        }
        return false
    }

    /// Domains with dkim=pass in a header written by Fastmail, or nil if the header isn't Fastmail's.
    static func passingDKIMDomains(_ header: String) -> Set<String>? {
        let parts = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let authServ = parts.first?.split(separator: " ").first.map({ String($0).lowercased() }),
              authServ.hasSuffix(trustedAuthServSuffix) else { return nil }
        var domains = Set<String>()
        for part in parts.dropFirst() where part.lowercased().hasPrefix("dkim=pass") {
            for token in part.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
                let t = token.lowercased()
                if t.hasPrefix("header.d=") { domains.insert(String(t.dropFirst(9))) }
                if t.hasPrefix("header.i=@") { domains.insert(String(t.dropFirst(10))) }
            }
        }
        return domains
    }

    static func dkimTags(_ raw: String) -> [String: String] {
        var value = raw
        if let colon = value.firstIndex(of: ":"), value[..<colon].lowercased().hasSuffix("dkim-signature") {
            value = String(value[value.index(after: colon)...])
        }
        var tags: [String: String] = [:]
        for part in value.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].filter { !$0.isWhitespace }.lowercased()
            tags[key] = kv[1].filter { !$0.isWhitespace && $0 != "\r" && $0 != "\n" }
        }
        return tags
    }
}

public enum UnsubscribeError: LocalizedError, Equatable {
    case notHTTPS
    case redirected
    case failed(Int)

    public var errorDescription: String? {
        switch self {
        case .notHTTPS: return "One-click unsubscribe needs a secure (HTTPS) link."
        case .redirected: return "The list tried to redirect the unsubscribe request, so it was stopped. Use the list’s web page instead."
        case .failed(let code): return "The list didn’t accept the unsubscribe request (HTTP \(code))."
        }
    }
}

/// Sends the RFC 8058 POST in an isolated session: no cookies, no stored credentials,
/// no cache, no redirects, and nothing but the required body. Never call it from rendering
/// or preview code, only from an explicit user action.
public final class OneClickUnsubscriber: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    /// `protocolClasses` lets tests intercept requests.
    public init(protocolClasses: [AnyClass]? = nil) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 30
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public static func makeRequest(_ url: URL) throws -> URLRequest {
        guard url.scheme?.lowercased() == "https" else { throw UnsubscribeError.notHTTPS }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpShouldHandleCookies = false
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        return req
    }

    public func post(_ url: URL) async throws {
        let (_, response) = try await session.data(for: try Self.makeRequest(url))
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(code) { throw UnsubscribeError.redirected }
        guard (200..<300).contains(code) else { throw UnsubscribeError.failed(code) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil   // never follow: the 3xx response is returned and reported as an error
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Validate the server normally, but never answer a request for credentials.
        challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? (.performDefaultHandling, nil)
            : (.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - HTML message rendering

/// How a message body may be shown.
public enum RenderDecision: Equatable, Sendable {
    /// Sandboxed HTML with these remote-content rules.
    case html(allowRemote: Bool)
    /// The blocking rule couldn't be installed: show plain text instead of risking remote loads.
    case plainTextFallback
}

public enum HTMLRendering {
    /// Fails closed: if remote content is blocked but the WebKit rule isn't available, no HTML is rendered.
    public static func decide(allowRemote: Bool, blockingRuleAvailable: Bool) -> RenderDecision {
        if allowRemote { return .html(allowRemote: true) }
        return blockingRuleAvailable ? .html(allowRemote: false) : .plainTextFallback
    }

    /// Content-Security-Policy for the wrapper page. A second, independent barrier behind the
    /// WebKit rule: with remote content blocked, only inline styles, data: images and the
    /// app's cid: scheme can load. Scripts never run either way.
    public static func contentSecurityPolicy(allowRemote: Bool, cidScheme: String) -> String {
        let images = allowRemote ? "\(cidScheme): data: https: http:" : "\(cidScheme): data:"
        let styles = allowRemote ? "'unsafe-inline' https: http:" : "'unsafe-inline'"
        let fonts = allowRemote ? "data: https: http:" : "data:"
        return "default-src 'none'; img-src \(images); style-src \(styles); font-src \(fonts); "
            + "media-src \(cidScheme): data:; script-src 'none'; frame-src 'none'; object-src 'none'; "
            + "form-action 'none'; base-uri 'none'"
    }

    /// Wraps sender HTML in a page with the CSP above and the app's styles.
    public static func document(body: String, allowRemote: Bool, cidScheme: String, css: String, darkScheme: Bool) -> String {
        let rewritten = body.replacingOccurrences(of: "cid:", with: "\(cidScheme):", options: .caseInsensitive)
        let csp = contentSecurityPolicy(allowRemote: allowRemote, cidScheme: cidScheme)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="color-scheme" content="\(darkScheme ? "dark" : "light")">
        <meta name="referrer" content="no-referrer">
        <style>\(css)</style></head><body>\(rewritten)</body></html>
        """
    }
}

/// Ties each render to the newest request, so a slower, older render can never apply its
/// HTML or rules after a newer one.
public final class RenderTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0

    public init() {}

    public func next() -> Int { lock.withLock { generation += 1; return generation } }
    public func isCurrent(_ ticket: Int) -> Bool { lock.withLock { ticket == generation } }
}
