//
//  ToolCallInspection.swift
//  leanring-buddy
//
//  Deterministic reading of a tool call — its name and its JSON arguments —
//  shared by the two things that need to understand a call before it runs:
//  the destructive-action floor (`ToolCallSafety`) and the rich confirmation
//  card (`ToolConfirmationCardBuilder`).
//
//  No model is involved anywhere here. A tool name like
//  `composio-connect__COMPOSIO_MULTI_EXECUTE_TOOL` or `filesystem__write_file`
//  is split into lowercase words, and arguments are looked up leniently by a
//  handful of conventional key names. Being lenient matters because MCP
//  servers and Composio toolkits each spell the same idea differently
//  (`to` / `recipient` / `recipient_email`), and a card that misses a field is
//  harmless while a parser that throws is not.
//

import Foundation

/// One concrete action a tool call will perform, after any wrapper has been
/// peeled away.
///
/// Most calls are exactly one action — the tool itself. Composio's gateway is
/// the exception: `COMPOSIO_MULTI_EXECUTE_TOOL` is a meta-tool whose arguments
/// name the real tools (`GMAIL_SEND_EMAIL`, `SLACK_SEND_MESSAGE`, …) and carry
/// their arguments. Judging or describing the wrapper by its own name would
/// say nothing about what actually happens, so it is unwrapped into these.
struct InspectedToolAction: Equatable {
    /// The action's own name with any `server__` namespace removed, e.g.
    /// `write_file` or `GMAIL_SEND_EMAIL`.
    let bareActionName: String
    /// The service the action belongs to when one can be told — the MCP server
    /// prefix, or a Composio slug's toolkit prefix (`GMAIL`). Used only as a
    /// label on the card.
    let serviceName: String?
    /// The action name split into lowercase words.
    let actionNameWords: [String]
    /// The action's arguments. `.object` in every well-formed case.
    let arguments: JSONValue
}

enum ToolCallInspection {

    // MARK: - Names

    /// Drops the `server__` namespace the MCP manager prefixes onto every tool.
    static func bareToolName(_ toolName: String) -> String {
        guard let namespaceSeparatorRange = toolName.range(of: "__") else {
            return toolName
        }
        return String(toolName[namespaceSeparatorRange.upperBound...])
    }

    /// The `server` part of a `server__tool` name, or nil for a built-in tool.
    static func serverNamespace(of toolName: String) -> String? {
        guard let namespaceSeparatorRange = toolName.range(of: "__") else {
            return nil
        }
        let namespace = String(toolName[..<namespaceSeparatorRange.lowerBound])
        return namespace.isEmpty ? nil : namespace
    }

    /// Splits an identifier into lowercase words on underscores, hyphens,
    /// dots, spaces and camelCase boundaries, so `chat.postMessage`,
    /// `SLACK_SEND_MESSAGE` and `delete-file` all read the same way.
    static func words(inIdentifier identifier: String) -> [String] {
        var words: [String] = []
        var currentWord = ""
        var previousCharacterWasLowercaseOrDigit = false

        for character in identifier {
            let isWordCharacter = character.isLetter || character.isNumber
            if !isWordCharacter {
                if !currentWord.isEmpty { words.append(currentWord.lowercased()) }
                currentWord = ""
                previousCharacterWasLowercaseOrDigit = false
                continue
            }
            // A capital after a lowercase letter starts a new camelCase word.
            if character.isUppercase && previousCharacterWasLowercaseOrDigit && !currentWord.isEmpty {
                words.append(currentWord.lowercased())
                currentWord = ""
            }
            currentWord.append(character)
            previousCharacterWasLowercaseOrDigit = character.isLowercase || character.isNumber
        }
        if !currentWord.isEmpty { words.append(currentWord.lowercased()) }
        return words
    }

    // MARK: - Composio unwrapping

    /// Whether a bare tool name is one of Composio's gateway meta-tools
    /// (`COMPOSIO_SEARCH_TOOLS`, `COMPOSIO_MULTI_EXECUTE_TOOL`, …).
    static func isComposioMetaTool(bareToolName: String) -> Bool {
        bareToolName.uppercased().hasPrefix("COMPOSIO_")
    }

    /// Whether a Composio meta-tool is the one that executes other tools. Named
    /// leniently (anything with EXECUTE in it) so a single-tool variant or a
    /// future rename is still unwrapped rather than judged by its wrapper name.
    static func isComposioExecuteMetaTool(bareToolName: String) -> Bool {
        let uppercasedName = bareToolName.uppercased()
        return isComposioMetaTool(bareToolName: bareToolName)
            && uppercasedName.contains("EXECUTE")
            && !uppercasedName.contains("BASH")
            && !uppercasedName.contains("WORKBENCH")
    }

    /// The concrete actions a Composio execute call carries, or nil when the
    /// arguments are not in a shape that can be read.
    ///
    /// The gateway's documented shape is
    /// `{"tools":[{"tool_slug":"GMAIL_SEND_EMAIL","arguments":{…}}]}`; a
    /// single-tool `{"tool_slug":…, "arguments":…}` is accepted too, and the
    /// inner arguments may arrive as a JSON *string* rather than an object,
    /// which small models do.
    static func composioExecutedActions(in composioArguments: JSONValue) -> [InspectedToolAction]? {
        guard case .object(let composioArgumentFields) = composioArguments else { return nil }

        var rawToolItems: [JSONValue] = []
        if case .array(let toolItems)? = composioArgumentFields["tools"] {
            rawToolItems = toolItems
        } else if composioArgumentFields["tool_slug"] != nil || composioArgumentFields["slug"] != nil {
            rawToolItems = [composioArguments]
        }
        guard !rawToolItems.isEmpty else { return nil }

        var executedActions: [InspectedToolAction] = []
        for rawToolItem in rawToolItems {
            guard let toolSlug = stringValue(
                forAnyOf: ["tool_slug", "slug", "tool", "action", "name"],
                in: rawToolItem
            ) else {
                // An item whose tool cannot be named cannot be judged; the
                // caller treats the whole call as unreadable.
                return nil
            }
            let innerArguments = objectValue(
                forAnyOf: ["arguments", "args", "input", "params", "parameters"],
                in: rawToolItem
            ) ?? .object([:])
            let slugWords = words(inIdentifier: toolSlug)
            executedActions.append(
                InspectedToolAction(
                    bareActionName: toolSlug,
                    serviceName: slugWords.first,
                    actionNameWords: slugWords,
                    arguments: innerArguments
                )
            )
        }
        return executedActions
    }

    /// Resolves a call into the concrete actions it performs.
    ///
    /// A Composio execute call becomes its inner tools. Every other call —
    /// including a Composio execute call whose arguments cannot be read — is
    /// one action describing itself.
    static func inspectedActions(toolName: String, toolInput: JSONValue) -> [InspectedToolAction] {
        let bareName = bareToolName(toolName)
        if isComposioExecuteMetaTool(bareToolName: bareName),
           let executedActions = composioExecutedActions(in: toolInput) {
            return executedActions
        }
        return [
            InspectedToolAction(
                bareActionName: bareName,
                serviceName: serverNamespace(of: toolName),
                actionNameWords: words(inIdentifier: bareName),
                arguments: toolInput
            )
        ]
    }

    // MARK: - Argument lookup

    /// The first matching field of an object, matching keys case-insensitively
    /// and ignoring `_`/`-` so `startTime`, `start_time` and `start-time` agree.
    static func fieldValue(forAnyOf candidateKeys: [String], in arguments: JSONValue) -> JSONValue? {
        guard case .object(let argumentFields) = arguments else { return nil }
        let normalizedFieldsByKey = Dictionary(
            argumentFields.map { (normalizedKey($0.key), $0.value) },
            uniquingKeysWith: { firstValue, _ in firstValue }
        )
        for candidateKey in candidateKeys {
            if let matchingValue = normalizedFieldsByKey[normalizedKey(candidateKey)] {
                if case .null = matchingValue { continue }
                return matchingValue
            }
        }
        return nil
    }

    /// A field rendered as display text, or nil when absent or blank.
    static func stringValue(forAnyOf candidateKeys: [String], in arguments: JSONValue) -> String? {
        guard let matchingValue = fieldValue(forAnyOf: candidateKeys, in: arguments) else { return nil }
        return displayText(for: matchingValue)
    }

    /// A field as a JSON object, parsing it first when it arrived as a JSON
    /// string — a common small-model habit for nested arguments.
    static func objectValue(forAnyOf candidateKeys: [String], in arguments: JSONValue) -> JSONValue? {
        guard let matchingValue = fieldValue(forAnyOf: candidateKeys, in: arguments) else { return nil }
        switch matchingValue {
        case .object:
            return matchingValue
        case .string(let jsonText):
            guard let jsonData = jsonText.data(using: .utf8),
                  let parsedObject = try? JSONSerialization.jsonObject(with: jsonData),
                  case .object = JSONValue(untypedValue: parsedObject) else { return nil }
            return JSONValue(untypedValue: parsedObject)
        default:
            return nil
        }
    }

    /// Renders any JSON value as short readable text for a card or a check.
    ///
    /// Arrays of people (`[{"email":"a@b.com"}]`) and date objects
    /// (`{"dateTime":"…"}`) are common in mail and calendar arguments, so
    /// objects are read through a few conventional fields rather than dumped.
    static func displayText(for value: JSONValue) -> String? {
        switch value {
        case .null:
            return nil
        case .bool(let booleanValue):
            return booleanValue ? "yes" : "no"
        case .number(let numberValue):
            if numberValue == numberValue.rounded() && abs(numberValue) < 1e15 {
                return String(Int(numberValue))
            }
            return String(numberValue)
        case .string(let stringValue):
            let trimmedText = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedText.isEmpty ? nil : trimmedText
        case .array(let arrayValues):
            let itemTexts = arrayValues.compactMap(displayText(for:))
            return itemTexts.isEmpty ? nil : itemTexts.joined(separator: ", ")
        case .object:
            let readableFieldKeys = [
                "email", "emailAddress", "address", "name", "displayName",
                "dateTime", "date", "value", "title", "id"
            ]
            return stringValue(forAnyOf: readableFieldKeys, in: value)
        }
    }

    /// The file-system paths a call names, read from the conventional path
    /// argument keys (`path`, `source`, `destination`, …). Only string values
    /// count; a `paths` array contributes each of its strings.
    static func pathLikeArgumentValues(in arguments: JSONValue) -> [String] {
        let pathArgumentKeys = [
            "path", "file_path", "filepath", "file", "filename", "file_name",
            "source", "source_path", "destination", "destination_path", "dest",
            "target", "target_path", "output_path", "new_path", "old_path", "paths"
        ]
        var pathValues: [String] = []
        for pathArgumentKey in pathArgumentKeys {
            guard let matchingValue = fieldValue(forAnyOf: [pathArgumentKey], in: arguments) else { continue }
            switch matchingValue {
            case .string(let pathText):
                let trimmedPath = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedPath.isEmpty { pathValues.append(trimmedPath) }
            case .array(let pathItems):
                for case .string(let pathText) in pathItems {
                    let trimmedPath = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedPath.isEmpty { pathValues.append(trimmedPath) }
                }
            default:
                continue
            }
        }
        return pathValues
    }

    /// Whether a path (absolute, `~`-relative, or relative to the agent
    /// folder) resolves inside the agent's working folder.
    ///
    /// Standardised before comparing so `folder/../../etc` cannot pass as
    /// inside, and compared with a trailing slash so `/projects/app-other`
    /// does not count as inside `/projects/app`.
    static func isPath(_ rawPath: String, insideDirectory rawDirectoryPath: String) -> Bool {
        let expandedDirectoryPath = (rawDirectoryPath as NSString).expandingTildeInPath
        let standardizedDirectoryPath = URL(fileURLWithPath: expandedDirectoryPath).standardizedFileURL.path

        let pathWithoutFileScheme = rawPath.hasPrefix("file://")
            ? (URL(string: rawPath)?.path ?? rawPath)
            : rawPath
        let expandedPath = (pathWithoutFileScheme as NSString).expandingTildeInPath
        let absolutePath = expandedPath.hasPrefix("/")
            ? expandedPath
            : (standardizedDirectoryPath as NSString).appendingPathComponent(expandedPath)
        let standardizedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path

        if standardizedPath == standardizedDirectoryPath { return true }
        let directoryPrefix = standardizedDirectoryPath.hasSuffix("/")
            ? standardizedDirectoryPath
            : standardizedDirectoryPath + "/"
        return standardizedPath.hasPrefix(directoryPrefix)
    }

    private static func normalizedKey(_ rawKey: String) -> String {
        rawKey.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
