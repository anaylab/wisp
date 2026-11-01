//
//  BuddyGroupViews.swift
//  leanring-buddy
//
//  The Buddies page's group chat (after OpenBot's channels) and the editor that
//  makes and edits one. A group chat is one shared transcript: the user's
//  messages on the right, each buddy's answers on the left in its own colour,
//  and small notices in the middle for handoffs, stops and failures. @Name picks
//  who answers; otherwise the buddy who spoke last carries on.
//

import SwiftUI

// MARK: - Group chat

struct BuddyGroupChatView: View {
    let groupID: UUID
    var onEdit: () -> Void
    var onOpenBuddy: (UUID) -> Void

    @ObservedObject private var groupStore = BuddyGroupStore.shared
    @ObservedObject private var engine = BuddyGroupEngine.shared
    @ObservedObject private var buddyStore = BuddyStore.shared

    @State private var draftText = ""
    @State private var isConfirmingDeletion = false
    @FocusState private var isComposerFocused: Bool

    private let bottomAnchorID = "buddy-group-chat-bottom"

    var body: some View {
        if let group = groupStore.group(withID: groupID) {
            content(for: group)
        } else {
            Color.clear
        }
    }

    private func buddy(_ buddyID: UUID) -> WispBuddy? { buddyStore.buddy(withID: buddyID) }

    private func content(for group: BuddyGroup) -> some View {
        let messages = groupStore.messages(ofGroupWithID: group.id)
        let workingIDs = engine.workingBuddyIDs(inGroupWithID: group.id)
        let members = group.memberIDs.compactMap(buddy)
        return ZStack {
            BuddyAmbientBackground(colorIndex: members.first?.colorIndex ?? 1)
            VStack(spacing: 0) {
                header(for: group, members: members, workingIDs: workingIDs)
                Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty { emptyState(for: group, members: members) }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                                let previous = index > 0 ? messages[index - 1] : nil
                                if BuddyChatLayoutPolicy.startsNewDay(previous: previous?.createdAt, current: message.createdAt) {
                                    daySeparator(BuddyChatLayoutPolicy.dayLabel(for: message.createdAt, now: Date()))
                                }
                                row(for: message, previous: previous)
                            }
                            ForEach(workingIDs, id: \.self) { workingID in
                                if let working = buddy(workingID) { workingRow(working) }
                            }
                            Color.clear.frame(height: 1).id(bottomAnchorID)
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 20)
                        .padding(.bottom, 16)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .onAppear { scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                    .onChange(of: messages.count + workingIDs.count) { _, _ in
                        withAnimation(WispMotion.smooth) { scrollProxy.scrollTo(bottomAnchorID, anchor: .bottom) }
                    }
                }

                composer(for: group, members: members)
            }
        }
        .confirmationDialog("Delete \(group.name)?", isPresented: $isConfirmingDeletion) {
            Button("Delete Group", role: .destructive) {
                BuddyGroupEngine.shared.stop(groupWithID: group.id)
                groupStore.deleteGroup(withID: group.id)
            }
        } message: {
            Text("The shared chat is removed. The buddies and their own chats stay.")
        }
    }

    // MARK: Header

    private func header(for group: BuddyGroup, members: [WispBuddy], workingIDs: [UUID]) -> some View {
        HStack(spacing: 12) {
            BuddyGroupFace(members: members, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WispColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle(for: group, members: members, workingIDs: workingIDs))
                    .font(.system(size: 12))
                    .foregroundStyle(workingIDs.isEmpty ? WispColor.textSecondary : WispColor.accentText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if !workingIDs.isEmpty {
                Button { BuddyGroupEngine.shared.stop(groupWithID: group.id) } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: members.first?.colorIndex ?? 1, isProminent: false))
                    .pointerCursor()
            }
            Menu {
                Button("Edit Group…", systemImage: "pencil", action: onEdit)
                Menu("Give Last Message To", systemImage: "arrow.triangle.swap") {
                    ForEach(members) { member in
                        Button(member.name) {
                            BuddyGroupEngine.shared.reassignLatestMessage(inGroupWithID: group.id, toBuddyWithID: member.id)
                        }
                    }
                }
                .disabled(!groupStore.messages(ofGroupWithID: group.id).contains { $0.author == .user })
                Divider()
                Button("Clear Messages", systemImage: "eraser") {
                    BuddyGroupEngine.shared.stop(groupWithID: group.id)
                    groupStore.clearMessages(ofGroupWithID: group.id)
                }
                Button(group.isArchivedInList ? "Restore" : "Archive", systemImage: group.isArchivedInList ? "tray.and.arrow.up" : "archivebox") {
                    groupStore.setArchived(!group.isArchivedInList, groupWithID: group.id)
                }
                Button("Delete…", systemImage: "trash", role: .destructive) { isConfirmingDeletion = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WispColor.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .pointerCursor()
            .accessibilityLabel("More actions")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }

    private func subtitle(for group: BuddyGroup, members: [WispBuddy], workingIDs: [UUID]) -> String {
        if let firstWorking = workingIDs.first.flatMap(buddy) {
            let isStarted = engine.activeAssignments.values.contains { $0.groupID == group.id && $0.ownerID == firstWorking.id }
            return isStarted ? "\(firstWorking.name) is working…" : "Waiting for \(firstWorking.name)…"
        }
        return members.map(\.name).joined(separator: ", ")
    }

    // MARK: Transcript

    private func emptyState(for group: BuddyGroup, members: [WispBuddy]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Say something to the group.")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(WispColor.textPrimary)
            Text("One buddy answers each message. Use @Name to choose who; otherwise whoever spoke last carries on, starting with \(leadName(for: group, members: members)).")
                .font(.system(size: 12.5))
                .foregroundStyle(WispColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WispColor.surface2.opacity(0.6)))
    }

    private func leadName(for group: BuddyGroup, members: [WispBuddy]) -> String {
        (group.leadID.flatMap(buddy) ?? members.first)?.name ?? "the first member"
    }

    private func daySeparator(_ label: String) -> some View {
        HStack(spacing: 10) {
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(WispColor.textTertiary)
            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func row(for message: BuddyGroupMessage, previous: BuddyGroupMessage?) -> some View {
        switch message.author {
        case .user:
            Text(message.text)
                .font(.system(size: 13.5))
                .foregroundStyle(WispColor.textOnAccent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.accent))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 70)
        case .buddy(let buddyID):
            let author = buddy(buddyID)
            let continues = previous?.author == message.author
                && BuddyChatLayoutPolicy.continuesAnswerRun(
                    previous: previous?.createdAt, current: message.createdAt, currentHasUserMessage: false,
                    startsNewDay: false)
            buddyMessageRow(message, author: author, showsHeader: !continues)
        case .notice:
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 10))
                Text(message.text).font(.system(size: 11.5))
            }
            .foregroundStyle(WispColor.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
    }

    private func buddyMessageRow(_ message: BuddyGroupMessage, author: WispBuddy?, showsHeader: Bool) -> some View {
        let colorIndex = author?.colorIndex ?? 1
        return HStack(alignment: .top, spacing: 8) {
            Group {
                if showsHeader {
                    Button {
                        if let author { onOpenBuddy(author.id) }
                    } label: {
                        BuddyCharacter(colorIndex: colorIndex, size: 24, mood: .idle, liveliness: .still)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .nativeTooltip(author.map { "Open \($0.name)" })
                } else {
                    Color.clear.frame(width: 26, height: 26)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                if showsHeader {
                    HStack(spacing: 6) {
                        Text(author?.name ?? "Former member")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: colorIndex))
                        Text(BuddyFormatting.timeText(message.createdAt))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(WispColor.textTertiary)
                    }
                }
                Text(BuddyAnswerFormatting.attributedAnswer(message.text))
                    .font(.system(size: 13.5))
                    .foregroundStyle(WispColor.textPrimary)
                    .tint(BuddyAppearance.deepColor(forColorIndex: colorIndex))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface2.opacity(0.9)))
            }
            Spacer(minLength: 40)
        }
    }

    private func workingRow(_ working: WispBuddy) -> some View {
        HStack(spacing: 8) {
            BuddyCharacter(colorIndex: working.colorIndex, size: 24, mood: .working, liveliness: .working)
                .frame(width: 26, height: 26)
            BuddyTypingDots(colorIndex: working.colorIndex)
                .padding(.horizontal, 13).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface2.opacity(0.9)))
            Spacer()
        }
        .transition(.opacity)
        .accessibilityLabel("\(working.name) is working")
    }

    // MARK: Composer

    private func composer(for group: BuddyGroup, members: [WispBuddy]) -> some View {
        VStack(spacing: 8) {
            // Tap a name to address that buddy; the composer keeps what is typed.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(members) { member in
                        Button {
                            insertAddress(for: member)
                        } label: {
                            Text("@\(member.name)")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(BuddyAppearance.deepColor(forColorIndex: member.colorIndex))
                                .padding(.horizontal, 9).frame(height: 24)
                                .background(Capsule(style: .continuous).fill(WispColor.surface3.opacity(0.8)))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .accessibilityLabel("Address \(member.name)")
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message the group — @Name picks who answers", text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(1...6)
                    .focused($isComposerFocused)
                    .onSubmit { send(to: group) }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(WispColor.surface2.opacity(0.9)))
                Button { send(to: group) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(WispColor.textOnAccent)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(WispColor.accent.opacity(canSend ? 1 : 0.35)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .pointerCursor()
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool { !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func insertAddress(for member: BuddyGroupMember) {
        draftText = "@\(member.name) " + draftText
        isComposerFocused = true
    }

    private func insertAddress(for member: WispBuddy) {
        insertAddress(for: BuddyGroupMember(id: member.id, name: member.name))
    }

    private func send(to group: BuddyGroup) {
        guard canSend else { return }
        if BuddyGroupEngine.shared.send(draftText, inGroupWithID: group.id) { draftText = "" }
    }
}

extension BuddyGroupMember {
    init(_ buddy: WispBuddy) { self.init(id: buddy.id, name: buddy.name) }
}

// MARK: - Overlapping faces

/// A few member characters side by side, overlapping, as a group's avatar.
struct BuddyGroupFace: View {
    let members: [WispBuddy]
    var size: CGFloat = 26
    var maximumFaces = 3

    var body: some View {
        let shown = Array(members.prefix(maximumFaces))
        HStack(spacing: -size * 0.35) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, member in
                BuddyCharacter(colorIndex: member.colorIndex, size: size, mood: .idle, liveliness: .still)
                    .frame(width: size + 4, height: size + 4)
                    .background(Circle().fill(WispColor.windowBackground))
                    .zIndex(Double(shown.count - index))
            }
        }
        .frame(minWidth: size + 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Editor

/// A small dialog, like OpenBot's "New channel": a name, a searchable list of buddies to add,
/// and Create. Shown as a sheet over the Buddies page.
struct BuddyGroupEditorView: View {
    /// Nil makes a new group; otherwise edits that one.
    let groupID: UUID?
    var onSaved: (UUID) -> Void
    var onCancel: () -> Void

    @ObservedObject private var groupStore = BuddyGroupStore.shared
    @ObservedObject private var buddyStore = BuddyStore.shared
    @State private var nameText = ""
    @State private var hasEditedName = false
    @State private var searchText = ""
    @State private var selectedMemberIDs: [UUID] = []
    @State private var leadID: UUID?

    private var candidates: [WispBuddy] {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
        return trimmedSearch.isEmpty
            ? buddyStore.buddies
            : buddyStore.buddies.filter { $0.name.localizedCaseInsensitiveContains(trimmedSearch) }
    }
    private var canSave: Bool { selectedMemberIDs.count >= 2 }

    private var suggestedName: String {
        BuddyGroupPolicy.suggestedName(memberNames: selectedMemberIDs.compactMap { buddyStore.buddy(withID: $0)?.name })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(groupID == nil ? "New group" : "Edit group")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(WispColor.textPrimary)
                Spacer()
                BuddyIconButton(symbolName: "xmark", label: "Close", size: 26, action: onCancel)
            }
            .padding(.horizontal, 20).frame(height: 52)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    label("Group name")
                    TextField(selectedMemberIDs.count >= 2 ? suggestedName : "Ex: Project Falcon", text: Binding(
                        get: { nameText },
                        set: { nameText = $0; hasEditedName = true }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 7) {
                    label("Add buddies (pick at least two)")
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(WispColor.textTertiary)
                        TextField("Search buddies", text: $searchText).textFieldStyle(.plain).font(.system(size: 12.5))
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(WispColor.surface3.opacity(0.7)))

                    ScrollView {
                        VStack(spacing: 0) { ForEach(candidates) { buddy in memberRow(buddy) } }
                    }
                    .frame(height: min(220, CGFloat(max(candidates.count, 1)) * 46))
                }

                if selectedMemberIDs.count >= 2 {
                    HStack {
                        label("Answers first")
                        Spacer()
                        Picker("Lead", selection: $leadID) {
                            Text("First member").tag(UUID?.none)
                            ForEach(selectedMemberIDs.compactMap(buddyStore.buddy(withID:))) { buddy in
                                Text(buddy.name).tag(UUID?.some(buddy.id))
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).fixedSize().pointerCursor()
                    }
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)

            Rectangle().fill(WispColor.cardSeparator.opacity(0.5)).frame(height: 0.5)
            HStack {
                Spacer()
                Button(groupID == nil ? "Create" : "Save", action: save)
                    .buttonStyle(BuddyPillButtonStyle(colorIndex: 1)).pointerCursor()
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20).frame(height: 56)
        }
        .frame(width: 460)
        .background(WispColor.background)
        .onAppear(perform: loadExisting)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(WispColor.textSecondary)
    }

    private func memberRow(_ buddy: WispBuddy) -> some View {
        let isSelected = selectedMemberIDs.contains(buddy.id)
        return Button {
            withAnimation(WispMotion.quick) {
                if isSelected { selectedMemberIDs.removeAll { $0 == buddy.id } } else { selectedMemberIDs.append(buddy.id) }
                if let leadID, !selectedMemberIDs.contains(leadID) { self.leadID = nil }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? BuddyAppearance.deepColor(forColorIndex: buddy.colorIndex) : WispColor.textTertiary)
                BuddyCharacter(colorIndex: buddy.colorIndex, size: 26, mood: .idle, liveliness: .still)
                    .frame(width: 30, height: 30)
                Text(buddy.name).font(.system(size: 13, weight: .medium)).foregroundStyle(WispColor.textPrimary)
                Text(buddy.instruction)
                    .font(.system(size: 11.5)).foregroundStyle(WispColor.textTertiary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4).frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(buddy.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func loadExisting() {
        guard let groupID, let group = groupStore.group(withID: groupID) else { return }
        nameText = group.name
        hasEditedName = true
        selectedMemberIDs = group.memberIDs
        leadID = group.leadID
    }

    private func save() {
        let name = hasEditedName && !nameText.trimmingCharacters(in: .whitespaces).isEmpty ? nameText : suggestedName
        if let groupID {
            groupStore.updateGroup(withID: groupID, name: name, memberIDs: selectedMemberIDs, leadID: leadID)
            onSaved(groupID)
        } else {
            onSaved(groupStore.createGroup(name: name, memberIDs: selectedMemberIDs, leadID: leadID).id)
        }
    }
}
