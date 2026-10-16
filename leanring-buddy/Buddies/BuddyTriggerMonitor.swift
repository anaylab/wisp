//
//  BuddyTriggerMonitor.swift
//  leanring-buddy
//
//  Watches the Mac for the events buddies can be triggered by and hands each
//  one to `BuddyStore.fireTrigger`, which decides whether a run may start.
//  The deciding rules (cooldown, daily limit, what counts as a new file, which
//  calendar events are due) are pure and live in `BuddyTrigger.swift`.
//
//  - A new file in a folder: a 30-second poll of the folder's direct contents.
//    The first look at a folder only records what is already there, so adding a
//    trigger, or launching Wisp, never runs a buddy for old files. Files that
//    appear while Wisp is closed are not reported.
//  - An app opening: NSWorkspace's launch notification.
//  - A calendar event about to start: the same poll, reading EventKit only when
//    Calendar access was already granted (it never prompts).
//
//  Nothing is watched unless a buddy has a trigger for it.
//

import AppKit
import Foundation

@MainActor
final class BuddyTriggerMonitor {
    static let shared = BuddyTriggerMonitor()

    private static let pollIntervalSeconds: TimeInterval = 30
    /// How far ahead the calendar is read: the longest lead a trigger offers.
    private static let calendarLookAheadSeconds = Double(BuddyTrigger.calendarLeadMinuteChoices.max() ?? 30) * 60 + 60

    private var pollTimer: Timer?
    private var launchObserver: NSObjectProtocol?
    /// The file names each buddy has already been offered in each watched
    /// folder, keyed by `baselineKey`. Per buddy, so two buddies watching one
    /// folder each get their own run for a file.
    private var knownFileNamesByBaselineKey: [String: Set<String>] = [:]

    private init() {}

    /// Starts watching. Safe to call more than once.
    func start(buddyStore: BuddyStore = .shared) {
        guard pollTimer == nil else { return }

        let timer = Timer(timeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll(buddyStore: buddyStore, now: Date())
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let launchedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let launchedBundleIdentifier = launchedApplication?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let launchedBundleIdentifier else { return }
                self?.handleApplicationLaunch(bundleIdentifier: launchedBundleIdentifier, buddyStore: buddyStore)
            }
        }

        poll(buddyStore: buddyStore, now: Date())
    }

    // MARK: - Polling

    private func poll(buddyStore: BuddyStore, now: Date) {
        let watchedBaselineKeys = Set(buddyStore.buddies.flatMap { buddy in
            buddy.activeTriggers.compactMap { trigger -> String? in
                if case .newFileInFolder(let folderPath) = trigger { return Self.baselineKey(buddyID: buddy.id, folderPath: folderPath) }
                return nil
            }
        })
        // Forget folders no buddy watches any more, so re-adding one re-baselines it.
        knownFileNamesByBaselineKey = knownFileNamesByBaselineKey.filter { watchedBaselineKeys.contains($0.key) }

        for buddy in buddyStore.buddies {
            for trigger in buddy.activeTriggers {
                switch trigger {
                case .newFileInFolder(let folderPath):
                    pollFolder(folderPath, trigger: trigger, buddyID: buddy.id, buddyStore: buddyStore, now: now)
                case .calendarEventStarting(let minutesBefore):
                    // Calendar reads are async (the provider is an actor), so this
                    // runs beside the rest of the pass rather than inside it.
                    Task { @MainActor in
                        await self.pollCalendar(minutesBefore: minutesBefore, trigger: trigger, buddyID: buddy.id, buddyStore: buddyStore, now: now)
                    }
                case .appLaunched:
                    break
                }
            }
        }
    }

    private func pollFolder(_ folderPath: String, trigger: BuddyTrigger, buddyID: UUID, buddyStore: BuddyStore, now: Date) {
        guard let currentFiles = Self.directFiles(inFolderAtPath: folderPath) else { return }

        // First look: record what is there and stop.
        let baselineKey = Self.baselineKey(buddyID: buddyID, folderPath: folderPath)
        guard let knownFileNames = knownFileNamesByBaselineKey[baselineKey] else {
            knownFileNamesByBaselineKey[baselineKey] = Set(currentFiles.map(\.name))
            return
        }

        let newFileNames = BuddyTriggerPolicy.newlySettledFileNames(
            knownFileNames: knownFileNames, currentFiles: currentFiles, now: now
        )
        guard !newFileNames.isEmpty else { return }

        // The files are marked seen only when a run actually started; if the
        // buddy was busy, paused or in its cooldown they're offered again, so a
        // burst of downloads becomes one run once it may.
        if buddyStore.fireTrigger(trigger, forBuddyWithID: buddyID, detailNames: newFileNames, now: now) {
            knownFileNamesByBaselineKey[baselineKey] = knownFileNames.union(newFileNames)
        }
    }

    private func pollCalendar(minutesBefore: Int, trigger: BuddyTrigger, buddyID: UUID, buddyStore: BuddyStore, now: Date) async {
        guard let upcomingEvents = await CalendarDataProvider.shared.timedEventsStartingIfAuthorized(
            from: now.addingTimeInterval(-BuddyTriggerPolicy.calendarGraceAfterStartSeconds),
            to: now.addingTimeInterval(Self.calendarLookAheadSeconds)
        ) else { return }

        // Read after the await, so keys fired in the meantime are respected.
        guard let buddy = buddyStore.buddy(withID: buddyID) else { return }
        let dueEvents = BuddyTriggerPolicy.calendarEventsToFire(
            events: upcomingEvents.map { BuddyTriggerCalendarEvent(id: $0.id, title: $0.title, startDate: $0.startDate) },
            minutesBefore: minutesBefore,
            now: now,
            alreadyFiredKeys: Set(buddy.firedTriggerKeys ?? [])
        )
        // One run per pass; the next event is picked up after the cooldown.
        guard let nextDueEvent = dueEvents.first else { return }
        buddyStore.fireTrigger(
            trigger,
            forBuddyWithID: buddy.id,
            detailNames: [nextDueEvent.title],
            firedKeys: [BuddyTriggerPolicy.calendarFiredKey(for: nextDueEvent)],
            now: now
        )
    }

    private func handleApplicationLaunch(bundleIdentifier: String, buddyStore: BuddyStore) {
        for buddy in buddyStore.buddies {
            for trigger in buddy.activeTriggers {
                guard case .appLaunched(let triggerBundleIdentifier, let appName) = trigger,
                      triggerBundleIdentifier == bundleIdentifier else { continue }
                buddyStore.fireTrigger(trigger, forBuddyWithID: buddy.id, detailNames: [appName])
            }
        }
    }

    private static func baselineKey(buddyID: UUID, folderPath: String) -> String {
        "\(buddyID.uuidString)|\(folderPath)"
    }

    // MARK: - Folder reading

    /// The regular files directly inside a folder with their modification
    /// dates, or nil when it can't be read (missing, or access not granted).
    private static func directFiles(inFolderAtPath folderPath: String) -> [(name: String, modifiedAt: Date)]? {
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        return fileURLs.compactMap { fileURL in
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard resourceValues?.isRegularFile == true else { return nil }
            return (fileURL.lastPathComponent, resourceValues?.contentModificationDate ?? Date.distantPast)
        }
    }
}
