//
//  ScreenWatcherStore.swift
//  leanring-buddy
//
//  Runs screen watchers: "tell me when the build finishes" keeps polling the
//  screen the user was on — a capture plus on-device OCR every few seconds —
//  and feeds each reading to the watch's `ScreenWatchEvaluator` (see
//  `ScreenWatcher.swift`). When the condition is met it posts a notification
//  and tells `CompanionManager` (island flash + success cue + the line in the
//  notch). No model call while watching.
//
//  Its own capture, not the turn's: a turn's capture goes through
//  `ScreenshotReuseCache`, which hands back the *previous* frame's bytes when
//  the screen has barely changed — exactly the change a watcher is waiting for
//  ("45%" → "46%", one new "Succeeded" line) — for up to 45 seconds. And the
//  shared OCR cache keeps one entry per display, so a poll storing its frame
//  there could evict the recognition a live turn is about to look up. So each
//  poll captures the watched display directly (cursor hidden), and skips OCR
//  when the pixels are byte-identical to the last poll's — an unchanged screen
//  is never recognised twice — without touching either shared cache.
//
//  Local-only: ScreenCaptureKit and Vision on this machine; nothing leaves it.
//

import AppKit
import Combine
import Foundation
import ScreenCaptureKit
import UserNotifications

/// One watch in progress.
struct ActiveScreenWatcher: Identifiable, Equatable {
    let id: UUID
    let condition: ScreenWatchCondition
    let startDate: Date
    /// The display the user was on when they asked. Polls read only this one,
    /// so a clock or a video on another monitor can't satisfy or upset it.
    let watchedDisplayID: CGDirectDisplayID
}

/// How a watch ended without the user stopping it.
enum ScreenWatchEnding: Equatable {
    case conditionMet(matchedLineText: String?)
    case timedOut
    case couldNotReadScreen
}

@MainActor
final class ScreenWatcherStore: ObservableObject {
    static let shared = ScreenWatcherStore()

    /// Most watches at once. Each one is a capture + OCR every poll (per
    /// display, shared between watches on the same one), so this bounds the
    /// background cost.
    static let maximumActiveWatcherCount = 3
    /// Seconds between polls. Fast enough that "it's done" arrives within a
    /// few seconds; slow enough that a 2-hour watch costs little (OCR takes
    /// ~170ms and is skipped entirely on an unchanged screen).
    static let pollIntervalSeconds: TimeInterval = 3
    /// After this the watch gives up and says so, so a forgotten watch doesn't
    /// poll all day.
    static let watchTimeoutSeconds: TimeInterval = 2 * 60 * 60
    /// Failed captures in a row (screen recording permission revoked, display
    /// gone) before the watches on that display stop.
    static let consecutiveCaptureFailuresBeforeGivingUp = 5
    /// The longest side of the polled frame — the same 896px a turn's capture
    /// uses, at which `.accurate` OCR reads UI text well in ~170ms.
    static let polledFrameLongestSideInPixels = 896

    @Published private(set) var activeWatchers: [ActiveScreenWatcher] = []

    /// Called when a watch ends on its own (met, timed out, unreadable) — not
    /// when the user stops it. Set once by `CompanionManager`, so this store
    /// doesn't reach into it and the `watch_screen` tool's watches land in the
    /// same place as spoken ones.
    var onWatcherEnded: ((ActiveScreenWatcher, ScreenWatchEnding) -> Void)?

    private var evaluatorsByWatcherID: [UUID: ScreenWatchEvaluator] = [:]
    private var pollingTask: Task<Void, Never>?

    /// Per display: the last polled frame's raw pixels and the text read from
    /// them, so an unchanged screen reuses its reading instead of running OCR.
    private var lastReadingByDisplayID: [CGDirectDisplayID: (pixelData: Data, screenLines: [String])] = [:]
    private var consecutiveCaptureFailureCountByDisplayID: [CGDirectDisplayID: Int] = [:]

    private init() {}

    // MARK: - Starting and stopping

    enum StartOutcome: Equatable {
        case started(ActiveScreenWatcher)
        /// An identical watch is already running; it is left as is.
        case alreadyWatching(ActiveScreenWatcher)
        case tooManyWatchers
    }

    /// Starts watching the display the pointer is on for `condition`.
    func startWatching(_ condition: ScreenWatchCondition) -> StartOutcome {
        if let identicalWatcher = activeWatchers.first(where: { $0.condition == condition }) {
            return .alreadyWatching(identicalWatcher)
        }
        guard activeWatchers.count < Self.maximumActiveWatcherCount else { return .tooManyWatchers }

        let newWatcher = ActiveScreenWatcher(
            id: UUID(),
            condition: condition,
            startDate: Date(),
            watchedDisplayID: Self.displayIDUnderPointer()
        )
        activeWatchers.append(newWatcher)
        evaluatorsByWatcherID[newWatcher.id] = ScreenWatchEvaluator(condition: condition)
        startPollingIfNeeded()
        // Asked now, while the user is here and expecting it, rather than at
        // the moment the watch fires when the prompt would hide the result.
        Self.requestNotificationAuthorizationIfNeeded()
        return .started(newWatcher)
    }

    func stopWatching(watcherID: UUID) {
        removeWatcher(withID: watcherID)
    }

    /// Stops every watch. Returns how many were running.
    @discardableResult
    func stopAllWatching() -> Int {
        let stoppedWatcherCount = activeWatchers.count
        for activeWatcher in activeWatchers {
            removeWatcher(withID: activeWatcher.id)
        }
        return stoppedWatcherCount
    }

    private func removeWatcher(withID watcherID: UUID) {
        activeWatchers.removeAll { $0.id == watcherID }
        evaluatorsByWatcherID.removeValue(forKey: watcherID)
        if activeWatchers.isEmpty {
            pollingTask?.cancel()
            pollingTask = nil
            lastReadingByDisplayID.removeAll()
            consecutiveCaptureFailureCountByDisplayID.removeAll()
        }
    }

    // MARK: - Polling

    private func startPollingIfNeeded() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollWatchedDisplays()
                guard !self.activeWatchers.isEmpty else { break }
                try? await Task.sleep(for: .seconds(Self.pollIntervalSeconds))
            }
        }
    }

    private func pollWatchedDisplays() async {
        let pollDate = Date()
        for timedOutWatcher in activeWatchers where pollDate.timeIntervalSince(timedOutWatcher.startDate) >= Self.watchTimeoutSeconds {
            endWatcher(timedOutWatcher, with: .timedOut)
        }

        let watchedDisplayIDs = Set(activeWatchers.map(\.watchedDisplayID))
        for watchedDisplayID in watchedDisplayIDs {
            let screenLines = await readScreenLines(ofDisplay: watchedDisplayID)
            guard !Task.isCancelled else { return }

            guard let screenLines else {
                let failureCount = (consecutiveCaptureFailureCountByDisplayID[watchedDisplayID] ?? 0) + 1
                consecutiveCaptureFailureCountByDisplayID[watchedDisplayID] = failureCount
                if failureCount >= Self.consecutiveCaptureFailuresBeforeGivingUp {
                    for unreadableWatcher in activeWatchers where unreadableWatcher.watchedDisplayID == watchedDisplayID {
                        endWatcher(unreadableWatcher, with: .couldNotReadScreen)
                    }
                }
                continue
            }
            consecutiveCaptureFailureCountByDisplayID[watchedDisplayID] = 0

            // Watches may have been stopped while the capture was in flight, so
            // the list is re-read here rather than captured before the await.
            for activeWatcher in activeWatchers where activeWatcher.watchedDisplayID == watchedDisplayID {
                guard var evaluator = evaluatorsByWatcherID[activeWatcher.id] else { continue }
                let evaluation = evaluator.observe(screenLines: screenLines)
                evaluatorsByWatcherID[activeWatcher.id] = evaluator
                if case .conditionMet(let matchedLineText) = evaluation {
                    endWatcher(activeWatcher, with: .conditionMet(matchedLineText: matchedLineText))
                }
            }
        }
    }

    private func endWatcher(_ endedWatcher: ActiveScreenWatcher, with ending: ScreenWatchEnding) {
        guard activeWatchers.contains(where: { $0.id == endedWatcher.id }) else { return }
        removeWatcher(withID: endedWatcher.id)
        print("👁️ Screen watch ended (\(endedWatcher.condition.summaryText)): \(ending)")
        Self.postNotification(for: endedWatcher, ending: ending)
        onWatcherEnded?(endedWatcher, ending)
    }

    // MARK: - Reading the screen

    /// The text lines on one display now, or nil when it couldn't be captured.
    /// Lines in the menu bar strip are left out: the menu bar clock changes
    /// every minute, which would look like work happening (and then settling).
    private func readScreenLines(ofDisplay displayID: CGDirectDisplayID) async -> [String]? {
        guard let capturedFrame = await Self.captureFrame(ofDisplay: displayID),
              let pixelData = capturedFrame.dataProvider?.data as Data? else {
            return nil
        }

        if let lastReading = lastReadingByDisplayID[displayID], lastReading.pixelData == pixelData {
            return lastReading.screenLines
        }

        let frameSizeInPixels = CGSize(width: capturedFrame.width, height: capturedFrame.height)
        let recognitionResult = await ScreenTextRecognizer.recognizeText(
            in: capturedFrame,
            screenshotSizeInPixels: frameSizeInPixels
        )
        let menuBarStripHeightInPixels = Self.menuBarStripFraction(ofDisplay: displayID) * frameSizeInPixels.height

        let screenLines = recognitionResult.lines
            .filter { $0.confidence >= ScreenTextSnapshot.minimumLineConfidence }
            .filter { $0.boundingBoxInScreenshotPixels.midY > menuBarStripHeightInPixels }
            .map { ScreenTextSnapshot.normalizedLineText($0.text) }
            .filter { !$0.isEmpty }

        lastReadingByDisplayID[displayID] = (pixelData, screenLines)
        return screenLines
    }

    /// One frame of the display, Wisp's own windows excluded and the pointer
    /// hidden (so moving the mouse isn't a change), scaled to 896px.
    private static func captureFrame(ofDisplay displayID: CGDirectDisplayID) async -> CGImage? {
        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let watchedDisplay = shareableContent.displays.first(where: { $0.displayID == displayID })
                    ?? shareableContent.displays.first else { return nil }

            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            let ownAppWindows = shareableContent.windows.filter { window in
                window.owningApplication?.bundleIdentifier == ownBundleIdentifier
            }
            let contentFilter = SCContentFilter(display: watchedDisplay, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            configuration.showsCursor = false
            let aspectRatio = CGFloat(watchedDisplay.width) / CGFloat(max(watchedDisplay.height, 1))
            if watchedDisplay.width >= watchedDisplay.height {
                configuration.width = polledFrameLongestSideInPixels
                configuration.height = Int(CGFloat(polledFrameLongestSideInPixels) / aspectRatio)
            } else {
                configuration.height = polledFrameLongestSideInPixels
                configuration.width = Int(CGFloat(polledFrameLongestSideInPixels) * aspectRatio)
            }

            return try await SCScreenshotManager.captureImage(contentFilter: contentFilter, configuration: configuration)
        } catch {
            print("👁️ Screen watch capture failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// How much of the display's height, from the top, the menu bar takes —
    /// measured from the screen when it can be, else a notched menu bar's ~38pt.
    private static func menuBarStripFraction(ofDisplay displayID: CGDirectDisplayID) -> CGFloat {
        guard let screen = screen(withDisplayID: displayID), screen.frame.height > 0 else { return 0.04 }
        let menuBarHeightInPoints = max(
            screen.frame.maxY - screen.visibleFrame.maxY,
            screen.safeAreaInsets.top,
            24
        )
        return min(menuBarHeightInPoints, 60) / screen.frame.height
    }

    private static func screen(withDisplayID displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }
    }

    private static func displayIDUnderPointer() -> CGDirectDisplayID {
        let pointerLocation = NSEvent.mouseLocation
        let screenUnderPointer = NSScreen.screens.first { $0.frame.contains(pointerLocation) } ?? NSScreen.main
        return (screenUnderPointer?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
            ?? CGMainDisplayID()
    }

    // MARK: - Wording and notification

    /// What Wisp says, shows and notifies when a watch ends.
    static func endingMessage(for endedWatcher: ActiveScreenWatcher, ending: ScreenWatchEnding) -> String {
        switch ending {
        case .conditionMet(let matchedLineText):
            switch endedWatcher.condition {
            case .textAppears(let targetText):
                if let matchedLineText, ScreenWatchTextMatching.normalizedText(matchedLineText) != ScreenWatchTextMatching.normalizedText(targetText) {
                    return "“\(targetText)” is on screen now: \(matchedLineText)"
                }
                return "“\(targetText)” is on screen now."
            case .textDisappears(let targetText):
                return "“\(targetText)” is gone from the screen."
            case .screenTextSettles:
                return "your screen has stopped changing — looks like it's finished."
            }
        case .timedOut:
            return "i stopped watching for \(endedWatcher.condition.summaryText) — it's been two hours."
        case .couldNotReadScreen:
            return "i stopped watching for \(endedWatcher.condition.summaryText) — i couldn't read the screen. screen recording permission may be off."
        }
    }

    private static func requestNotificationAuthorizationIfNeeded() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    /// Posts the ending as a system notification, so it reaches the user in
    /// another app or Space. Silent while quiet mode is on (the user is on a
    /// call) — the banner still appears, it just doesn't chime into the call.
    private static func postNotification(for endedWatcher: ActiveScreenWatcher, ending: ScreenWatchEnding) {
        let notificationBody = endingMessage(for: endedWatcher, ending: ending)
        let notificationTitle: String
        switch ending {
        case .conditionMet: notificationTitle = "Screen watch"
        case .timedOut, .couldNotReadScreen: notificationTitle = "Stopped watching"
        }
        let shouldPlaySound = !QuietModeMonitor.shared.isQuiet

        Task {
            let notificationCenter = UNUserNotificationCenter.current()
            let isAuthorized = (try? await notificationCenter.requestAuthorization(options: [.alert, .sound])) ?? false
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.body = notificationBody.prefix(1).uppercased() + notificationBody.dropFirst()
            content.sound = shouldPlaySound ? .default : nil

            try? await notificationCenter.add(
                UNNotificationRequest(
                    identifier: "wisp.screen-watch.\(endedWatcher.id.uuidString)",
                    content: content,
                    trigger: nil
                )
            )
        }
    }
}
