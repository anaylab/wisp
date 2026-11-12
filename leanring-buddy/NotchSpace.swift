//
//  NotchSpace.swift
//  leanring-buddy
//
//  Adapted from Sentient OS's NotchSpace (AGPL-3.0), itself distilled from DynamicNotch.
//
//  Pins the notch overlay into a window-server "space" at the top absolute level, via the
//  SkyLight private API, so it stays fixed over the notch on every Space and does not slide
//  during the 3-finger Spaces swipe. No public API does this: `.stationary` only covers Expose.
//
//  Fragile by nature (private symbols), so it fails gracefully: if any symbol is missing,
//  `shared` is nil and the window keeps its public `collectionBehavior` (.canJoinAllSpaces).
//

import AppKit
import Darwin

@MainActor
final class NotchSpace {
    /// nil when SkyLight is unavailable — callers then rely on the public collectionBehavior alone.
    static let shared = NotchSpace()

    /// Off by default: this leans on private SkyLight symbols that macOS may change, and the
    /// effect (the notch staying put during the 3-finger Spaces swipe) can't be checked by a
    /// build. Turn it on with `defaults write com.gluepixel.wisp wisp.notch.pinToFixedSpace -bool true`.
    static let isEnabledKey = "wisp.notch.pinToFixedSpace"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: isEnabledKey) }

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindowsAndRemoveFromSpaces

    private init?() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW),
              let connSym   = dlsym(handle, "SLSMainConnectionID"),
              let createSym = dlsym(handle, "SLSSpaceCreate"),
              let levelSym  = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let showSym   = dlsym(handle, "SLSShowSpaces"),
              let addSym    = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return nil }

        let mainConnectionID = unsafeBitCast(connSym, to: MainConnectionID.self)
        let spaceCreate      = unsafeBitCast(createSym, to: SpaceCreate.self)
        let setAbsoluteLevel = unsafeBitCast(levelSym, to: SpaceSetAbsoluteLevel.self)
        let showSpaces       = unsafeBitCast(showSym, to: ShowSpaces.self)
        self.addWindows      = unsafeBitCast(addSym, to: AddWindowsAndRemoveFromSpaces.self)

        let conn = mainConnectionID()
        let space = spaceCreate(conn, 1, 0)
        guard space != 0 else { return nil }
        _ = setAbsoluteLevel(conn, space, .max)        // top absolute level — above the Spaces swipe
        _ = showSpaces(conn, [space] as CFArray)       // keep it shown everywhere
        self.connection = conn
        self.space = space
    }

    /// Move the window into the fixed notch space (and out of the normal Spaces). The window must be on
    /// screen (valid windowNumber), so call this AFTER orderFront.
    func pin(_ window: NSWindow) {
        guard Self.isEnabled, window.windowNumber > 0 else { return }
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }
}
