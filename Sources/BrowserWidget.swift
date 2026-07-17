import Cocoa
import WebKit

final class BrowserWidget: Widget, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!

    private var homeURL: URL { URL(string: config.url ?? "") ?? URL(string: "https://www.apple.com")! }

    override var displayName: String { homeURL.host ?? "Browser" }
    override var menuSymbol: String { "globe" }

    override init(config: WidgetConfig, cascadeIndex: Int) {
        super.init(config: config, cascadeIndex: cascadeIndex)

        // Default data store so cookies/logins survive relaunches.
        let webConfig = WKWebViewConfiguration()
        webConfig.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: webConfig)
        // Safari UA so OAuth providers (Google) don't reject the embedded browser.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .clear

        installContent(webView, belowTitleBar: true)
        webView.load(URLRequest(url: homeURL))
    }

    override func addMenuItems(to menu: NSMenu) {
        for (title, action) in [
            ("Reload", #selector(reload)),
            ("Go Home", #selector(goHome)),
            ("Open in Browser", #selector(openInBrowser)),
            ("Change URL…", #selector(changeURL)),
        ] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
    }

    @objc private func reload() { webView.reload() }
    @objc private func goHome() { webView.load(URLRequest(url: homeURL)) }
    @objc private func openInBrowser() { NSWorkspace.shared.open(webView.url ?? homeURL) }

    @objc private func changeURL() {
        guard let text = runTextPrompt(title: "Widget URL", placeholder: "https://example.com", initial: config.url ?? ""),
              let url = normalizedWidgetURL(from: text) else { return }
        config.url = url.absoluteString
        titleLabel.stringValue = displayName
        webView.load(URLRequest(url: url))
    }

    // Links that ask for a new window (e.g. OAuth popups) load in the same view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
