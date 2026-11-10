// SPDX-License-Identifier: MPL-2.0
import Foundation
import Security

/// The device token and its server live in the Keychain, on this device only. They stay readable
/// after the first unlock so a payment captured with the phone locked can still sync. iOS keeps
/// Keychain items when the app is deleted, so a reinstall on the same iPhone can offer to continue
/// with the same account (docs/adr/0007-passkeys-in-the-app.md).
enum Keychain {
    static let token = "harina.device-token"
    static let server = "harina.server"

    static func save(_ value: String, for service: String = token) {
        delete(service)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(_ service: String = token) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ service: String = token) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}
