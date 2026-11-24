import AppKit
import Observation
import StarPulseCore
import WebKit

@MainActor @Observable
final class AccountStore {
    enum State: Equatable {
        case signedOut, connecting
        case connected(CloudAccount)
        case expired
        case failed(String)
    }

    var state: State = .signedOut
    private let cloud = StarlinkCloud()
    private var login: LoginWindow?

    /// Resumes a stored session at launch, without showing anything.
    func start() {
        Task {
            guard await cloud.hasStoredSession else { return }
            await refresh()
        }
    }

    func refresh() async {
        state = .connecting
        do {
            var info = try await cloud.account()
            #if DEBUG
            info = Anonymizer.account(info)
            #endif
            state = .connected(info)
        }
        catch CloudError.sessionExpired { state = .expired }
        catch CloudError.notConnected { state = .signedOut }
        catch { state = .failed(error.localizedDescription) }
    }

    func signIn() {
        guard login == nil else { login?.focus(); return }
        state = .connecting
        let window = LoginWindow(cloud: cloud)
        login = window
        Task {
            let outcome = await window.run()
            login = nil
            switch outcome {
            case .connected: await refresh()
            case .cancelled: state = .signedOut
            case .failed(let message): state = .failed(message)
            }
        }
    }

    /// Pauses or resumes a device through the Starlink account; the router's current list is read over the LAN first.
    func setPaused(_ paused: Bool, client: WifiClient, routerHost: String) async throws {
        guard let clientId = client.clientId, let router = RouterAPI(host: routerHost) else { throw PauseError.unknownClient }
        try await cloud.setPaused(paused, clientId: clientId, macAddress: client.mac) { try await router.rawConfigResponse() }
    }

    func setNameservers(_ servers: [String]) async throws { try await cloud.setNameservers(servers) }

    var isConnected: Bool { if case .connected = state { true } else { false } }

    func signOut() {
        Task {
            await cloud.disconnect()
            state = .signedOut
        }
    }
}

/// Hosts the real starlink.com login page. The app never sees the password; it
/// only adopts the session cookie once the page has created it (same approach as
/// Dishylink electron/cloud.ts, MIT).
@MainActor
final class LoginWindow: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver, NSWindowDelegate {
    enum Outcome { case connected, cancelled, failed(String) }

    private static let loginURL = URL(string: "https://www.starlink.com/account")!

    private let cloud: StarlinkCloud
    private let window: NSWindow
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var adopting = false

    init(cloud: StarlinkCloud) {
        self.cloud = cloud
        let configuration = WKWebViewConfiguration()
        // Nothing from the login page (cookies, cache) is written to disk; the session cookie goes to the Keychain only.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1124, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Sign in to Starlink"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        webView.navigationDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    func focus() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }

    func run() async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.load(URLRequest(url: Self.loginURL))
            focus()
        }
    }

    private func finish(_ outcome: Outcome) {
        guard let continuation else { return }
        self.continuation = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        window.delegate = nil
        window.close()
        continuation.resume(returning: outcome)
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { Task { @MainActor in await adopt() } }
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { @MainActor in await adopt() } }
    func windowWillClose(_ notification: Notification) { finish(.cancelled) }

    /// Tries the session as soon as the SSO cookie exists. The first call can land
    /// a beat before the cookie is usable, so it retries briefly.
    private func adopt() async {
        guard continuation != nil, !adopting else { return }
        adopting = true
        defer { adopting = false }
        var lastError: Error?
        for attempt in 0..<4 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(700)) }
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain.hasSuffix("starlink.com") }
            let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            guard StarlinkCookies.hasSSO(header) else { continue }
            do {
                try await cloud.connect(cookie: header)
                finish(.connected)
                return
            } catch {
                lastError = error
                if case CloudError.http(let status, _) = error, status >= 500 { continue }
            }
        }
        // Only a rejected session ends the attempt; a page still loading keeps the window open.
        if let lastError, case CloudError.sessionExpired = lastError { return }
        if let lastError, !(lastError is CloudError) { finish(.failed(lastError.localizedDescription)) }
    }
}
