//
//  ChromeAskAboutThisRouter.swift
//  leanring-buddy
//
//  Turns phase 06's `user.*` events from the Wisp Tabs extension into what
//  the user asked for:
//
//  - **Selection / image / link / page** (right-click → Ask Wisp…, or ⌘⇧Y for
//    the page): the text composer opens with an "About: …" chip, and the part
//    rides every question until a fresh composer opens — Ask About a Part, for
//    a piece of a page. The selection is read now (it is the one thing that
//    can change under the user); an image is downloaded and a link's words are
//    looked up when the question is sent
//    (`CompanionManager+ChromeAskAboutThis.swift`).
//  - **Omnibox** ("w how do I …"): runs at once as a typed question, with the
//    tab as context. The answer shows in the notch; Chrome keeps the focus.
//  - **Add to Wisp brain**: the selection's text, the page's text, or the
//    link's address goes to `BrainIngestQueue`, and the notch says so.
//
//  Nothing here closes a window or takes focus from Chrome except the
//  composer, which has to be key to be typed into.
//

import AppKit
import Combine
import Foundation

@MainActor
final class ChromeAskAboutThisRouter: ObservableObject {
    static let shared = ChromeAskAboutThisRouter()

    /// The part of a Chrome page the next questions are about, or nil.
    @Published private(set) var focusedPagePart: ChromeAskAboutThisPart?

    private weak var companionManager: CompanionManager?
    private var eventSubscription: AnyCancellable?
    private var focusedScreenRegionSubscription: AnyCancellable?

    /// The last downloaded image, so a follow-up about the same image doesn't
    /// download it again.
    private var downloadedImageCache: (imageURL: String, imageData: Data)?

    /// Reads made while the user waits for the composer stay short.
    private static let eventTimeReadTimeoutSeconds: Double = 3

    // MARK: - Lifecycle

    /// Starts listening. Safe to call more than once.
    func start(companionManager: CompanionManager) {
        self.companionManager = companionManager
        guard eventSubscription == nil else { return }
        eventSubscription = ChromeExtensionBridge.shared.extensionEventPublisher
            .filter { ChromeAskAboutThisEventName.all.contains($0.eventName) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] extensionEvent in
                MainActor.assumeIsolated {
                    self?.handle(extensionEvent)
                }
            }
        // Choosing a part of the screen (Ask About a Part, clicking a note)
        // makes that the subject instead.
        focusedScreenRegionSubscription = companionManager.$focusedScreenRegion
            .sink { [weak self] focusedScreenRegion in
                guard focusedScreenRegion != nil else { return }
                MainActor.assumeIsolated {
                    self?.clearFocusedPagePart()
                }
            }
    }

    /// Forgets the page part: a fresh question, a spoken one, or the chip's ✕.
    func clearFocusedPagePart() {
        guard focusedPagePart != nil else { return }
        focusedPagePart = nil
    }

    /// The turn path replaces a part once it learned more about it (a link's
    /// words), so follow-ups don't look again.
    func updateFocusedPagePart(_ updatedPart: ChromeAskAboutThisPart) {
        guard focusedPagePart?.tabID == updatedPart.tabID else { return }
        focusedPagePart = updatedPart
    }

    // MARK: - Events

    private func handle(_ extensionEvent: ChromeExtensionEvent) {
        guard let payload = extensionEvent.decodePayload(as: ChromeAskAboutThisEventPayload.self),
              let request = ChromeAskAboutThisRequestDecoder.request(eventName: extensionEvent.eventName, payload: payload) else {
            print("🙋 Ask Wisp about this: ignored a \(extensionEvent.eventName) event it couldn't use")
            return
        }
        print("🙋 Ask Wisp about this: \(extensionEvent.eventName) (\(payload.source ?? "?"), \(payload.intent ?? "ask"))")

        switch request {
        case .askAboutSelection(let tab, let menuSelectionText):
            Task { await openComposerAboutSelection(in: tab, menuSelectionText: menuSelectionText) }
        case .askAboutImage(let tab, let imageURL, let imageURLWasCutOff):
            openComposer(about: .image(tab, imageURL: imageURL, imageURLWasCutOff: imageURLWasCutOff))
        case .askAboutLink(let tab, let linkURL, let menuSelectionText):
            openComposer(about: .link(tab, linkURL: linkURL, linkText: menuSelectionText))
        case .askAboutPage(let tab):
            openComposer(about: .page(tab, isFromAddressBar: false))
        case .omniboxQuestion(let question, let tab):
            askFromAddressBar(question, tab: tab)
        case .addSelectionToBrain(let tab, let menuSelectionText):
            Task { await addSelectionToBrain(in: tab, menuSelectionText: menuSelectionText) }
        case .addLinkToBrain(let linkURL, _):
            guard isBrainOnOrSaySo() else { return }
            BrainIngestQueue.shared.enqueue(webPageURL: linkURL)
            reportBrainResult(queuedTitle: linkURL.host ?? linkURL.absoluteString)
        case .addPageToBrain(let tab):
            Task { await addPageToBrain(tab) }
        }
    }

    // MARK: - Asking

    private func openComposer(about pagePart: ChromeAskAboutThisPart) {
        guard let companionManager else { return }
        // A fresh question about this part, not the screen region chosen
        // before (clearing that also clears any earlier page part).
        companionManager.clearFocusedScreenRegion()
        focusedPagePart = pagePart
        companionManager.openTextComposer(keepingFocusedScreenRegion: true)
    }

    private func openComposerAboutSelection(in tab: ChromeAskTabReference, menuSelectionText: String) async {
        let pageReadSelection = await readSelectionIfAllowed(in: tab)
        guard let chosenSelection = ChromeAskAboutThisContext.chosenSelection(
            pageReadSelection: pageReadSelection,
            menuSelectionText: menuSelectionText,
            tab: tab
        ) else {
            companionManager?.presentChromeAskAboutThisReply(ChromeAskAboutThisContext.unreadableSelectionReply, didSucceed: false)
            return
        }
        openComposer(about: .selection(chosenSelection))
    }

    private func askFromAddressBar(_ question: String, tab: ChromeAskTabReference?) {
        guard let companionManager else { return }
        companionManager.clearFocusedScreenRegion()
        focusedPagePart = tab.map { .page($0, isFromAddressBar: true) }
        companionManager.submitTextComposerQuery(question)
    }

    private func readSelectionIfAllowed(in tab: ChromeAskTabReference) async -> ChromePageSelection? {
        guard ChromePageReader.canReadPages else { return nil }
        do {
            return try await ChromePageReader.readSelection(tabID: tab.tabID, timeoutSeconds: Self.eventTimeReadTimeoutSeconds)
        } catch {
            print("🙋 Ask Wisp about this: couldn't read the selection, using Chrome's menu text — \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - What a turn needs (called from the turn path)

    /// The image as a JPEG for the model, downloaded once per address.
    /// Nil when the address is refused or the download fails; the turn then
    /// sends the screenshot instead.
    func downloadedImageForModel(imageURL: String, imageURLWasCutOff: Bool, longestEdgePixels: CGFloat) async -> Data? {
        if let downloadedImageCache, downloadedImageCache.imageURL == imageURL {
            return Self.jpegForModel(downloadedImageCache.imageData, longestEdgePixels: longestEdgePixels)
        }
        let validatedURL: URL
        switch ChromeAskImageDownloadRules.validatedImageURL(imageURL, wasCutOff: imageURLWasCutOff) {
        case .success(let url): validatedURL = url
        case .failure(let refusal):
            print("🙋 Ask Wisp about this: not downloading the image — \(refusal.localizedDescription)")
            return nil
        }
        do {
            let imageData = try await ChromeAskImageDownloader.download(validatedURL)
            downloadedImageCache = (imageURL: imageURL, imageData: imageData)
            return Self.jpegForModel(imageData, longestEdgePixels: longestEdgePixels)
        } catch {
            print("🙋 Ask Wisp about this: image download failed — \(error.localizedDescription)")
            return nil
        }
    }

    /// The link's words from a snapshot of its page, or "" when the page
    /// can't be read or the link isn't listed.
    func linkTextFromPage(linkURL: String, tabID: Int) async -> String {
        guard ChromePageReader.canReadPages else { return "" }
        struct SnapshotParameters: Encodable {
            let tabId: Int
            let elementLimit: Int
            let maximumTextCharacters: Int
        }
        do {
            let reply = try await ChromeExtensionBridge.shared.sendRequest(
                method: "snapshotPage",
                parameters: SnapshotParameters(tabId: tabID, elementLimit: 500, maximumTextCharacters: 200),
                resultType: JSONValue.self,
                timeoutSeconds: Self.eventTimeReadTimeoutSeconds
            )
            guard let replyData = try? JSONEncoder().encode(reply),
                  let pageSnapshot = BrowserPageSnapshotDecoding.snapshot(fromJSONData: replyData) else { return "" }
            return ChromeAskAboutThisContext.linkText(
                forLinkURL: linkURL,
                among: pageSnapshot.elements.map { (href: $0.href, label: $0.label) }
            )
        } catch {
            print("🙋 Ask Wisp about this: couldn't look up the link's text — \(error.localizedDescription)")
            return ""
        }
    }

    /// Any image type NSImage can draw (PNG, WebP, GIF, SVG, HEIC…) becomes a
    /// downscaled JPEG, which every provider accepts.
    private static func jpegForModel(_ imageData: Data, longestEdgePixels: CGFloat) -> Data? {
        guard let image = NSImage(data: imageData), let firstRepresentation = image.representations.first else { return nil }
        let originalWidth = CGFloat(firstRepresentation.pixelsWide > 0 ? firstRepresentation.pixelsWide : Int(image.size.width))
        let originalHeight = CGFloat(firstRepresentation.pixelsHigh > 0 ? firstRepresentation.pixelsHigh : Int(image.size.height))
        let longestEdge = max(originalWidth, originalHeight)
        guard longestEdge > 0 else { return nil }
        let scale = min(1, longestEdgePixels / longestEdge)
        let targetSize = NSSize(width: max(1, (originalWidth * scale).rounded()), height: max(1, (originalHeight * scale).rounded()))

        let resizedImage = NSImage(size: targetSize)
        resizedImage.lockFocus()
        // A transparent PNG would turn black in a JPEG; white is what a page shows behind it.
        NSColor.white.setFill()
        NSRect(origin: .zero, size: targetSize).fill()
        image.draw(in: NSRect(origin: .zero, size: targetSize), from: .zero, operation: .sourceOver, fraction: 1)
        resizedImage.unlockFocus()
        guard let tiffData = resizedImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    // MARK: - Add to Wisp brain

    private func addSelectionToBrain(in tab: ChromeAskTabReference, menuSelectionText: String) async {
        guard isBrainOnOrSaySo() else { return }
        let pageReadSelection = await readSelectionIfAllowed(in: tab)
        guard let chosenSelection = ChromeAskAboutThisContext.chosenSelection(
            pageReadSelection: pageReadSelection,
            menuSelectionText: menuSelectionText,
            tab: tab
        ) else {
            companionManager?.presentChromeAskAboutThisReply(ChromeAskAboutThisContext.unreadableSelectionReply, didSucceed: false)
            return
        }
        let pageTitle = chosenSelection.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectionTitle = pageTitle.isEmpty ? "Selection from Chrome" : "Selection from \(pageTitle)"
        // Not tied to the page's address: that would merge it with the page
        // itself if both were queued at once.
        BrainIngestQueue.shared.enqueue(text: chosenSelection.selectedText, title: selectionTitle)
        reportBrainResult(queuedTitle: selectionTitle)
    }

    private func addPageToBrain(_ tab: ChromeAskTabReference) async {
        guard isBrainOnOrSaySo() else { return }
        let pageURL = ChromeAskAboutThisRequestDecoder.webAddress(tab.pageURL)
        if ChromePageReader.canReadPages {
            do {
                let pageText = try await ChromePageReader.readPage(tabID: tab.tabID)
                if pageText.wordCount >= ChromePageTextPrompt.minimumWordsToReplaceScreenshot {
                    let truncationNote = pageText.truncated ? "\n\n(the page was longer; only its first part was read.)" : ""
                    let pageTitle = pageText.title.isEmpty ? (pageURL?.host ?? "Chrome page") : pageText.title
                    BrainIngestQueue.shared.enqueue(
                        text: pageText.text + truncationNote,
                        title: pageTitle,
                        sourceWebPageURL: pageURL
                    )
                    reportBrainResult(queuedTitle: pageTitle)
                    return
                }
            } catch {
                print("🙋 Ask Wisp about this: couldn't read the page for the brain, fetching its address — \(error.localizedDescription)")
            }
        }
        // Without page reading (or a near-empty page), fetch the address, as
        // "add this page to my brain" does.
        guard let pageURL else {
            companionManager?.presentChromeAskAboutThisReply("i can only add web pages to the brain, not this kind of tab.", didSucceed: false)
            return
        }
        BrainIngestQueue.shared.enqueue(webPageURL: pageURL)
        reportBrainResult(queuedTitle: pageURL.host ?? pageURL.absoluteString)
    }

    private func isBrainOnOrSaySo() -> Bool {
        guard BrainPreferences.shared.isBrainEnabled else {
            companionManager?.presentChromeAskAboutThisReply("the brain is off. turn it on in wisp → brain → settings first.", didSucceed: false)
            return false
        }
        return true
    }

    private func reportBrainResult(queuedTitle: String) {
        companionManager?.presentChromeAskAboutThisReply(BrainCommandRouter.queuedReply(forTitles: [queuedTitle]), didSucceed: true)
    }
}
