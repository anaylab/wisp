//
//  CompanionManager+WorkedSolutionExport.swift
//  leanring-buddy
//
//  "Save Worked Solution": the thin glue around the pure rules in
//  WorkedSolutionExport.swift. Captures a fresh native-resolution picture of
//  the display the explanation is drawn on (Wisp's own windows left out),
//  draws every annotation over it with the same `ScreenAnnotationLayer` the
//  overlay uses, asks where to save, and writes a PNG plus a small Markdown
//  file of the notes beside it. Local only: nothing is sent anywhere and the
//  clipboard is never touched.
//
//  Screen capture, ImageRenderer and NSSavePanel can't run headless, so this
//  file has no test suite; everything decidable is in WorkedSolutionExport.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension CompanionManager {
    /// True while the drawings hold a note or a circle — what the menu item
    /// enables on.
    var canSaveWorkedSolution: Bool {
        WorkedSolutionExport.hasSomethingToSave(annotationsByDisplayFrame: activeAnnotationsByDisplayFrame)
    }

    /// The menu item and ⌃⌥S both land here.
    func saveWorkedSolution() {
        guard workedSolutionSaveTask == nil else { return }

        // Snapshot the drawings now: they can time out or be cleared while the
        // capture and the save panel are up.
        guard let displayFrame = WorkedSolutionExport.displayFrameToSave(
                annotationsByDisplayFrame: activeAnnotationsByDisplayFrame
              ),
              let annotations = activeAnnotationsByDisplayFrame[displayFrame],
              let screenshotSize = annotationScreenshotSizeByDisplayFrame[displayFrame] else {
            presentWorkedSolutionSaveOutcome("there's no worked solution on screen to save.", didSucceed: false)
            return
        }
        let questionAsked = lastQuestionAskedByUser
        let savedAtDate = Date()

        workedSolutionSaveTask = Task { [weak self] in
            guard let self else { return }
            defer { self.workedSolutionSaveTask = nil }

            guard let screenImage = await CompanionScreenCaptureUtility.captureDisplayAtNativeResolution(
                displayFrameInAppKitCoordinates: displayFrame
            ), let pngData = self.renderWorkedSolutionPNG(
                screenImage: screenImage,
                annotations: annotations,
                screenshotSize: screenshotSize,
                displaySizeInPoints: displayFrame.size
            ) else {
                self.presentWorkedSolutionSaveOutcome("i couldn't capture the screen to save that.", didSucceed: false)
                return
            }

            guard let chosenImageURL = await self.askWhereToSaveWorkedSolution(savedAtDate: savedAtDate) else {
                return
            }

            let markdownText = WorkedSolutionExport.markdown(
                noteTexts: WorkedSolutionExport.noteTexts(in: annotations),
                question: questionAsked,
                date: savedAtDate,
                imageFileName: chosenImageURL.lastPathComponent
            )
            let markdownURL = chosenImageURL
                .deletingLastPathComponent()
                .appendingPathComponent(WorkedSolutionExport.markdownFileName(forImageFileName: chosenImageURL.lastPathComponent))

            do {
                try pngData.write(to: chosenImageURL, options: .atomic)
                try markdownText.write(to: markdownURL, atomically: true, encoding: .utf8)
                self.presentWorkedSolutionSaveOutcome(
                    "saved your worked solution to \(chosenImageURL.deletingLastPathComponent().lastPathComponent).",
                    didSucceed: true
                )
            } catch {
                self.presentWorkedSolutionSaveOutcome(
                    "i couldn't save that: \(error.localizedDescription)",
                    didSucceed: false
                )
            }
        }
    }

    // MARK: - Rendering

    /// The screenshot with every annotation drawn over it at full strength,
    /// as PNG data. Reuses `ScreenAnnotationLayer` (in export mode: all notes,
    /// no Next pill, no pulse) so the picture matches what was on screen.
    private func renderWorkedSolutionPNG(
        screenImage: CGImage,
        annotations: [ScreenAnnotation],
        screenshotSize: CGSize,
        displaySizeInPoints: CGSize
    ) -> Data? {
        let compositeView = ZStack(alignment: .topLeading) {
            Image(decorative: screenImage, scale: 1)
                .resizable()
                .frame(width: displaySizeInPoints.width, height: displaySizeInPoints.height)
            ScreenAnnotationLayer(
                annotations: annotations,
                screenshotSize: screenshotSize,
                displaySize: displaySizeInPoints,
                isForExport: true
            )
        }
        .frame(width: displaySizeInPoints.width, height: displaySizeInPoints.height)

        let renderer = ImageRenderer(content: compositeView)
        // One rendered pixel per captured pixel, so the screenshot stays sharp.
        renderer.scale = CGFloat(screenImage.width) / displaySizeInPoints.width
        guard let renderedImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: renderedImage).representation(using: .png, properties: [:])
    }

    // MARK: - Save panel

    /// Shows the save panel in ~/Pictures/Wisp Solutions (created now if it
    /// doesn't exist) and returns the chosen PNG location, or nil if cancelled.
    private func askWhereToSaveWorkedSolution(savedAtDate: Date) async -> URL? {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.title = "Save Worked Solution"
        savePanel.nameFieldStringValue = WorkedSolutionExport.defaultImageFileName(date: savedAtDate)
        if let defaultFolderURL = workedSolutionsFolderURLCreatingIfNeeded() {
            savePanel.directoryURL = defaultFolderURL
        }

        // Wisp is a menu bar app with no active window; the panel needs the app
        // active to come to the front and take typing.
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in
            savePanel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? savePanel.url : nil
    }

    private func workedSolutionsFolderURLCreatingIfNeeded() -> URL? {
        guard let picturesFolderURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folderURL = picturesFolderURL.appendingPathComponent(WorkedSolutionExport.defaultFolderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            return folderURL
        } catch {
            return nil
        }
    }

    // MARK: - Confirmation

    /// The brief confirmation, through the same notch reply and island flash
    /// the other direct commands use.
    private func presentWorkedSolutionSaveOutcome(_ replyText: String, didSucceed: Bool) {
        currentReplyText = replyText
        flashIsland(didSucceed ? .success : .error)
    }
}
