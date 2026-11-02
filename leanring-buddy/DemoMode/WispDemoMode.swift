//
//  WispDemoMode.swift
//  leanring-buddy
//
//  Demo mode, for screenshots and showing Wisp to someone: the same app, run on
//  a separate set of data filled with sample buddies, chats, automations, a
//  checklist and calendar events, so nothing personal is on screen.
//
//  It is a launch option, not a switch inside the app, because every store
//  reads its file once at launch: `scripts/demo.sh` quits Wisp and opens it with
//  `-WispDemoMode YES` (UserDefaults' argument domain, so it is never saved).
//  Opening Wisp normally is the way back.
//
//  While it is on:
//  - Every store that keeps the user's data reads and writes under
//    `~/Library/Application Support/Wisp Demo/home/` instead of the real home
//    (`dataHome`), so the real buddies, chats, brain and history are never read
//    or changed. Settings that aren't personal (MCP servers, skills, keys) stay
//    the real ones, so a model still answers.
//  - Nothing runs on its own: buddy schedules, automations, Canvas sync and the
//    morning banner are off, and the calendar shows sample events instead of
//    the user's.
//

import Foundation

nonisolated enum WispDemoMode {
    static let launchArgumentKey = "WispDemoMode"

    /// Read once: a demo session stays a demo session until Wisp quits.
    static let isOn: Bool = UserDefaults.standard.bool(forKey: launchArgumentKey)

    /// The stand-in home folder the demo's data lives under.
    static let demoHomeURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wisp Demo/home", isDirectory: true)

    /// Where the user's data lives: the real home, or the demo's stand-in.
    static var dataHome: URL {
        isOn ? demoHomeURL : FileManager.default.homeDirectoryForCurrentUser
    }

    /// `dataHome`'s Application Support folder.
    static var applicationSupportDirectory: URL {
        dataHome.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Flags the demo keeps for itself (such as which starter buddies it made),
    /// so the real ones stay as they are.
    static let demoUserDefaultsSuiteName = "com.gluepixel.wisp.demo"
}
