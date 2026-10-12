//
//  StructuredTextToolProtocol.swift
//  leanring-buddy
//
//  Tool calling expressed as structured text rather than native function
//  calls.
//
//  Ollama does expose a `tools` field, but it is unusable with the model
//  this app runs on. Measured directly: qwen2.5vl:7b rejects tool requests
//  outright (HTTP 400, no tool capability), and the only locally available
//  vision model that advertises tools — qwen3-vl:8b — returned an empty
//  tool_calls array in every configuration tried, while spending 25 to 90
//  seconds reasoning first. Neither is viable for a voice assistant.
//
//  What the resident model does do reliably is emit a fixed text tag. The
//  existing [POINT:x,y:label] mechanism scored five hits out of five with a
//  six pixel median error, in about a second per call, using the app's own
//  full system prompt. So tools here reuse that proven shape: the model is
//  taught a tag syntax in the prompt, and the app parses the tag back into a
//  call. It costs one model round trip, needs no second model, and adds no
//  memory pressure on a machine that has none to spare.
//
//  The tag deliberately mirrors [POINT:...]:
//
//      [TOOL:tool_name:{"arg":"value"}]
//
//  JSON is used for the arguments because tools take structured input, but
//  the surrounding tag is what makes the call easy to find and easy for a
//  small model to produce consistently.
//

import Foundation

enum StructuredTextToolProtocol {
    /// Result of scanning a model reply for tool calls.
    struct ParseResult {
        /// The reply with every tool tag removed — what gets spoken aloud.
        let spokenText: String
        /// Calls found, in the order the model wrote them.
        let toolCalls: [ParsedToolCall]
        /// Tags that looked like tool calls but could not be read. Surfaced
        /// rather than dropped so a malformed call can be reported back to
        /// the model instead of silently doing nothing.
        let malformedTags: [String]
        /// The reply as ordered blocks: each run of prose and each call, in
        /// the position the model wrote it.
        ///
        /// This is the lossless view. `spokenText` and `toolCalls` are the two
        /// halves of the same reply pulled apart, and once apart there is no
        /// way back — "checking. [TOOL:x] here it is." and "checking. here it
        /// is. [TOOL:x]" flatten to the same pair. A model told what it said
        /// last turn should be told what it actually said.
        let contentBlocks: [BuddyContentBlock]
    }

    struct ParsedToolCall {
        /// Synthesized locally — the text protocol has no call ids of its own,
        /// but results still need to be matched back to their call.
        let id: String
        let name: String
        let input: JSONValue
    }

    /// Instructions appended to the system prompt describing the available
    /// tools and the exact tag to use.
    ///
    /// Kept terse on purpose. Every token here shares a context window with
    /// a screenshot, and long tool preambles are also where small models
    /// start improvising syntax.
    static func promptInstructions(for tools: [BuddyToolDefinition]) -> String {
        guard !tools.isEmpty else { return "" }

        var lines = [
            "",
            "",
            "tools:",
            "you can run a tool by writing a tag at the very end of your reply, after any spoken text.",
            "",
            "format: [TOOL:name:{\"argument\":\"value\"}]",
            "",
            "rules:",
            "- write the tag exactly once, at the end, and nothing after it.",
            "- always include the square brackets and the TOOL: prefix.",
            "- the part after the second colon must be valid json on a single line.",
            "- never guess or make up something a tool would tell you. if answering needs a tool, call it and wait for the result instead of describing what you imagine the result would be.",
            "- if a tool is not needed, just reply normally with no tag.",
            "- after a tool runs you will be shown its result and can then answer.",
            "",
            "available tools:"
        ]

        for tool in tools {
            lines.append("- \(tool.name): \(tool.description)")
            lines.append("  arguments: \(compactSchemaDescription(for: tool.inputSchema))")
        }

        // One worked example. Small models copy a demonstrated shape far more
        // reliably than they follow a description of it — without this the
        // model tends to emit a bare `name:{...}` and drop the brackets.
        //
        // The example is a liability as well as a help: it gets reproduced
        // verbatim, placeholder values and all, on turns that need no tool at
        // all. Hence the explicit warning, and the placeholder text below,
        // which is rejected during validation if it ever comes back.
        if let firstTool = tools.first {
            lines.append("")
            lines.append("this is only an illustration of the format — never copy its values, and never send a tool call just because you saw this example:")
            lines.append("sure, one moment. [TOOL:\(firstTool.name):\(exampleArguments(for: firstTool.inputSchema))]")
        }

        return lines.joined(separator: "\n")
    }

    /// Renders a JSON Schema as a short argument list, e.g. `{"label": string
    /// (required), "x": integer (required)}`. The full schema is far too
    /// verbose to place in a prompt that also carries an image.
    private static func compactSchemaDescription(for schema: JSONValue) -> String {
        guard case .object(let root) = schema,
              case .object(let properties)? = root["properties"] else {
            return "{}"
        }

        var requiredNames: Set<String> = []
        if case .array(let requiredValues)? = root["required"] {
            for value in requiredValues {
                if case .string(let name) = value { requiredNames.insert(name) }
            }
        }

        let described = properties.keys.sorted().map { name -> String in
            var typeName = "value"
            if case .object(let property)? = properties[name],
               case .string(let declaredType)? = property["type"] {
                typeName = declaredType
            }
            return "\"\(name)\": \(typeName)\(requiredNames.contains(name) ? " (required)" : "")"
        }

        return "{" + described.joined(separator: ", ") + "}"
    }

    /// The string placeholder used in the prompt's worked example. Recognisable
    /// on the way back so a parroted example can be discarded.
    static let examplePlaceholderText = "…"

    /// Whether a parsed call is just the worked example echoed back.
    ///
    /// Small models sometimes reproduce the example verbatim on turns that
    /// need no tool at all. Those calls are indistinguishable from real ones
    /// by shape, but their values give them away, and running one would act on
    /// a request the user never made.
    ///
    /// - Parameter exampleToolName: The tool the prompt's example shows (the
    ///   first one offered). Only a call to *that* tool can be an echo. Without
    ///   it, every call whose arguments happened to be all true/zero/empty was
    ///   dropped — so cua-driver's `list_windows {"on_screen_only": true}`, a
    ///   real and natural call, vanished and the turn ended with nothing done.
    ///   `nil` keeps the old any-tool reading for callers that don't know.
    static func isEchoOfPromptExample(_ call: ParsedToolCall, exampleToolName: String? = nil) -> Bool {
        if let exampleToolName, call.name != exampleToolName { return false }
        guard case .object(let arguments) = call.input, !arguments.isEmpty else { return false }

        return arguments.values.allSatisfy { value in
            switch value {
            case .string(let text): return text == examplePlaceholderText || text.isEmpty
            case .number(let number): return number == 0
            case .bool(let flag): return flag
            case .null: return true
            default: return false
            }
        }
    }

    /// A plausible-looking argument object for the prompt's worked example.
    private static func exampleArguments(for schema: JSONValue) -> String {
        guard case .object(let root) = schema,
              case .object(let properties)? = root["properties"],
              !properties.isEmpty else {
            return "{}"
        }

        let rendered = properties.keys.sorted().map { name -> String in
            var declaredType = "string"
            if case .object(let property)? = properties[name],
               case .string(let type)? = property["type"] {
                declaredType = type
            }
            switch declaredType {
            case "integer", "number": return "\"\(name)\": 0"
            case "boolean": return "\"\(name)\": true"
            default: return "\"\(name)\": \"\(examplePlaceholderText)\""
            }
        }
        return "{" + rendered.joined(separator: ", ") + "}"
    }

    /// Finds tool calls in a model reply and strips them from the spoken text.
    ///
    /// Two spellings are accepted. The documented one is the bracketed tag,
    /// but the model frequently drops the wrapper and writes a bare
    /// `name:{...}` instead — with the tool name and arguments otherwise
    /// perfectly formed. Since the intent is unambiguous, and only names that
    /// match a real tool are honoured, refusing that form would throw away a
    /// correct call over punctuation.
    ///
    /// - Parameter knownToolNames: Names eligible for the unbracketed form.
    ///   Pass the tools actually offered; without this, ordinary prose
    ///   containing a colon and a brace could be misread as a call.
    static func parse(_ responseText: String, knownToolNames: Set<String> = []) -> ParseResult {
        // Matches [TOOL:name:{...}] — the JSON body is captured lazily up to
        // the closing bracket so a trailing "]" inside a string is unlikely
        // to swallow the tag boundary.
        let bracketedPattern = #"\[TOOL:\s*([A-Za-z0-9_.-]+)\s*:\s*(\{.*?\})\s*\]"#
        let barePattern = #"(?:^|\s)([A-Za-z0-9_.-]+)\s*:\s*(\{.*?\})\s*$"#

        let hasBracketedTag = responseText.range(of: bracketedPattern, options: .regularExpression) != nil
        let pattern = hasBracketedTag ? bracketedPattern : barePattern

        // No tag anywhere: the whole reply is one run of prose.
        func plainTextResult() -> ParseResult {
            var blocks: [BuddyContentBlock] = []
            appendTextSegment(responseText, to: &blocks)
            return ParseResult(spokenText: responseText, toolCalls: [],
                               malformedTags: [], contentBlocks: blocks)
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return plainTextResult()
        }

        let fullRange = NSRange(responseText.startIndex..., in: responseText)
        let matches = regex.matches(in: responseText, range: fullRange)
        guard !matches.isEmpty else {
            return plainTextResult()
        }

        var toolCalls: [ParsedToolCall] = []
        var malformedTags: [String] = []
        // Every range actually recognised as a call, in the order it appears,
        // paired with the call it produced — `nil` when the tag was malformed.
        // Only these ranges are removed from the spoken text: a lenient
        // pattern can also match ordinary prose, and deleting that would
        // silently mangle the reply. Recording the positions rather than just
        // the calls is what lets the ordered blocks be rebuilt below.
        var recognisedTags: [(range: Range<String.Index>, call: ParsedToolCall?)] = []

        for match in matches {
            guard let nameRange = Range(match.range(at: 1), in: responseText),
                  let jsonRange = Range(match.range(at: 2), in: responseText),
                  let tagRange = Range(match.range, in: responseText) else { continue }

            let name = String(responseText[nameRange])
            let jsonText = String(responseText[jsonRange])

            // The unbracketed form is only trusted for names that are really
            // tools, so prose can't be mistaken for a call.
            if !hasBracketedTag && !knownToolNames.contains(name) {
                continue
            }

            if let jsonData = jsonText.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData),
               parsed is [String: Any] {
                let call = ParsedToolCall(
                    id: UUID().uuidString,
                    name: name,
                    input: JSONValue(untypedValue: parsed)
                )
                toolCalls.append(call)
                recognisedTags.append((range: tagRange, call: call))
            } else {
                malformedTags.append(String(responseText[tagRange]))
                recognisedTags.append((range: tagRange, call: nil))
            }
        }

        // Rebuild the reply as ordered blocks: the prose between recognised
        // tags, and the calls themselves, each where the model put it. Matches
        // arrive in ascending order and never overlap, so one forward pass is
        // enough. A malformed tag contributes no block — there is no call to
        // record — but its text is still skipped, so nothing tag-shaped
        // survives into the prose.
        var contentBlocks: [BuddyContentBlock] = []
        var segmentStart = responseText.startIndex
        for tag in recognisedTags {
            appendTextSegment(String(responseText[segmentStart..<tag.range.lowerBound]),
                              to: &contentBlocks)
            if let call = tag.call {
                contentBlocks.append(.toolUse(id: call.id, name: call.name, input: call.input))
            }
            segmentStart = tag.range.upperBound
        }
        appendTextSegment(String(responseText[segmentStart...]), to: &contentBlocks)

        // Remove recognised tags — valid or malformed — so nothing tag-shaped
        // is ever read aloud. Removing back-to-front keeps earlier indices
        // valid as the string shrinks.
        var spokenText = responseText
        for range in recognisedTags.map(\.range).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            spokenText.removeSubrange(range)
        }

        return ParseResult(
            spokenText: spokenText.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: toolCalls,
            malformedTags: malformedTags,
            contentBlocks: contentBlocks
        )
    }

    /// Appends one run of prose, unless it is blank once trimmed.
    ///
    /// A tag at the very end of a reply — which is where the prompt tells the
    /// model to put it — leaves an empty tail segment behind, and an empty
    /// text block would then travel into the conversation history as a message
    /// that says nothing.
    private static func appendTextSegment(
        _ segment: String,
        to blocks: inout [BuddyContentBlock]
    ) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        blocks.append(.text(trimmed))
    }

    /// Formats a tool's result as the user-role message fed back to the model.
    ///
    /// Small models follow a labelled, plain-language result far more
    /// consistently than a JSON envelope, and this text sits in the same
    /// context window as a screenshot, so brevity is worth real money here.
    static func resultMessageText(toolName: String, content: String, isError: Bool) -> String {
        isError
            ? "the \(toolName) tool failed: \(content)\nreply to the user about this without trying the tool again."
            : "result from \(toolName):\n\(content)\n\nnow answer the user using this result. do not call another tool unless it is truly needed."
    }
}
