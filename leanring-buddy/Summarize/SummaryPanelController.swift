// Adapted from Sentient OS's summary window (AGPL-3.0).
//
// A floating dark panel that shows the summary as it streams, with Copy and Try again.
// Closing it dismisses the request and discards the text.

import AppKit
import SwiftUI

@MainActor final class SummaryPanelController: NSObject, NSWindowDelegate {
    private let summary: Summarize
    private var panel: NSPanel?

    init(summary: Summarize) {
        self.summary = summary
        super.init()
    }

    func show() {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panelSize = NSSize(width: 520, height: 460)
        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Summary"
        newPanel.titlebarAppearsTransparent = true
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.appearance = NSAppearance(named: .darkAqua)
        newPanel.backgroundColor = .black
        newPanel.delegate = self
        newPanel.contentView = NSHostingView(rootView: SummaryPanelView(summary: summary))

        // Open on the screen holding the pointer, since that is where the user is looking.
        let screenUnderPointer = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visibleFrame = screenUnderPointer?.visibleFrame {
            newPanel.setFrameOrigin(NSPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.midY - panelSize.height / 2
            ))
        }
        panel = newPanel
        newPanel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// The close button ends the request instead of only hiding the window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        summary.dismiss()
        return false
    }
}

private struct SummaryPanelView: View {
    let summary: Summarize
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !summary.sourceTitle.isEmpty {
                Text(summary.sourceTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if summary.phase == .reading {
                        Text("Reading…").foregroundStyle(.white.opacity(0.6))
                    }
                    if !summary.summaryText.isEmpty {
                        Text(summary.summaryText)
                            .textSelection(.enabled)
                            .lineSpacing(4)
                    }
                    if let errorMessage = summary.errorMessage {
                        Text(errorMessage).foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if summary.phase == .failed {
                    Button("Try again") { summary.retry() }.pointerCursor()
                }
                Spacer()
                if !summary.summaryText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(summary.summaryText, forType: .string)
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .pointerCursor()
                }
            }
        }
        .padding(.top, 36)
        .padding([.horizontal, .bottom], 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .ignoresSafeArea()
    }
}
