//
//  ServiceIntegration.swift
//  leanring-buddy
//
//  The services Wisp can keep an eye on from the notch — GitHub, Vercel,
//  Stripe, n8n, Resend, Notion and Cal.com — and the value types their status
//  is reported in. Modeled on Coucou's integration pills (MIT).
//
//  Every service is opt-in: nothing is fetched until the user pastes a key in
//  Connections → Services. Keys live in the login Keychain
//  (`ServiceIntegrationKeychainStore`), never in UserDefaults or a file, and
//  requests go straight from this Mac to the service — no relay.
//

import Foundation
import Security

nonisolated enum ServiceIntegrationKind: String, CaseIterable, Identifiable, Sendable {
    case github
    case vercel
    case stripe
    case n8n
    case resend
    case notion
    case calcom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .vercel: return "Vercel"
        case .stripe: return "Stripe"
        case .n8n: return "n8n"
        case .resend: return "Resend"
        case .notion: return "Notion"
        case .calcom: return "Cal.com"
        }
    }

    var symbolName: String {
        switch self {
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .vercel: return "triangle.fill"
        case .stripe: return "creditcard"
        case .n8n: return "point.3.connected.trianglepath.dotted"
        case .resend: return "paperplane"
        case .notion: return "doc.text"
        case .calcom: return "calendar.badge.clock"
        }
    }

    /// What the notch shows and announces for this service.
    var whatWispWatches: String {
        switch self {
        case .github: return "Your repositories and stars, and new stars as they come in."
        case .vercel: return "Your latest deployments, and a note in the notch when one finishes or fails."
        case .stripe: return "Your balance and latest payments, and a note in the notch for each new payment."
        case .n8n: return "Your latest workflow runs, and a note in the notch when one fails."
        case .resend: return "Your latest sent emails, and a note in the notch when one bounces."
        case .notion: return "The pages you edited most recently."
        case .calcom: return "Your upcoming bookings, and a note in the notch for each new one."
        }
    }

    /// Where to create the key, shown as a link next to the field.
    var keyCreationURL: URL? {
        switch self {
        case .github: return URL(string: "https://github.com/settings/personal-access-tokens")
        case .vercel: return URL(string: "https://vercel.com/account/settings/tokens")
        case .stripe: return URL(string: "https://dashboard.stripe.com/apikeys")
        case .n8n: return nil
        case .resend: return URL(string: "https://resend.com/api-keys")
        case .notion: return URL(string: "https://www.notion.so/profile/integrations")
        case .calcom: return URL(string: "https://app.cal.com/settings/developer/api-keys")
        }
    }

    /// Where a click on the service's notch row goes.
    var dashboardURL: URL? {
        switch self {
        case .github: return URL(string: "https://github.com")
        case .vercel: return URL(string: "https://vercel.com/dashboard")
        case .stripe: return URL(string: "https://dashboard.stripe.com")
        case .n8n: return nil
        case .resend: return URL(string: "https://resend.com/emails")
        case .notion: return URL(string: "https://www.notion.so")
        case .calcom: return URL(string: "https://app.cal.com/bookings/upcoming")
        }
    }

    var credentialFields: [ServiceCredentialField] {
        switch self {
        case .github:
            return [ServiceCredentialField(fieldKey: "token", label: "Token", placeholder: "github_pat_…", isSecret: true,
                                           hint: "Read-only access to your repositories is enough.")]
        case .vercel:
            return [ServiceCredentialField(fieldKey: "token", label: "Token", placeholder: "Vercel access token", isSecret: true, hint: nil)]
        case .stripe:
            return [ServiceCredentialField(fieldKey: "apiKey", label: "Restricted key", placeholder: "rk_live_…", isSecret: true,
                                           hint: "Use a restricted key with read access to Balance and Charges.")]
        case .n8n:
            return [
                ServiceCredentialField(fieldKey: "baseURL", label: "Instance URL", placeholder: "https://n8n.example.com", isSecret: false, hint: nil),
                ServiceCredentialField(fieldKey: "apiKey", label: "API key", placeholder: "n8n API key", isSecret: true,
                                       hint: "Settings → n8n API in your instance."),
            ]
        case .resend:
            return [ServiceCredentialField(fieldKey: "apiKey", label: "API key", placeholder: "re_…", isSecret: true,
                                           hint: "Needs full access — Resend's sending-only keys can't list emails.")]
        case .notion:
            return [ServiceCredentialField(fieldKey: "token", label: "Integration secret", placeholder: "ntn_…", isSecret: true,
                                           hint: "Share the pages you want Wisp to see with the integration.")]
        case .calcom:
            return [ServiceCredentialField(fieldKey: "apiKey", label: "API key", placeholder: "cal_live_…", isSecret: true, hint: nil)]
        }
    }

    /// How often to check while configured. Payments and deploys are worth
    /// knowing about quickly; stars and pages aren't.
    var pollIntervalSeconds: TimeInterval {
        switch self {
        case .stripe, .vercel, .n8n: return 60
        case .resend: return 120
        case .github, .notion, .calcom: return 300
        }
    }
}

nonisolated struct ServiceCredentialField: Identifiable, Sendable {
    let fieldKey: String
    let label: String
    let placeholder: String
    let isSecret: Bool
    let hint: String?

    var id: String { fieldKey }
}

nonisolated enum ServiceIntegrationTone: Sendable {
    case good
    case bad
    case neutral
}

/// One line in a service's status: a payment, a deployment, a page.
nonisolated struct ServiceIntegrationRow: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let detail: String
    let tone: ServiceIntegrationTone
    let url: URL?
}

/// Something worth telling the user about now: a new payment, a failed deploy.
nonisolated struct ServiceIntegrationEvent: Identifiable, Equatable, Sendable {
    let id: String
    let serviceKind: ServiceIntegrationKind
    let title: String
    let detail: String
    let tone: ServiceIntegrationTone
    let url: URL?
}

/// A service's state after one fetch.
nonisolated struct ServiceIntegrationSnapshot: Equatable, Sendable {
    /// One short line for the notch row: "$1,284.10 available", "12 repos · 340 ★".
    let headline: String
    let rows: [ServiceIntegrationRow]
    /// Events seen in this fetch, newest first. Which are new is decided by
    /// comparing ids with the previous fetch, so the first fetch announces nothing.
    let announceableEvents: [ServiceIntegrationEvent]

    /// Plain text for the agent tool and for copying.
    func plainTextSummary(serviceName: String) -> String {
        var lines = ["\(serviceName): \(headline)"]
        for row in rows {
            lines.append("- \(row.title)" + (row.detail.isEmpty ? "" : " — \(row.detail)"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Each service's credentials in the login Keychain.
nonisolated enum ServiceIntegrationKeychainStore {
    private static let keychainServiceName = "com.wisp.service-integration-keys"

    private static func accountName(for kind: ServiceIntegrationKind, fieldKey: String) -> String {
        "\(kind.rawValue).\(fieldKey)"
    }

    static func save(_ value: String, for kind: ServiceIntegrationKind, fieldKey: String) {
        delete(for: kind, fieldKey: fieldKey)
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return }
        let addItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: accountName(for: kind, fieldKey: fieldKey),
            kSecValueData as String: Data(trimmedValue.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addItemQuery as CFDictionary, nil)
    }

    static func value(for kind: ServiceIntegrationKind, fieldKey: String) -> String? {
        let copyItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: accountName(for: kind, fieldKey: fieldKey),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var copiedItem: AnyObject?
        guard SecItemCopyMatching(copyItemQuery as CFDictionary, &copiedItem) == errSecSuccess,
              let valueData = copiedItem as? Data else { return nil }
        return String(data: valueData, encoding: .utf8)
    }

    static func delete(for kind: ServiceIntegrationKind, fieldKey: String) {
        let deleteItemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: accountName(for: kind, fieldKey: fieldKey),
        ]
        SecItemDelete(deleteItemQuery as CFDictionary)
    }

    /// Configured means every field has a value.
    static func isConfigured(_ kind: ServiceIntegrationKind) -> Bool {
        kind.credentialFields.allSatisfy { value(for: kind, fieldKey: $0.fieldKey) != nil }
    }

    static func credentials(for kind: ServiceIntegrationKind) -> [String: String]? {
        var credentialsByFieldKey: [String: String] = [:]
        for credentialField in kind.credentialFields {
            guard let storedValue = value(for: kind, fieldKey: credentialField.fieldKey) else { return nil }
            credentialsByFieldKey[credentialField.fieldKey] = storedValue
        }
        return credentialsByFieldKey
    }

    static func deleteAll(for kind: ServiceIntegrationKind) {
        for credentialField in kind.credentialFields {
            delete(for: kind, fieldKey: credentialField.fieldKey)
        }
    }
}
