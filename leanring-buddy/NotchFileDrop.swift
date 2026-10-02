//
//  NotchFileDrop.swift
//  leanring-buddy
//
//  Dropping a file on the notch offers Ask about it / Add to brain / Email
//  (see NotchFileAttachment.swift). The notch window is
//  click-through while collapsed and its hosting view is SwiftUI, so this lives
//  at the AppKit level: a transparent sibling drop view above the notch content, plus a
//  detector that tells the controller when a file drag — as opposed to a window
//  drag or a text selection — is in flight so it can open the island under it.
//

import AppKit
import SwiftUI

/// A transparent view that accepts dragged files, layered above the notch's
/// hosting view as its sibling. It returns nil from `hitTest` so every click
/// still reaches the SwiftUI controls beneath it, while AppKit still delivers
/// drags to it. (Registering the hosting view itself, wrapping it, or using
/// SwiftUI's `.onDrop` all failed to receive drags on this panel; the panel
/// also has to be at a lower level and able to become key — see
/// `NotchWindowController.enterFileDragPanelMode`.)
final class NotchFileDropView: NSView {
    /// Whether the drop would be accepted right now. Checked at
    /// drag-enter so a refused drag shows the "not allowed" cursor.
    var canAcceptFiles: () -> Bool = { true }
    /// Called with the dropped file URLs; returns whether they were taken.
    var onFilesDropped: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFiles() ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptFiles() ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let droppedFileURLs = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !droppedFileURLs.isEmpty else { return false }
        return onFilesDropped?(droppedFileURLs) ?? false
    }
}

/// Detects a file drag in progress from the global state, since the window is
/// click-through until it is told otherwise and gets no drag events of its own.
///
/// The drag pasteboard keeps its contents after a drag ends, so "the pasteboard
/// holds files and the mouse is down" would misfire on a window drag that
/// follows a file drag. Instead the pasteboard's change count is baselined while
/// the button is up; a drag is a file drag only if the count moves while the
/// button is held and the pasteboard then holds files.
struct NotchFileDragDetector {
    private var baselineChangeCount: Int = NSPasteboard(name: .drag).changeCount

    /// Call on every poll tick. Returns true while a file drag is in flight.
    mutating func isFileDragInProgress() -> Bool {
        let dragPasteboard = NSPasteboard(name: .drag)
        let isPrimaryButtonHeld = NSEvent.pressedMouseButtons & 1 != 0
        guard isPrimaryButtonHeld else {
            baselineChangeCount = dragPasteboard.changeCount
            return false
        }
        guard dragPasteboard.changeCount != baselineChangeCount else { return false }
        return dragPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
    }
}
