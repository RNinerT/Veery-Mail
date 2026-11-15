import AppKit
import VeeryMailCore
import SwiftUI
import WebKit

/// Renders one HTML message, sized to its content (the reader scrolls, not the web view).
/// Privacy defaults: no JavaScript, remote resources (tracking pixels) blocked until allowed,
/// inline `cid:` images served from Fastmail via a custom scheme, links open in the browser.
struct MessageWebView: NSViewRepresentable {
    let html: String
    let allowRemote: Bool
    /// Simple person-to-person mail blends into the reader sheet (transparent page, sheet colors).
    /// Designed mail keeps its own white page so branded layouts look as the sender intended.
    let blend: Bool
    let palette: ReaderPalette
    let inlineParts: [String: (blobId: String, type: String)]
    let client: JMAPClient?
    @Binding var height: CGFloat
    /// Called instead of rendering when HTML can't be shown safely (the blocking rule isn't available).
    var onUnsafe: () -> Void = {}

    /// One shared, memory-only store: no cookies or cache written to disk.
    @MainActor private static let dataStore = WKWebsiteDataStore.nonPersistent()

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = Self.dataStore
        config.suppressesIncrementalRendering = true
        config.setURLSchemeHandler(context.coordinator.cidHandler, forURLScheme: CIDSchemeHandler.scheme)
        let view = PassthroughWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: PassthroughWebView, context: Context) {
        let c = context.coordinator
        c.cidHandler.client = client
        c.cidHandler.parts = inlineParts
        let key = "\(html.hashValue)-\(allowRemote)-\(blend)-\(palette.textHex)"
        guard c.loadedKey != key else { return }
        c.loadedKey = key
        // A newer render always wins: stop whatever is loading and drop the old rules first.
        let ticket = c.ticket.next()
        view.stopLoading()
        let controller = view.configuration.userContentController
        controller.removeAllContentRuleLists()
        view.setValue(!blend, forKey: "drawsBackground")   // transparent page when blending
        view.pageZoom = 1
        c.fittedWidth = false
        let allowRemote = allowRemote
        let document = HTMLRendering.document(body: html, allowRemote: allowRemote, cidScheme: CIDSchemeHandler.scheme,
                                              css: Self.css(blend: blend, palette: palette),
                                              darkScheme: blend && palette.isDark)
        let onUnsafe = onUnsafe
        Task { @MainActor in
            let rules = allowRemote ? nil : await RemoteContentBlocker.rules()
            // The message, the setting or the view may have changed while the rule compiled.
            guard c.ticket.isCurrent(ticket) else { return }
            switch HTMLRendering.decide(allowRemote: allowRemote, blockingRuleAvailable: rules != nil) {
            case .plainTextFallback:
                onUnsafe()
            case .html(let remote):
                if !remote, let rules { controller.add(rules) }
                view.loadHTMLString(document, baseURL: nil)
            }
        }
    }

    /// App styles for the wrapper page. Blending forces every text color so nothing ends up
    /// unreadable on the sheet.
    static func css(blend: Bool, palette: ReaderPalette) -> String {
        let colors = blend
            ? """
              html,body{background:transparent;color:\(palette.textHex);}
              body *{color:\(palette.textHex) !important;background-color:transparent !important;border-color:\(palette.ruleHex) !important;}
              a,a *{color:\(palette.linkHex) !important;}
              blockquote{border-left:3px solid \(palette.ruleHex);}
              blockquote,blockquote *{color:\(palette.secondaryHex) !important;}
              """
            : """
              html,body{background:#fff;color:#111;}
              blockquote{border-left:3px solid #ccd;color:#444;}
              """
        return """
          html,body{margin:0;padding:0;}
          body{font:15px -apple-system,system-ui,sans-serif;line-height:1.55;word-wrap:break-word;overflow-wrap:anywhere;padding:\(blend ? "0" : "14px 16px");}
          img,video{max-width:100%;height:auto;}
          table{max-width:100%;}
          pre{white-space:pre-wrap;}
          blockquote{margin-left:0;padding-left:10px;}
          \(colors)
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var height: Binding<CGFloat>
        var loadedKey: String?
        /// Wide fixed-width layouts are zoomed to fit once per load.
        var fittedWidth = false
        let cidHandler = CIDSchemeHandler()
        let ticket = RenderTicket()

        init(height: Binding<CGFloat>) { self.height = height }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // Inline images can arrive after didFinish; measure once more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak webView] in
                if let webView { self?.measure(webView) }
            }
        }

        private func measure(_ webView: WKWebView) {
            // App-initiated scripts still run with page JavaScript disabled.
            let js = "[document.documentElement.scrollWidth, Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)]"
            webView.evaluateJavaScript(js) { [weak self, weak webView] result, _ in
                guard let self, let webView, let values = result as? [NSNumber], values.count == 2 else { return }
                let contentWidth = CGFloat(values[0].doubleValue)
                let zoom = webView.pageZoom
                let available = webView.bounds.width
                // A newsletter built wider than the reader is scaled down to fit, so it can
                // never push the window wider or hide under other controls.
                if !self.fittedWidth, available > 0, contentWidth * zoom > available + 2 {
                    self.fittedWidth = true
                    webView.pageZoom = max(0.35, available / contentWidth)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak webView] in
                        if let webView { self?.measure(webView) }
                    }
                    return
                }
                let h = CGFloat(values[1].doubleValue) * zoom
                if h > 0, abs(h - self.height.wrappedValue) > 1 {
                    self.height.wrappedValue = h
                }
            }
        }

        @MainActor
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                switch url.scheme?.lowercased() {
                case "mailto": MailStore.current?.composeMailto(url)   // write it here, not in another mail app
                case "http", "https": NSWorkspace.shared.open(url)
                default: break
                }
                return .cancel
            }
            // Only the message itself (about:blank) may load. This stops a message from
            // redirecting the reader to a website (meta refresh) or embedding one in a frame.
            return action.request.url?.scheme?.lowercased() == "about" ? .allow : .cancel
        }
    }
}

/// Lets the enclosing SwiftUI ScrollView handle scrolling.
final class PassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

/// Serves `cid:` inline images by downloading the blob from Fastmail.
final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "veerymail-cid"
    var client: JMAPClient?
    var parts: [String: (blobId: String, type: String)] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let cid = String(url.absoluteString.dropFirst(Self.scheme.count + 1)).removingPercentEncoding ?? ""
        guard let part = parts[cid], let client else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        tasks[key] = Task { @MainActor in
            defer { self.tasks[key] = nil }
            do {
                let data = try await client.download(blobId: part.blobId, name: cid, type: part.type)
                guard !Task.isCancelled else { return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: part.type,
                                                     expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } catch {
                if !Task.isCancelled { urlSchemeTask.didFailWithError(error) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

/// Compiled once: blocks every http(s) load inside message bodies.
@MainActor
enum RemoteContentBlocker {
    private static var compiled: WKContentRuleList?

    static func rules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let json = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://.*"},"action":{"type":"block"}}]"#
        // Blocks all network schemes, including redirects and preconnects; anything the rule list
        // can't compile means no HTML is rendered (see HTMLRendering.decide).
        guard !UserDefaults.standard.bool(forKey: "debug.simulateRuleFailure"),
              let store = WKContentRuleListStore.default() else { return nil }
        let list = try? await store.compileContentRuleList(forIdentifier: "veerymail-block-remote", encodedContentRuleList: json)
        compiled = list
        return list
    }
}
