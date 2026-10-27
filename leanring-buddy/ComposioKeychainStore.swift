//
//  ComposioKeychainStore.swift
//  leanring-buddy
//
//  Stores the Composio API key in the login Keychain — never in UserDefaults,
//  the config file, or a log. The user pastes their own key in the marketplace;
//  Wisp only saves and retrieves it, and sends it as the `x-api-key` header on
//  Composio API calls and on the remote MCP transport.
//
//  Mirrors ProviderKeychainStore. There is exactly one Composio key, so saving
//  replaces rather than accumulates; deleting it disconnects Composio.
//

import Foundation
import Security

enum ComposioKeychainStore {
    private static let keychainServiceName = "com.wisp.composio-api-key"
    private static let account = "composio"

    static func save(_ apiKey: String) {
        delete()

        guard let apiKeyData = apiKey.data(using: .utf8) else { return }

        let addItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: apiKeyData,
            // The app runs in the background from the menu bar, so the key must
            // be readable after the first unlock following a reboot.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemAdd(addItemQuery as CFDictionary, nil)
    }

    static func apiKey() -> String? {
        let copyItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var copiedItem: AnyObject?
        let copyStatus = SecItemCopyMatching(copyItemQuery as CFDictionary, &copiedItem)

        guard copyStatus == errSecSuccess,
              let apiKeyData = copiedItem as? Data,
              let apiKey = String(data: apiKeyData, encoding: .utf8) else {
            return nil
        }

        return apiKey
    }

    static func hasAPIKey() -> Bool {
        apiKey() != nil
    }

    static func delete() {
        let deleteItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(deleteItemQuery as CFDictionary)
    }
}
