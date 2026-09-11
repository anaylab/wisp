//
//  ProviderKeychainStore.swift
//  leanring-buddy
//
//  Stores the API key for each bring-your-own-key cloud provider in the login
//  Keychain. The user pastes their own key in the dashboard; Wisp only saves
//  and retrieves it. A key is never written to UserDefaults or Info.plist, and
//  never logged.
//
//  There is exactly one key per provider, keyed by the provider's raw value, so
//  saving replaces rather than accumulates. Deleting a provider's key is how a
//  cloud provider is disabled.
//
//  Nothing consumes this type yet — it is landed ahead of the cloud providers
//  and the settings UI so those later changes stay small.
//

import Foundation
import Security

/// The Keychain-backed store of per-provider API keys.
enum ProviderKeychainStore {
    /// Namespaces every item this store writes, so its keys never collide with
    /// anything else in the login Keychain.
    private static let keychainServiceName = "com.wisp.provider-api-keys"

    /// Saves (or replaces) the API key for one cloud provider.
    ///
    /// Delete-then-add is used rather than `SecItemUpdate` because there is only
    /// ever one item per provider, which makes replacement the simpler and less
    /// error-prone operation.
    static func save(_ apiKey: String, for provider: BuddyChatProviderKind) {
        deleteAPIKey(for: provider)

        guard let apiKeyData = apiKey.data(using: .utf8) else { return }

        let addItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: provider.rawValue,
            kSecValueData as String: apiKeyData,
            // The app runs in the background from the menu bar, so the key must
            // be readable after the first unlock following a reboot rather than
            // only while the screen is actively unlocked.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        SecItemAdd(addItemQuery as CFDictionary, nil)
    }

    /// Returns the stored API key for a provider, or `nil` if none is set.
    static func apiKey(for provider: BuddyChatProviderKind) -> String? {
        let copyItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: provider.rawValue,
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

    /// Whether a key is stored for the provider. A convenience over `apiKey` for
    /// callers — the settings UI, the factory — that only need to know whether a
    /// cloud provider is configured, not the secret itself.
    static func hasAPIKey(for provider: BuddyChatProviderKind) -> Bool {
        apiKey(for: provider) != nil
    }

    /// Removes the stored key for a provider, disabling it.
    static func deleteAPIKey(for provider: BuddyChatProviderKind) {
        let deleteItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: provider.rawValue
        ]

        SecItemDelete(deleteItemQuery as CFDictionary)
    }
}
