import Foundation

public enum CloudError: Error, Equatable, LocalizedError {
    case notConnected
    case sessionExpired
    case badSession
    case noServiceLine
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: "Not signed in to Starlink."
        case .sessionExpired: "The Starlink session expired. Sign in again."
        case .badSession: "That is not a Starlink session."
        case .noServiceLine: "No service line was found on this account."
        case .http(let status, let path): "Starlink answered HTTP \(status) for \(path)."
        }
    }
}

public struct CloudAccount: Sendable, Equatable {
    public var name: String?
    public var email: String?
    public var plan: String?
    public var nickname: String?
    public var locality: String?
    public var terminalCount = 0
    /// Service address coordinates, used only as the observer position for the satellite view. Kept in memory.
    public var latitude: Double?
    public var longitude: Double?
    public var serviceLineNumber: String?
    public var accountReference: String?
    public init() {}
}

/// Session handling and account reads for starlink.com. Unofficial interface, observed
/// by Dishylink (cloud/starlinkCloudHandler.ts, MIT); it can change without notice.
public actor StarlinkCloud {
    static let authURL = URL(string: "https://api.starlink.com/auth-rp/auth/user")!
    static let apiBase = "https://starlink.com/api"
    static let refreshInterval: TimeInterval = 60 // the access token is short-lived
    static let serviceLinesPath = "/webagg/v2/accounts/service-lines?limit=100&page=0&isConverting=false&serviceAddressId=&onlyActive=false&searchString=&onlyNoUts=false"

    private let store: SessionStore
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date
    private var cachedCookie: String?
    private var cachedAt = Date.distantPast

    public init(store: SessionStore = KeychainSessionStore(), transport: HTTPTransport = .cloud, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.transport = transport
        self.now = now
    }

    public var hasStoredSession: Bool { store.read() != nil }

    /// Stores the cookie, then proves it by refreshing the token and reading the account.
    public func connect(cookie: String) async throws {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard StarlinkCookies.hasSSO(trimmed) else { throw CloudError.badSession }
        try store.write(trimmed)
        cachedCookie = nil
        do { _ = try await account() } catch {
            // A cookie that does not authenticate must not stay stored.
            if error as? CloudError == .sessionExpired { store.clear() }
            throw error
        }
    }

    public func disconnect() {
        store.clear()
        cachedCookie = nil
    }

    private func freshCookie(force: Bool = false) async throws -> String {
        guard let base = store.read() else { throw CloudError.notConnected }
        if !force, let cachedCookie, now().timeIntervalSince(cachedAt) < Self.refreshInterval { return cachedCookie }
        var request = URLRequest(url: Self.authURL)
        request.setValue(base, forHTTPHeaderField: "Cookie")
        let (_, response) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 {
            cachedCookie = nil
            throw CloudError.sessionExpired
        }
        let issued = HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields as? [String: String] ?? [:], for: Self.authURL)
        let merged = StarlinkCookies.merge(base, with: issued, now: now())
        // Persist what Starlink last issued so the next launch resumes from it.
        if merged != base { try? store.write(merged) }
        cachedCookie = merged
        cachedAt = now()
        return merged
    }

    func sessionCookie() async throws -> String { try await freshCookie() }

    func transportSend(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await transport.send(request) }

    func sendChecked(_ request: URLRequest, label: String) async throws -> Data {
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw CloudError.sessionExpired }
        guard (200..<300).contains(response.statusCode) else { throw CloudError.http(response.statusCode, label) }
        return data
    }

    private var writeChain: Task<Void, Never>?

    /// Pauses or resumes one device. The whole client list is rewritten, so the LAN read that
    /// feeds the request and the write itself run one at a time: a later change can never be
    /// built from a list that predates an earlier one.
    public func setPaused(_ paused: Bool, clientId: UInt32, macAddress: String,
                          readRouterId: @escaping @Sendable () async throws -> String,
                          readRouterConfig: @escaping @Sendable () async throws -> [UInt8]) async throws {
        try await serialized {
            let target = try await self.verifiedTarget(readRouterId)
            let existing = try DevicePause.rawClientConfigs(configResponse: try await readRouterConfig())
            let body = try DevicePause.request(targetId: target, existing: existing, clientId: clientId, macAddress: macAddress, paused: paused)
            try await self.sendDeviceRequest(body)
        }
    }

    /// Points the whole network at a DNS service. Shares the one-at-a-time queue with device pauses.
    public func setNameservers(_ nameservers: [String], readRouterId: @escaping @Sendable () async throws -> String) async throws {
        try await serialized {
            let target = try await self.verifiedTarget(readRouterId)
            try await self.sendDeviceRequest(try DnsWrite.request(targetId: target, nameservers: nameservers))
        }
    }

    /// The Starlink app's Content Filtering: a Cloudflare preset, or the router's default DNS.
    public func setContentFilter(_ filter: ContentFilter, readRouterId: @escaping @Sendable () async throws -> String) async throws {
        try await serialized {
            let target = try await self.verifiedTarget(readRouterId)
            let body = try filter.preset.map { try DnsWrite.request(targetId: target, nameservers: $0.servers) } ?? DnsWrite.clear(targetId: target)
            try await self.sendDeviceRequest(body)
        }
    }

    /// Reboot or obstruction-map reset through the account. The dish that answered on the LAN must
    /// be one of the account's dishes, as with the router; the request goes to the account's ID.
    public func dishMaintenance(_ action: DishMaintenance, lanDishId: String) async throws {
        try await serialized {
            let target = try Self.requireAccountDish(lan: lanDishId, account: try await self.accountDishIds())
            try await self.sendDeviceRequest(try action.cloudRequest(dishId: target))
        }
    }

    /// The account's router, confirmed to be the one answering on this LAN. Writes are built from or
    /// decided on LAN reads, and anything on the network can answer at the router's address.
    private func verifiedTarget(_ readRouterId: @Sendable () async throws -> String) async throws -> String {
        let target = try await controllerRouterId()
        try Self.requireSameRouter(lan: try await readRouterId(), account: target)
        return target
    }

    static func requireSameRouter(lan: String, account: String) throws {
        guard !lan.isEmpty, lan.caseInsensitiveCompare(account) == .orderedSame else { throw PauseError.otherRouter }
    }

    private func serialized(_ body: @escaping @Sendable () async throws -> Void) async throws {
        let previous = writeChain
        let work = Task { () async throws -> Void in
            _ = await previous?.value
            try await body()
        }
        writeChain = Task { _ = try? await work.value }
        try await work.value
    }

    private func getData(_ url: URL, cookie: String, label: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw CloudError.sessionExpired }
        guard (200..<300).contains(response.statusCode) else { throw CloudError.http(response.statusCode, label) }
        return data
    }

    public func account() async throws -> CloudAccount {
        let cookie = try await freshCookie()
        async let identityData = try? getData(Self.authURL, cookie: cookie, label: "auth/user")
        let linesData = try await getData(URL(string: Self.apiBase + Self.serviceLinesPath)!, cookie: cookie, label: "service-lines")
        let identity = await identityData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return try CloudAccount.parse(identity: identity, serviceLines: try JSONSerialization.jsonObject(with: linesData))
    }
}

extension CloudAccount {
    /// Shapes follow Dishylink src/lib/starlinkCloud.ts. Identity is optional: a
    /// dead identity call must still leave the plan readable.
    static func parse(identity: Any?, serviceLines: Any) throws -> CloudAccount {
        var account = CloudAccount()
        if let identity = identity as? [String: Any] {
            account.name = identity["name"] as? String ?? identity["givenName"] as? String
            account.email = identity["email"] as? String
        }
        let content = (serviceLines as? [String: Any])?["content"] as? [String: Any]
        guard let first = (content?["results"] as? [[String: Any]])?.first,
              let lineNumber = first["serviceLineNumber"] as? String,
              let reference = first["accountReferenceId"] as? String
        else { throw CloudError.noServiceLine }
        account.serviceLineNumber = lineNumber
        account.accountReference = reference
        account.nickname = (first["nickname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        account.plan = (first["subscription"] as? [String: Any])?["productDescription"] as? String
        if let address = first["serviceAddress"] as? [String: Any] {
            let parts = [address["locality"] as? String, address["administrativeArea"] as? String ?? address["region"] as? String].compactMap { $0 }
            account.locality = parts.isEmpty ? nil : parts.joined(separator: ", ")
            if let geo = address["geoLocation"] as? [String: Any] {
                account.latitude = (geo["latitude"] as? NSNumber)?.doubleValue
                account.longitude = (geo["longitude"] as? NSNumber)?.doubleValue
            }
        }
        account.terminalCount = (first["userTerminals"] as? [[String: Any]])?.count ?? 0
        return account
    }
}
