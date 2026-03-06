import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case notFound
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .notFound: return "No saved credentials found."
        case .saveFailed(let s): return "Keychain save failed: \(s)"
        case .loadFailed(let s): return "Keychain load failed: \(s)"
        case .decodeFailed: return "Could not decode saved credentials."
        }
    }
}

final class CookieKeychainStore {
    private static let service = "com.jeff.kindlesync"
    private static let account = "amazon-session"

    // MARK: - Save

    static func save(_ cookies: [HTTPCookie]) throws {
        let data = try encode(cookies)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String:   data
        ]
        SecItemDelete(query as CFDictionary) // Remove existing before add
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    // MARK: - Load

    static func load() throws -> [HTTPCookie] {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.notFound
        }
        return try decode(data)
    }

    // MARK: - Delete

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Expiry Check

    static func areCookiesExpired(_ cookies: [HTTPCookie]) -> Bool {
        let sessionCookieNames = ["session-token", "session-id"]
        let relevantCookies = cookies.filter { sessionCookieNames.contains($0.name) }
        guard !relevantCookies.isEmpty else { return true }
        let now = Date()
        return relevantCookies.allSatisfy { cookie in
            guard let expires = cookie.expiresDate else { return false }
            return expires < now
        }
    }

    // MARK: - Private Encoding

    private static func encode(_ cookies: [HTTPCookie]) throws -> Data {
        let dicts: [[String: Any]] = cookies.map { cookie in
            var d: [String: Any] = [
                "name":     cookie.name,
                "value":    cookie.value,
                "domain":   cookie.domain,
                "path":     cookie.path,
                "secure":   cookie.isSecure
            ]
            if let exp = cookie.expiresDate {
                d["expires"] = exp.timeIntervalSince1970
            }
            return d
        }
        return try JSONSerialization.data(withJSONObject: dicts)
    }

    private static func decode(_ data: Data) throws -> [HTTPCookie] {
        guard let dicts = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw KeychainError.decodeFailed
        }
        return dicts.compactMap { d -> HTTPCookie? in
            var props: [HTTPCookiePropertyKey: Any] = [:]
            guard let name   = d["name"]   as? String,
                  let value  = d["value"]  as? String,
                  let domain = d["domain"] as? String,
                  let path   = d["path"]   as? String else { return nil }
            props[.name]   = name
            props[.value]  = value
            props[.domain] = domain
            props[.path]   = path
            if let ts = d["expires"] as? TimeInterval {
                props[.expires] = Date(timeIntervalSince1970: ts)
            }
            if let secure = d["secure"] as? Bool, secure {
                props[.secure] = "TRUE"
            }
            return HTTPCookie(properties: props)
        }
    }
}
