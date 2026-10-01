//
//  BrainPreferences.swift
//  leanring-buddy
//
//  The brain's switches, in one place. UserDefaults-backed like
//  `AnnouncementPreferences`; the Brain page's Sources card edits them.
//

import Combine
import Foundation

@MainActor
final class BrainPreferences: ObservableObject {
    static let shared = BrainPreferences()

    private enum Key {
        static let isBrainEnabled = "brain.enabled"
        static let isConversationDigestEnabled = "brain.conversationDigest.enabled"
        static let isInboxWatchingEnabled = "brain.inboxWatching.enabled"
        static let isActivityRecordingEnabled = "brain.activityRecording.enabled"
        static let isActivityTextCaptureEnabled = "brain.activityRecording.captureScreenText"
        static let activityExcludedBundleIdentifiers = "brain.activityRecording.excludedBundleIdentifiers"
        static let activityExcludedDomains = "brain.activityRecording.excludedDomains"
        static let isPromptContextEnabled = "brain.promptContext.enabled"
    }

    /// Master switch. Off: nothing reads from or writes to the brain.
    @Published var isBrainEnabled: Bool { didSet { defaults.set(isBrainEnabled, forKey: Key.isBrainEnabled) } }
    /// File lasting facts from finished conversations (default on).
    @Published var isConversationDigestEnabled: Bool { didSet { defaults.set(isConversationDigestEnabled, forKey: Key.isConversationDigestEnabled) } }
    /// Ingest files dropped into `raw/inbox/` automatically (default on).
    @Published var isInboxWatchingEnabled: Bool { didSet { defaults.set(isInboxWatchingEnabled, forKey: Key.isInboxWatchingEnabled) } }
    /// Record which apps/windows/sites the user works in (default OFF — it
    /// records things the user never asked Wisp about, so it is opt-in).
    @Published var isActivityRecordingEnabled: Bool { didSet { defaults.set(isActivityRecordingEnabled, forKey: Key.isActivityRecordingEnabled) } }
    /// Also keep a little on-screen text (OCR) with each activity sample (default off).
    @Published var isActivityTextCaptureEnabled: Bool { didSet { defaults.set(isActivityTextCaptureEnabled, forKey: Key.isActivityTextCaptureEnabled) } }
    /// Apps never recorded, beyond the built-in list (password managers etc.).
    @Published var activityExcludedBundleIdentifiers: [String] { didSet { defaults.set(activityExcludedBundleIdentifiers, forKey: Key.activityExcludedBundleIdentifiers) } }
    /// Sites never recorded, beyond the built-in list (banking etc.).
    @Published var activityExcludedDomains: [String] { didSet { defaults.set(activityExcludedDomains, forKey: Key.activityExcludedDomains) } }
    /// Put relevant brain pages into each turn (default on).
    @Published var isPromptContextEnabled: Bool { didSet { defaults.set(isPromptContextEnabled, forKey: Key.isPromptContextEnabled) } }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.isBrainEnabled: true,
            Key.isConversationDigestEnabled: true,
            Key.isInboxWatchingEnabled: true,
            Key.isActivityRecordingEnabled: false,
            Key.isActivityTextCaptureEnabled: false,
            Key.isPromptContextEnabled: true
        ])
        isBrainEnabled = defaults.bool(forKey: Key.isBrainEnabled)
        isConversationDigestEnabled = defaults.bool(forKey: Key.isConversationDigestEnabled)
        isInboxWatchingEnabled = defaults.bool(forKey: Key.isInboxWatchingEnabled)
        isActivityRecordingEnabled = defaults.bool(forKey: Key.isActivityRecordingEnabled)
        isActivityTextCaptureEnabled = defaults.bool(forKey: Key.isActivityTextCaptureEnabled)
        activityExcludedBundleIdentifiers = defaults.stringArray(forKey: Key.activityExcludedBundleIdentifiers) ?? []
        activityExcludedDomains = defaults.stringArray(forKey: Key.activityExcludedDomains) ?? []
        isPromptContextEnabled = defaults.bool(forKey: Key.isPromptContextEnabled)
    }
}
