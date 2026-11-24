import Foundation
import Testing
@testable import StarPulseCore

private final class MemoryStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String? = nil) { self.value = value }
    func read() -> String? { lock.withLock { value } }
    func write(_ cookie: String) throws { lock.withLock { value = cookie } }
    func clear() { lock.withLock { value = nil } }
}

private func response(_ url: URL, _ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}

private let serviceLines = """
{"content":{"results":[{"serviceLineNumber":"SL-1","accountReferenceId":"ACC-1","nickname":"Home",
"subscription":{"productDescription":"Residential"},"serviceAddress":{"locality":"Springfield","administrativeArea":"IL"},
"userTerminals":[{"userTerminalId":"a"}]}]}}
""".data(using: .utf8)!

@Test func mergeReplacesAddsAndRemovesExpired() {
    let url = URL(string: "https://api.starlink.com")!
    let issued = HTTPCookie.cookies(withResponseHeaderFields: [
        "Set-Cookie": "Access.V1=new; Path=/, Old=gone; Max-Age=0; Path=/, Fresh=1; Path=/",
    ], for: url)
    let merged = StarlinkCookies.merge("Starlink.Com.Sso=abc; Access.V1=old; Old=x", with: issued)
    #expect(merged == "Starlink.Com.Sso=abc; Access.V1=new; Fresh=1")
}

@Test func connectRejectsCookieWithoutSSO() async {
    let cloud = StarlinkCloud(store: MemoryStore(), transport: HTTPTransport { _ in throw URLError(.notConnectedToInternet) })
    await #expect(throws: CloudError.badSession) { try await cloud.connect(cookie: "foo=bar") }
}

@Test func connectStoresSessionAndParsesAccount() async throws {
    let store = MemoryStore()
    let cloud = StarlinkCloud(store: store, transport: HTTPTransport { request in
        let url = request.url!
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("Starlink.Com.Sso=abc") == true)
        if url.path.contains("auth-rp") { return (Data(#"{"name":"Jane Doe","email":"user@example.com"}"#.utf8), response(url, 200)) }
        return (serviceLines, response(url, 200))
    })
    try await cloud.connect(cookie: " Starlink.Com.Sso=abc ")
    #expect(store.read() == "Starlink.Com.Sso=abc")
    let account = try await cloud.account()
    #expect(account.name == "Jane Doe")
    #expect(account.plan == "Residential")
    #expect(account.nickname == "Home")
    #expect(account.locality == "Springfield, IL")
    #expect(account.terminalCount == 1)
}

@Test func deadSessionIsClearedOnConnectAndReportedOnRefresh() async throws {
    let store = MemoryStore()
    let cloud = StarlinkCloud(store: store, transport: HTTPTransport { request in (Data(), response(request.url!, 401)) })
    await #expect(throws: CloudError.sessionExpired) { try await cloud.connect(cookie: "Starlink.Com.Sso=dead") }
    #expect(store.read() == nil)

    let kept = MemoryStore("Starlink.Com.Sso=old")
    let later = StarlinkCloud(store: kept, transport: HTTPTransport { request in (Data(), response(request.url!, 403)) })
    await #expect(throws: CloudError.sessionExpired) { try await later.account() }
    #expect(kept.read() != nil)
}

@Test func refreshPersistsReissuedCookies() async throws {
    let store = MemoryStore("Starlink.Com.Sso=abc; Access.V1=old")
    let cloud = StarlinkCloud(store: store, transport: HTTPTransport { request in
        let url = request.url!
        if url.path.contains("auth-rp") {
            return (Data("{}".utf8), response(url, 200, headers: ["Set-Cookie": "Access.V1=new; Path=/"]))
        }
        return (serviceLines, response(url, 200))
    })
    _ = try await cloud.account()
    #expect(store.read() == "Starlink.Com.Sso=abc; Access.V1=new")
}

@Test func signedOutAccountThrowsNotConnected() async {
    let cloud = StarlinkCloud(store: MemoryStore(), transport: HTTPTransport { _ in throw URLError(.badURL) })
    await #expect(throws: CloudError.notConnected) { try await cloud.account() }
}

@Test func onlyStarlinkCookieDomainsAreKept() {
    #expect(StarlinkCookies.isStarlinkDomain("starlink.com"))
    #expect(StarlinkCookies.isStarlinkDomain(".starlink.com"))
    #expect(StarlinkCookies.isStarlinkDomain("api.starlink.com"))
    #expect(!StarlinkCookies.isStarlinkDomain("evilstarlink.com"))
    #expect(!StarlinkCookies.isStarlinkDomain("starlink.com.example.net"))
}
