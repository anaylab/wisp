//
//  RoutineParameterPrompt.swift
//  leanring-buddy
//
//  Asks for a routine's blanks (`RoutineParameters`) just before it runs: a small
//  native dialog with one labelled field per blank, prefilled with the last
//  answer or the default. An alert rather than a panel in Wisp's own UI because
//  a routine is run from the notch, the Wisp window, a keyboard shortcut and the
//  morning banner, and the notch can't host a sheet. Return runs it, Escape
//  cancels and nothing is sent.
//

import AppKit

@MainActor
enum RoutineParameterPrompt {
    /// The values the user entered, keyed by `RoutineParameter.key`, or nil if cancelled.
    static func ask(
        routineName: String,
        parameters: [RoutineParameter],
        initialValues: [String: String]
    ) -> [String: String]? {
        let alert = NSAlert()
        alert.messageText = routineName
        alert.informativeText = "Fill in the blanks for this run."
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")

        let fieldWidth: CGFloat = 300
        let rowHeight: CGFloat = 26
        let labelHeight: CGFloat = 16
        let rowGap: CGFloat = 8
        let accessoryHeight = CGFloat(parameters.count) * (labelHeight + rowHeight + rowGap)
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: fieldWidth, height: accessoryHeight))

        var textFields: [(key: String, field: NSTextField)] = []
        for (parameterIndex, parameter) in parameters.enumerated() {
            // Laid out top to bottom; AppKit's origin is bottom-left.
            let rowTop = accessoryHeight - CGFloat(parameterIndex) * (labelHeight + rowHeight + rowGap)

            let label = NSTextField(labelWithString: parameter.name)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: 0, y: rowTop - labelHeight, width: fieldWidth, height: labelHeight)
            accessoryView.addSubview(label)

            let field = NSTextField(frame: NSRect(x: 0, y: rowTop - labelHeight - rowHeight, width: fieldWidth, height: rowHeight))
            field.stringValue = initialValues[parameter.key] ?? ""
            field.placeholderString = parameter.defaultValue ?? ""
            accessoryView.addSubview(field)
            textFields.append((parameter.key, field))
        }
        alert.accessoryView = accessoryView
        alert.window.initialFirstResponder = textFields.first?.field

        // The alert needs the app active to take typing; Wisp is an accessory app.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Dictionary(uniqueKeysWithValues: textFields.map { ($0.key, $0.field.stringValue) })
    }
}
