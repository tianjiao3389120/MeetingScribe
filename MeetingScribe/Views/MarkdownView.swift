import SwiftUI
import WebKit

/// Renders Markdown as styled HTML in a WKWebView.
///
/// SwiftUI's own `Text(markdown:)` only handles inline emphasis — it drops
/// headings, tables and task lists, which is most of what a meeting summary is
/// made of. A web view gives real preview fidelity with no dependency.
struct MarkdownView: NSViewRepresentable {

    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")   // let SwiftUI's background show
        view.allowsBackForwardNavigationGestures = false
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastRendered != markdown else { return }
        context.coordinator.lastRendered = markdown
        view.loadHTMLString(MarkdownRenderer.html(from: markdown), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastRendered: String?

        /// Keep the pane on the document; send real links to the browser.
        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
