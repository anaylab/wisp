//
//  ToolMetadata.swift
//  leanring-buddy
//
//  What a tool does to the world, as data the permission layer can reason about.
//
//  Until now a tool carried a single `requiresConfirmation` flag, set by hand at
//  each registration. That works while one person writes every tool and
//  remembers the rule, and stops working the moment tools arrive from
//  elsewhere — an MCP server, a Skill, a future provider — because the flag
//  records a *decision* without recording the *facts* the decision came from.
//  Nobody can audit "why does this ask?" and nothing can re-derive it when the
//  policy changes.
//
//  So the facts are stored and the decision is computed. A tool declares
//  whether it only reads, whether it destroys, whether its effects leave this
//  machine, and where its data comes from. Whether that warrants a prompt is
//  then one rule in one place, applied identically to a built-in tool and to
//  something a server described five seconds ago.
//

import Foundation

/// Where a tool's data comes from, for the UI and for future routing.
enum ToolDataSource: String, Sendable, CaseIterable {
    /// Reads nothing outside the tool itself, e.g. the current time.
    case none
    /// This Mac: files, windows, clipboard, screen.
    case localMachine
    /// The network: a web page, an API.
    case network
    /// Something a third party holds on the user's behalf, e.g. a mailbox.
    case userAccount
}

struct ToolMetadata: Sendable, Equatable {
    /// Observes without changing anything. A read-only tool run twice leaves
    /// the world exactly as a tool run once would.
    let readOnly: Bool

    /// Can remove or overwrite something that is not easily recovered.
    /// Stricter than "not read-only" — editing a file is reversible in a way
    /// that deleting it is not.
    let destructive: Bool

    /// Effects escape this machine: a message sent, an issue filed, a purchase.
    /// These are the ones that cannot be undone by quitting the app, which is
    /// why they are separated from ordinary writes.
    let externalSideEffect: Bool

    let dataSource: ToolDataSource

    /// Whether the user must approve before this runs.
    ///
    /// Deliberately derived rather than stored. One rule, one place, applied to
    /// every tool from every source — so a tool cannot be registered as
    /// destructive and silently also as not needing approval.
    var requiresConfirmation: Bool {
        !readOnly || destructive || externalSideEffect
    }

    init(
        readOnly: Bool,
        destructive: Bool = false,
        externalSideEffect: Bool = false,
        dataSource: ToolDataSource = .localMachine
    ) {
        self.readOnly = readOnly
        self.destructive = destructive
        self.externalSideEffect = externalSideEffect
        self.dataSource = dataSource
    }

    // MARK: - Common shapes

    /// Observes something on this Mac and changes nothing.
    static func reading(_ dataSource: ToolDataSource = .localMachine) -> ToolMetadata {
        ToolMetadata(readOnly: true, dataSource: dataSource)
    }

    /// Changes something, recoverably.
    static func writing(_ dataSource: ToolDataSource = .localMachine) -> ToolMetadata {
        ToolMetadata(readOnly: false, dataSource: dataSource)
    }

    /// Acts on the world beyond this Mac.
    static func external(_ dataSource: ToolDataSource = .network) -> ToolMetadata {
        ToolMetadata(readOnly: false, externalSideEffect: true, dataSource: dataSource)
    }

    /// The default for a tool that has not described itself.
    ///
    /// Assumes the worst, because the tools that arrive without metadata are
    /// exactly the ones nobody has vetted — an MCP server's, a Skill's. A tool
    /// that is merely cautious costs one prompt; the opposite default costs
    /// whatever the tool happened to do.
    static let unknown = ToolMetadata(
        readOnly: false, destructive: true, externalSideEffect: true, dataSource: .network
    )
}
