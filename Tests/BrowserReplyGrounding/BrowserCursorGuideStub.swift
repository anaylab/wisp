//
//  BrowserTask.swift takes an optional BrowserCursorGuide, which is declared in
//  BrowserStepLoop.swift (that file needs far more of the app than this suite
//  compiles). This declares the same members so the runner builds here.
//

import CoreGraphics

@MainActor
protocol BrowserCursorGuide: AnyObject {
    func guideCursor(to point: CGPoint, on displayFrame: CGRect, actionText: String) async
    func endCursorGuidance()
    func reportBrowserProgress(_ progressText: String)
}
