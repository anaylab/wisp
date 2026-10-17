//
//  MenuBarMenuController.swift
//  leanring-buddy
//
//  The menu bar icon and its menu. Wisp is notch-first, so the menu bar item is
//  a plain native menu — status, a way to ask, pausing, the handful of switches people
//  flip often, and the way into the Wisp window — rather than the large custom
//  panel it used to open, which duplicated the dashboard's settings.
//
//  The menu is rebuilt each time it opens (`menuNeedsUpdate`), so the status
//  line and checkmarks are always current without observing anything.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarMenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let companionManager: CompanionManager
    private let statusMenu = NSMenu()
    private var listeningPausedCancellable: AnyCancellable?

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()
        // A paused Wisp dims its menu bar icon, the standard macOS cue for a
        // status item that's switched off, so the pause is visible at a glance.
        listeningPausedCancellable = companionManager.$isListeningPaused
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isListeningPaused in
                self?.statusItem?.button?.appearsDisabled = isListeningPaused
            }
    }

    // MARK: - Status item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = makeWispMenuBarIcon()
        button.image?.isTemplate = true
        button.setAccessibilityLabel("Wisp")

        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        statusItem?.menu = statusMenu
    }

    /// Draws the Wisp ribbon mark as a menu bar icon. Uses the same path as
    /// `WispRibbonShape` so the menu bar, notch and app icon all share one logo.
    /// It is a template image, so macOS tints it for light and dark menu bars.
    private func makeWispMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: true) { drawingRect in
            let ribbonPath = WispRibbonShape().path(in: drawingRect)
            let strokedRibbonPath = ribbonPath.strokedPath(
                StrokeStyle(lineWidth: iconSize * 0.16, lineCap: .round, lineJoin: .round)
            )
            guard let graphicsContext = NSGraphicsContext.current?.cgContext else { return false }
            graphicsContext.addPath(strokedRibbonPath.cgPath)
            graphicsContext.setFillColor(NSColor.black.cgColor)
            graphicsContext.fillPath()
            return true
        }
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabledItem(title: statusTitle))
        menu.addItem(disabledItem(
            title: companionManager.isListeningPaused
                ? "The talk shortcut is ignored until you resume"
                : "Hold \(ShortcutBindingStore.shared.primaryHoldChord.displayText) to talk"
        ))
        menu.addItem(.separator())

        if !companionManager.allPermissionsGranted {
            let setupItem = actionItem(title: "Finish Setup…", action: #selector(openSetup))
            setupItem.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            menu.addItem(setupItem)
            menu.addItem(.separator())
        }

        menu.addItem(actionItem(title: "Ask Wisp…", action: #selector(askWisp)))
        menu.addItem(actionItem(title: "Ask About a Part…", action: #selector(askAboutPart)))
        menu.addItem(actionItem(title: "Open Wisp", action: #selector(openToday), keyEquivalent: "o"))
        menu.addItem(actionItem(title: "Chat", action: #selector(openChat)))
        menu.addItem(actionItem(title: "Buddies", action: #selector(openBuddies)))
        menu.addItem(actionItem(title: "Brain", action: #selector(openBrain)))
        menu.addItem(actionItem(title: "Add to Brain…", action: #selector(addToBrain)))
        menu.addItem(.separator())

        let pauseListeningItem = actionItem(title: "Pause Listening", action: #selector(togglePauseListening))
        pauseListeningItem.state = companionManager.isListeningPaused ? .on : .off
        menu.addItem(pauseListeningItem)

        let speakRepliesItem = actionItem(title: "Speak Replies", action: #selector(toggleSpeakReplies))
        speakRepliesItem.state = VoiceOutputPreference.shared.isReplySpeechEnabled ? .on : .off
        menu.addItem(speakRepliesItem)

        let soundCuesItem = actionItem(title: "Sound Cues", action: #selector(toggleSoundCues))
        soundCuesItem.state = WispSoundPreference.shared.areSoundCuesEnabled ? .on : .off
        menu.addItem(soundCuesItem)
        menu.addItem(.separator())

        menu.addItem(actionItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(actionItem(title: "Quit Wisp", action: #selector(quitWisp), keyEquivalent: "q"))
    }

    /// "Wisp — Ready", "Wisp — Listening…", "Wisp — Paused", "Wisp — Needs setup".
    private var statusTitle: String {
        if !companionManager.allPermissionsGranted {
            return "Wisp — Needs setup"
        }
        if companionManager.isListeningPaused {
            return "Wisp — Paused"
        }
        let islandState = companionManager.islandState
        return islandState.isActive ? "Wisp — \(islandState.label)" : "Wisp — Ready"
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func actionItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.target = self
        menuItem.isEnabled = true
        return menuItem
    }

    // MARK: - Actions

    @objc private func askWisp() {
        companionManager.openAskComposer()
    }

    @objc private func askAboutPart() {
        companionManager.beginAskAboutRegion()
    }

    @objc private func openSetup() {
        WispWindowNavigator.open(.home)
    }

    @objc private func openToday() {
        WispWindowNavigator.open(.home)
    }

    @objc private func openChat() {
        WispWindowNavigator.open(.chat)
    }

    @objc private func openBuddies() {
        WispWindowNavigator.open(.buddies)
    }

    @objc private func openBrain() {
        WispWindowNavigator.open(.brainPages)
    }

    /// The Inbox page is where files, links and text are dropped or picked.
    @objc private func addToBrain() {
        WispWindowNavigator.open(.brainInbox)
    }

    @objc private func openSettings() {
        WispWindowNavigator.open(.general)
    }

    @objc private func togglePauseListening() {
        companionManager.setListeningPaused(!companionManager.isListeningPaused)
    }

    @objc private func toggleSpeakReplies() {
        VoiceOutputPreference.shared.isReplySpeechEnabled.toggle()
    }

    @objc private func toggleSoundCues() {
        WispSoundPreference.shared.areSoundCuesEnabled.toggle()
    }

    @objc private func quitWisp() {
        NSApp.terminate(nil)
    }
}
