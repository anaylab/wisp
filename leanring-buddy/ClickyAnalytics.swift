//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Usage analytics — disabled.
//
//  This app originally reported to the PostHog project belonging to its
//  original author, and two of the events carried the actual content of the
//  conversation: the user's full transcript on every utterance, and the
//  assistant's full reply on every response. That is a reasonable thing for an
//  author to instrument in their own product, and an unreasonable thing to
//  leave running in someone else's copy — particularly one whose whole point
//  is now that it runs locally and sends nothing anywhere.
//
//  Every function below is kept with its original signature so the call sites
//  throughout the app continue to describe what happens and when. They simply
//  do nothing unless analytics are explicitly switched on by setting
//  `AnalyticsEnabled` to true in Info.plist, which also requires supplying an
//  API key for a project the user actually owns.
//

import Foundation
import PostHog

enum ClickyAnalytics {

    // MARK: - Configuration

    /// Off unless deliberately enabled. Absent key means disabled.
    private static var isEnabled: Bool {
        AppBundleConfiguration.stringValue(forKey: "AnalyticsEnabled")?.lowercased() == "true"
    }

    /// Deliberately not hardcoded. Anyone enabling analytics should be sending
    /// data to their own project, not to whichever one happened to ship in the
    /// source they started from.
    private static var apiKey: String? {
        AppBundleConfiguration.stringValue(forKey: "AnalyticsAPIKey")
    }

    private static var host: String {
        AppBundleConfiguration.stringValue(forKey: "AnalyticsHost") ?? "https://us.i.posthog.com"
    }

    // MARK: - Setup

    static func configure() {
        guard isEnabled, let apiKey, !apiKey.isEmpty else {
            print("📊 Analytics: disabled — nothing is sent off this machine")
            return
        }

        PostHogSDK.shared.setup(PostHogConfig(apiKey: apiKey, host: host))
        print("📊 Analytics: enabled, reporting to \(host)")
    }

    /// Single point through which every event passes, so there is exactly one
    /// place that can let data leave.
    private static func capture(_ event: String, properties: [String: Any]? = nil) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(event, properties: properties)
    }

    // MARK: - App Lifecycle

    /// Fired once on every app launch in applicationDidFinishLaunching.
    static func trackAppOpened() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        capture("app_opened", properties: ["app_version": version])
    }

    // MARK: - Onboarding

    /// User clicked the Start button to begin onboarding for the first time.
    static func trackOnboardingStarted() {
        capture("onboarding_started")
    }

    /// User clicked "Watch Onboarding Again" from the panel footer.
    static func trackOnboardingReplayed() {
        capture("onboarding_replayed")
    }

    /// The onboarding video finished playing to the end.
    static func trackOnboardingVideoCompleted() {
        capture("onboarding_video_completed")
    }

    /// The 40s onboarding demo interaction where Clicky points at something.
    static func trackOnboardingDemoTriggered() {
        capture("onboarding_demo_triggered")
    }

    // MARK: - Permissions

    /// All three permissions (accessibility, screen recording, mic) are granted.
    static func trackAllPermissionsGranted() {
        capture("all_permissions_granted")
    }

    /// A single permission was granted. Called when polling detects a change.
    static func trackPermissionGranted(permission: String) {
        capture("permission_granted", properties: ["permission": permission])
    }

    // MARK: - Voice Interaction

    /// User pressed the push-to-talk shortcut (control+option) to start talking.
    static func trackPushToTalkStarted() {
        capture("push_to_talk_started")
    }

    /// User released the shortcut — transcript is being finalized.
    static func trackPushToTalkReleased() {
        capture("push_to_talk_released")
    }

    /// Transcription completed and the user's message is being sent to the AI.
    ///
    /// The transcript itself is no longer included. Only its length is, which
    /// answers questions about usage without carrying what was said.
    static func trackUserMessageSent(transcript: String) {
        capture("user_message_sent", properties: ["character_count": transcript.count])
    }

    /// The model responded and the response is being spoken via TTS.
    ///
    /// As above: length only, never the reply itself.
    static func trackAIResponseReceived(response: String) {
        capture("ai_response_received", properties: ["character_count": response.count])
    }

    /// The response included a [POINT:x,y:label] coordinate tag, so the buddy
    /// is flying to point at a UI element.
    ///
    /// The element's label is dropped — it describes what is on the user's
    /// screen, which is content rather than usage.
    static func trackElementPointed(elementLabel: String?) {
        capture("element_pointed")
    }

    // MARK: - Errors

    /// An error occurred during the AI response pipeline.
    static func trackResponseError(error: String) {
        capture("response_error", properties: ["error": error])
    }

    /// An error occurred during TTS playback.
    static func trackTTSError(error: String) {
        capture("tts_error", properties: ["error": error])
    }
}
