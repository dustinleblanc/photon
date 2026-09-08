import Foundation
import Security

// Thin wrapper around Keychain Services for storing Proton credentials and
// the resumable session token. Nothing here ever touches disk in plaintext.
enum Keychain {
    private static let service = "com.dustinleblanc.photon-migrate-bar"

    static func save(account: String, string: String) {
        save(account: account, data: Data(string.utf8))
    }

    static func save(account: String, data: Data) {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func loadString(account: String) -> String? {
        guard let data = loadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func loadData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainAccount {
    static let username = "proton-username"
    static let session = "proton-session"
}
