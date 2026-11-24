import Foundation
import Security

public enum StarlinkCookies {
    public static func hasSSO(_ header: String) -> Bool { header.contains("Starlink.Com.Sso=") }

    /// starlink.com or a subdomain of it; a bare suffix match would also accept "evilstarlink.com".
    public static func isStarlinkDomain(_ domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == "starlink.com" || host.hasSuffix(".starlink.com")
    }

    /// Applies Set-Cookie results to a Cookie header like a browser jar: same name
    /// replaces, a new name is added, an expired one is removed. Starlink splits a
    /// large token into a marker plus numbered pieces that must all be re-sent
    /// together, so every cookie is kept by name and none is dropped selectively.
    /// Logic from Dishylink cloud/starlinkCloudHandler.ts (MIT).
    public static func merge(_ header: String, with cookies: [HTTPCookie], now: Date = Date()) -> String {
        guard !cookies.isEmpty else { return header }
        var order: [String] = []
        var jar: [String: String] = [:]
        func set(_ name: String, _ value: String?) {
            if let value {
                if jar[name] == nil { order.append(name) }
                jar[name] = value
            } else if jar.removeValue(forKey: name) != nil {
                order.removeAll { $0 == name }
            }
        }
        for part in header.split(separator: ";") {
            guard let equals = part.firstIndex(of: "="), equals != part.startIndex else { continue }
            set(part[..<equals].trimmingCharacters(in: .whitespaces), part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces))
        }
        for cookie in cookies {
            let expired = cookie.expiresDate.map { $0 <= now } ?? false
            set(cookie.name, expired ? nil : cookie.value)
        }
        return order.map { "\($0)=\(jar[$0] ?? "")" }.joined(separator: "; ")
    }
}

public protocol SessionStore: Sendable {
    func read() -> String?
    func write(_ cookie: String) throws
    func clear()
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? { "Keychain error \(status)" }
}

/// The session cookie is a credential: it lives only in the login Keychain,
/// readable while the Mac is unlocked, never synced.
public struct KeychainSessionStore: SessionStore {
    private let service: String
    private let account: String

    public init(service: String = "app.starpulse.mac", account: String = "starlink-session") {
        self.service = service
        self.account = account
    }

    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let cookie = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return cookie.isEmpty ? nil : cookie
    }

    public func write(_ cookie: String) throws {
        SecItemDelete(identity as CFDictionary)
        var attributes = identity
        attributes[kSecValueData as String] = Data(cookie.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    public func clear() { SecItemDelete(identity as CFDictionary) }
}
