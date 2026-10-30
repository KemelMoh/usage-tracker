import AppKit
import os
import UsageTrackerCore
import WebKit

enum LiteLLMSSOStatus: Equatable {
    case unknown
    case signedOut
    case signingIn
    case signedIn
    case needsLogin

    var label: String {
        switch self {
        case .unknown: return "Comprobando sesión"
        case .signedOut: return "Sin sesión LiteLLM"
        case .signingIn: return "Iniciando sesión…"
        case .signedIn: return "Sesión LiteLLM activa"
        case .needsLogin: return "La sesión requiere renovar"
        }
    }
}

/// Persistent, app-local WebKit session for LiteLLM's Google Cloud IAP login.
@MainActor
final class LiteLLMSession: NSObject, LiteLLMAuthStore {
    static var homeURL: URL? { EndpointConfiguration.accountPortalBaseURL }
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/155.0.0.0 Safari/537.36"
    private static let renewTimeout: TimeInterval = 20
    private static let idleOnLoginPage: TimeInterval = 5
    private static let offlineCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
        .cannotConnectToHost, .dnsLookupFailed, .timedOut,
        .internationalRoamingOff, .dataNotAllowed
    ]

    private let dataStore = WKWebsiteDataStore.default()
    private lazy var renewalGate = LiteLLMRenewalGate { [unowned self] in
        await self.performRenewal()
    }
    private var loginWindow: LiteLLMLoginWindowController? {
        didSet { renewalGate.interactiveLoginActive = loginWindow != nil }
    }

    func authCookie() async -> String? {
        guard let host = Self.homeURL?.host else { return nil }
        let cookies = await dataStore.httpCookieStore.allCookies()
        return cookies.first { cookie in
            guard cookie.name == LiteLLMPlatformClient.cookieName else { return false }
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == host || host.hasSuffix(".\(domain)")
        }?.value
    }

    func renew() async -> LiteLLMRenewResult {
        await renewalGate.renew()
    }

    func presentLogin(onSuccess: @escaping () -> Void, onClose: @escaping () -> Void) {
        if let loginWindow {
            loginWindow.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = LiteLLMLoginWindowController(
            session: self,
            onSuccess: { [weak self] in
                self?.loginWindow = nil
                onSuccess()
            },
            onClose: { [weak self] in
                self?.loginWindow = nil
                onClose()
            }
        )
        loginWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func signOut() async {
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    fileprivate func makeWebView(frame: NSRect) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        return webView
    }

    private func performRenewal() async -> LiteLLMRenewResult {
        guard let homeURL = Self.homeURL else { return .needsLogin }
        let previousCookie = await authCookie()
        let webView = makeWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768))
        let tracker = LiteLLMNavigationTracker()
        webView.navigationDelegate = tracker
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        webView.load(URLRequest(url: homeURL))

        let deadline = Date().addingTimeInterval(Self.renewTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if renewalGate.interactiveLoginActive { return .needsLogin }
            if let cookie = await authCookie(), cookie != previousCookie { return .renewed }
            if let error = tracker.networkError, Self.offlineCodes.contains(error.code) {
                return .offline
            }
            if let finished = tracker.lastFinishedURL,
               let finishedAt = tracker.lastFinishedAt,
               finished.host != homeURL.host,
               !webView.isLoading,
               Date().timeIntervalSince(finishedAt) > Self.idleOnLoginPage {
                return .needsLogin
            }
        }
        return .needsLogin
    }
}

@MainActor
private final class LiteLLMRenewalGate {
    var interactiveLoginActive = false
    private let attempt: @MainActor () async -> LiteLLMRenewResult
    private var inFlight: Task<LiteLLMRenewResult, Never>?

    init(attempt: @escaping @MainActor () async -> LiteLLMRenewResult) {
        self.attempt = attempt
    }

    func renew() async -> LiteLLMRenewResult {
        if interactiveLoginActive { return .needsLogin }
        if let inFlight { return await inFlight.value }
        let task = Task { await attempt() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }
}

@MainActor
private final class LiteLLMLoginWindowController: NSWindowController, NSWindowDelegate, WKHTTPCookieStoreObserver {
    private let session: LiteLLMSession
    private let webView: WKWebView
    private let tracker = LiteLLMNavigationTracker()
    private let onSuccess: () -> Void
    private let onClose: () -> Void
    private var succeeded = false
    private var previousCookie: String?

    init(session: LiteLLMSession, onSuccess: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.session = session
        self.onSuccess = onSuccess
        self.onClose = onClose
        let frame = NSRect(x: 0, y: 0, width: 600, height: 760)
        webView = session.makeWebView(frame: frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Iniciar sesión en LiteLLM"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        tracker.onFinish = { [weak self] url in self?.checkSignedIn(url) }
        webView.navigationDelegate = tracker

        Task { @MainActor [weak self] in
            guard let self, let homeURL = LiteLLMSession.homeURL else {
                self?.onClose()
                return
            }
            previousCookie = await session.authCookie()
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
            webView.load(URLRequest(url: homeURL))
        }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in self?.checkSignedIn(nil) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func checkSignedIn(_ url: URL?) {
        guard !succeeded else { return }
        Task { @MainActor in
            guard let cookie = await session.authCookie(),
                  cookie != previousCookie || url?.host == LiteLLMSession.homeURL?.host,
                  !succeeded else { return }
            succeeded = true
            window?.close()
            onSuccess()
        }
    }

    func windowWillClose(_ notification: Notification) {
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        webView.stopLoading()
        if !succeeded { onClose() }
    }
}

@MainActor
private final class LiteLLMNavigationTracker: NSObject, WKNavigationDelegate {
    private let logger = Logger(subsystem: "dev.kemel.usagetracker", category: "litellm-sso")
    private(set) var lastFinishedURL: URL?
    private(set) var lastFinishedAt: Date?
    private(set) var networkError: URLError?
    var onFinish: ((URL?) -> Void)?

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Google sign-in creates blank child frames during its challenge flow.
        // They do not carry credentials and must not be mistaken for an
        // external navigation.
        if url.absoluteString == "about:blank",
           navigationAction.targetFrame?.isMainFrame == false {
            decisionHandler(.allow)
            return
        }
        // The corporate Google Workspace may hand authentication off to an
        // organization-specific identity provider. Restricting navigation to
        // Google hosts leaves the embedded sign-in spinner running forever.
        // HTTPS is still mandatory; IAP cookies are host-only and cannot be
        // sent to these other sites.
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            logger.warning("Blocked non-HTTPS SSO navigation: \(url.scheme ?? "unknown", privacy: .public)")
            decisionHandler(.cancel)
            return
        }
        logger.debug("Allowed SSO navigation host: \(host, privacy: .public)")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        record(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        networkError = error as? URLError
        let failure = error as NSError
        logger.error("SSO navigation failed: \(failure.domain, privacy: .public) code=\(failure.code)")
        record(webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        networkError = error as? URLError
        let failure = error as NSError
        logger.error("SSO provisional navigation failed: \(failure.domain, privacy: .public) code=\(failure.code)")
        record(webView.url)
    }

    private func record(_ url: URL?) {
        lastFinishedURL = url
        lastFinishedAt = Date()
        onFinish?(url)
    }

}
