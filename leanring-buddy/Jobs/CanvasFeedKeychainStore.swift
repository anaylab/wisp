//
//  CanvasFeedKeychainStore.swift
//  leanring-buddy
//
//  The Canvas calendar feed URL carries a secret token, so it lives only in the
//  login Keychain: never UserDefaults, ~/.wisp, logs, History or error text.
//  One item, so saving replaces.
//

import Foundation
import Security

nonisolated enum CanvasFeedKeychainStore {
    private static let keychainServiceName = "com.wisp.canvas-feed"
    private static let keychainAccountName = "feed-url"

    struct KeychainError: Error, Equatable, LocalizedError {
        let status: OSStatus
        // Deliberately generic: never echo the URL or Keychain attributes.
        var errorDescription: String? { "Wisp couldn't save your Canvas feed to the Keychain." }
    }

    static func save(_ url: URL) throws {
        guard let urlData = url.absoluteString.data(using: .utf8) else {
            throw KeychainError(status: errSecParam)
        }
        let itemIdentityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName
        ]
        // Update in place when an item exists, so a failed save leaves the previous
        // working link untouched instead of deleting it first.
        let updateStatus = SecItemUpdate(itemIdentityQuery as CFDictionary,
                                         [kSecValueData as String: urlData] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var addItemQuery = itemIdentityQuery
        addItemQuery[kSecValueData as String] = urlData
        // Hourly sync runs while the Mac may be locked after a reboot's first unlock.
        addItemQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addItemQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    static func feedURL() -> URL? {
        let copyItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(copyItemQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: text)
    }

    static func hasFeedURL() -> Bool { feedURL() != nil }

    static func delete() {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName
        ]
        SecItemDelete(deleteQuery as CFDictionary)
    }
}
