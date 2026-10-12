import AppKit
import WebKit

class LoginWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    weak var authManager: AuthManager?
    private let dataStore: WKWebsiteDataStore
    private var webView: WKWebView!
    private var verifying = false
    private var finished = false
    private var fallbackTimer: Timer?

    // Holds any OAuth popup windows (e.g. Google sign-in)
    private var popupWindowControllers: [NSWindowController] = []

    init(authManager: AuthManager?, dataStore: WKWebsiteDataStore? = nil) {
        self.dataStore = dataStore ?? .default()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in to Claude"
        window.center()
        super.init(window: window)
        self.authManager = authManager
        window.delegate = self
        setupWebView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        webView?.removeObserver(self, forKeyPath: "URL")
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.addObserver(self, forKeyPath: "URL", options: .new, context: nil)
        window?.contentView = webView
        webView.load(URLRequest(url: URL(string: "https://claude.ai/login")!))
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        finished = false
        fallbackTimer?.invalidate()
        // Fallback: a login that never changes the URL still gets detected within 2 s.
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.verify()
        }
    }

    // MARK: - Detection: URL changes only trigger an API check; the API decides.

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "URL", let url = webView?.url {
            noteCandidate(url: url)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { noteCandidate(url: url) }
        if webView !== self.webView, let mainURL = self.webView?.url { noteCandidate(url: mainURL) }
    }

    /// A claude.ai URL outside the login routes. Not proof of a session, only a reason to ask the API.
    func isCandidateLoginURL(_ url: URL) -> Bool {
        guard let host = url.host, host.contains("claude.ai") else { return false }
        let loginPaths = ["/login", "/auth", "/oauth"]
        return !loginPaths.contains(where: { url.path.hasPrefix($0) })
    }

    private func noteCandidate(url: URL) {
        guard isCandidateLoginURL(url) else { return }
        verify()
    }

    private func verify() {
        guard !verifying, !finished, let authManager else { return }
        verifying = true
        Task { @MainActor [weak self] in
            let confirmed = await authManager.loginWindowSawCandidate()
            guard let self else { return }
            self.verifying = false
            if confirmed { self.finish() }
        }
    }

    private func finish() {
        finished = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        popupWindowControllers.forEach { $0.close() }
        popupWindowControllers.removeAll()
        close()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        authManager?.loginWindowDidClose()
    }

    // MARK: - WKUIDelegate (popup handling for Google OAuth)

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Create a popup window for OAuth flows (e.g. Google sign-in)
        let popupWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupWindow.title = "Sign in"
        popupWindow.center()

        configuration.websiteDataStore = dataStore
        let popupWebView = WKWebView(frame: popupWindow.contentView!.bounds, configuration: configuration)
        popupWebView.autoresizingMask = [.width, .height]
        popupWebView.navigationDelegate = self
        popupWebView.uiDelegate = self
        popupWindow.contentView?.addSubview(popupWebView)

        let popupController = NSWindowController(window: popupWindow)
        popupController.showWindow(nil)
        popupWindow.makeKeyAndOrderFront(nil)
        popupWindowControllers.append(popupController)

        return popupWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        // Clean up popup controllers whose webview was closed
        popupWindowControllers.removeAll { $0.window?.contentView?.subviews.first == webView }

        // After OAuth popup closes, reload main webView; if login succeeded,
        // claude.ai redirects to home, which triggers an API check
        guard !finished else { return }
        self.webView.load(URLRequest(url: URL(string: "https://claude.ai/")!))
    }
}
