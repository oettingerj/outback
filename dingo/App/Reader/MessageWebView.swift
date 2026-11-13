import AppKit
import Eucalyptus
import SwiftUI
import WebKit

/// What the reader shows: a message's HTML (or plain text, set as HTML here), whether its remote
/// images may load, and where its `cid:` images come from.
struct MessageDocument: Equatable {
    var id: String
    var html: String?
    var text: String?
    var allowsRemoteContent: Bool
    /// Wide measure for newsletters; conversation width for people's mail.
    var measure: CGFloat = 680

    static func == (lhs: MessageDocument, rhs: MessageDocument) -> Bool {
        lhs.id == rhs.id && lhs.allowsRemoteContent == rhs.allowsRemoteContent && lhs.html == rhs.html
            && lhs.text == rhs.text && lhs.measure == rhs.measure
    }
}

/// Mail HTML in a web view that runs no script, loads nothing remote unless the sender is
/// allowed, serves inline images itself, and sends every link to the default browser.
/// Height follows the content, so a conversation stacks messages in one scroll view.
struct MessageWebView: NSViewRepresentable {
    let document: MessageDocument
    /// Returns bytes and MIME type for a Content-ID, from the cache or Gmail.
    let inlinePart: @MainActor (String) async -> (Data, String)?
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator.inlineHandler, forURLScheme: "cid")
        configuration.suppressesIncrementalRendering = true
        let view = AutoHeightWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        view.onHeight = { [weak coordinator = context.coordinator] in coordinator?.update(height: $0) }
        context.coordinator.load(document, into: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(document, into: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MessageWebView
        let inlineHandler = InlineSchemeHandler()
        private var loaded: MessageDocument?

        init(_ parent: MessageWebView) {
            self.parent = parent
            super.init()
            inlineHandler.resolve = { [weak self] cid in await self?.parent.inlinePart(cid) }
        }

        func load(_ document: MessageDocument, into view: WKWebView) {
            guard document != loaded else { return }
            loaded = document
            Task {
                await RemoteContentRules.apply(allowsRemote: document.allowsRemoteContent, to: view.configuration.userContentController)
                view.loadHTMLString(MessageHTML.page(for: document), baseURL: nil)
            }
        }

        func update(height: CGFloat) {
            if abs(parent.height - height) > 0.5 { parent.height = height }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated else {
                // Only the page itself, loaded from a string as about:blank. A meta refresh,
                // form, or redirect never navigates the reader.
                return action.navigationType == .other && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
            }
            if let url = action.request.url {
                switch url.scheme?.lowercased() {
                case "mailto": NSApp.sendAction(#selector(AppDelegate.composeMailto(_:)), to: nil, from: url)
                case "http", "https": NSWorkspace.shared.open(url)
                default: break
                }
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            (webView as? AutoHeightWebView)?.measure()
        }
    }
}

/// Reports its document height after loads and resizes; never scrolls itself.
final class AutoHeightWebView: WKWebView {
    var onHeight: ((CGFloat) -> Void)?
    private var lastWidth: CGFloat = 0

    override func layout() {
        super.layout()
        if abs(bounds.width - lastWidth) > 1 {
            lastWidth = bounds.width
            measure()
        }
    }

    /// JavaScript is off for the page, but the app may still evaluate its own script in a separate world.
    func measure() {
        evaluateJavaScript("document.documentElement.scrollHeight", in: nil, in: .defaultClient) { [weak self] result in
            if case .success(let value) = result, let height = value as? Double {
                self?.onHeight?(CGFloat(height))
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // The enclosing scroll view owns scrolling; wide content still scrolls sideways here.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }
}

/// Serves `cid:` URLs from the message's inline parts.
final class InlineSchemeHandler: NSObject, WKURLSchemeHandler {
    var resolve: (@MainActor (String) async -> (Data, String)?)?
    private var stopped: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let cid = (url.absoluteString.dropFirst("cid:".count).removingPercentEncoding ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let key = ObjectIdentifier(task)
        Task { @MainActor in
            let part = await resolve?(cid)
            guard !stopped.contains(key) else { stopped.remove(key); return }
            guard let (data, mimeType) = part else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil))
            task.didReceive(data)
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(task))
    }
}

/// A content rule list that blocks every remote load. Trackers in mail are images, fonts, and
/// stylesheets; JavaScript is already off.
@MainActor
enum RemoteContentRules {
    private static var blockList: WKContentRuleList?

    static func apply(allowsRemote: Bool, to controller: WKUserContentController) async {
        controller.removeAllContentRuleLists()
        guard !allowsRemote else { return }
        if blockList == nil {
            let rules = #"[{"trigger":{"url-filter":"^(https?|ftp|wss?)://"},"action":{"type":"block"}}]"#
            blockList = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "DingoBlockRemote", encodedContentRuleList: rules)
        }
        if let blockList { controller.add(blockList) }
    }
}

/// Wraps a message in a page: a content security policy as a second wall behind the rule list,
/// system text, and for plain text, the app's colors and linked URLs.
enum MessageHTML {
    static func page(for document: MessageDocument) -> String {
        let remote = document.allowsRemoteContent ? " https: http:" : ""
        let csp = "default-src 'none'; img-src cid: data:\(remote); style-src 'unsafe-inline'\(remote); font-src data:\(remote); media-src cid: data:\(remote)"
        let head = """
        <meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width">
        """
        if let html = document.html, !html.isEmpty {
            // Mail HTML is designed for a light page; it renders on its own paper in both appearances.
            let style = """
            <style>html{background:#FFFFFF;color:#18181B;-webkit-text-size-adjust:100%}
            body{margin:0;padding:20px 24px;font:14px/1.5 -apple-system,system-ui,sans-serif;overflow-wrap:anywhere}
            img{max-width:100%;height:auto}table{max-width:100%}::selection{background:#F3D3B8}</style>
            """
            return "<!doctype html><html><head>\(head)\(style)</head><body>\(stripScripts(html))</body></html>"
        }
        let style = """
        <style>:root{color-scheme:light dark}
        html{background:transparent;color:#18181B}
        body{margin:0;padding:20px 24px;font:14px/1.55 -apple-system,system-ui,sans-serif;white-space:pre-wrap;overflow-wrap:anywhere;max-width:\(Int(document.measure))px}
        a{color:#A8520F;text-underline-offset:2px}blockquote{margin:0;padding-left:12px;border-left:1px solid #C8C8CD;color:#4E4E56}
        ::selection{background:#F3D3B8}
        @media (prefers-color-scheme: dark){html{color:#F4F4F5}a{color:#F0904A}blockquote{border-color:#3E3E44;color:#A6A6AE}::selection{background:#5A3A22}}</style>
        """
        return "<!doctype html><html><head>\(head)\(style)</head><body>\(plainTextHTML(document.text ?? ""))</body></html>"
    }

    /// JavaScript is off, but nothing executable should even reach the page.
    static func stripScripts(_ html: String) -> String {
        html.replacingOccurrences(of: #"<script\b[\s\S]*?</script\s*>"#, with: "", options: [.regularExpression, .caseInsensitive])
    }

    /// Escapes text, links URLs, and sets quoted lines (">") as blockquotes.
    static func plainTextHTML(_ text: String) -> String {
        var out = ""
        var quoting = false
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let isQuote = line.hasPrefix(">")
            if isQuote != quoting {
                out += isQuote ? "<blockquote>" : "</blockquote>"
                quoting = isQuote
            }
            let body = isQuote ? String(line.drop { $0 == ">" || $0 == " " }) : line
            out += link(escape(body)) + "\n"
        }
        if quoting { out += "</blockquote>" }
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func link(_ escaped: String) -> String {
        escaped.replacingOccurrences(of: #"(https?://[^\s<>&]+(?:&amp;[^\s<>&]+)*)"#, with: "<a href=\"$1\">$1</a>", options: .regularExpression)
    }
}
