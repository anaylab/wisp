// Adapted from Sentient OS's ProofreadResultPanel (AGPL-3.0).
//
// A small, ephemeral window for the cases where Wisp can't safely paste the correction itself:
// it explains why and offers the corrected text to copy. Closing it discards the text.

import AppKit
import SwiftUI

@MainActor final class ProofreadResultPanel {
    private var panel: NSPanel?

    func show(text: String?, explanation: String) {
        close()

        let panelSize = NSSize(width: 520, height: text == nil ? 200 : 420)
        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Proofread"
        newPanel.titlebarAppearsTransparent = true
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.appearance = NSAppearance(named: .darkAqua)
        newPanel.backgroundColor = .black

        let hostingView = NSHostingView(rootView: ProofreadResultView(
            correctedText: text,
            explanation: explanation,
            close: { [weak self] in self?.close() }
        ))
        newPanel.contentView = hostingView

        // Center on whichever screen holds the pointer, since that is where the user is looking.
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

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }
}

private struct ProofreadResultView: View {
    let correctedText: String?
    let explanation: String
    let close: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(explanation)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            if let correctedText {
                ScrollView {
                    Text(correctedText)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(correctedText, forType: .string)
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .pointerCursor()
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 36)
        .padding([.horizontal, .bottom], 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .ignoresSafeArea()
    }
}
