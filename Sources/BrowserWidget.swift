import Cocoa
import WebKit

final class BrowserWidget: Widget, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!
    private var navObservations: [NSKeyValueObservation] = []

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

        // Nav buttons live in the glass title bar, above the drag strip in z-order.
        backButton = navButton("chevron.left", #selector(goBack))
        forwardButton = navButton("chevron.right", #selector(goForward))
        reloadButton = navButton("arrow.clockwise", #selector(reload))
        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 6),
            reloadButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        navObservations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                self?.backButton.isEnabled = view.canGoBack
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                self?.forwardButton.isEnabled = view.canGoForward
            },
        ]

        webView.load(URLRequest(url: homeURL))
    }

    private func navButton(_ symbol: String, _ action: Selector) -> NSButton {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!
            .withSymbolConfiguration(config)!
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 18),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        return button
    }

    override func didSetCollapsed(_ collapsed: Bool) {
        [backButton, forwardButton, reloadButton].forEach { $0?.isHidden = collapsed }
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
    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
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
