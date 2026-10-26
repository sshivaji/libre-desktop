import Foundation
import Security
import LocalAuthentication

enum LibreKeychain {
    private static func query(history: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: history ? "local.shiv.libredesktop.libreview" : "local.shiv.libredesktop.librelinkup", kSecAttrAccount as String: "account"]
    }
    static func load(history: Bool = false) throws -> LibreAccount? {
        var request = query(history: history)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Background startup must not open a Keychain permission dialog.
        let context = LAContext(); context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let account = try? JSONDecoder().decode(LibreAccount.self, from: data) else { throw LibreError.keychain }
        return account
    }
    static func save(_ account: LibreAccount, history: Bool = false) throws {
        let query = query(history: history)
        let data = try JSONEncoder().encode(account)
        let changes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LibreError.keychain }
        } else if status != errSecSuccess { throw LibreError.keychain }
    }
    static func delete(history: Bool = false) throws {
        let status = SecItemDelete(query(history: history) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LibreError.keychain }
    }
}
