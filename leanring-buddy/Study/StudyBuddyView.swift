//
//  StudyBuddyView.swift
//  leanring-buddy
//
//  The study buddy's body: the same living character as the Buddies page, driven by the
//  session. Its eyes follow the pointer, it squishes when it speaks or is poked, and its
//  face follows `StudyBuddyFeeling` (calm while you focus, happy on a win, dozing when paused).
//

import SwiftUI

enum StudyBuddyLook {
    /// A fixed hue from the buddy palette, so the study buddy is always recognisable.
    static let colorIndex = 2
}

struct StudyBuddyView: View {
    @ObservedObject private var controller = StudySessionController.shared
    var size: CGFloat = 40
    var liveliness: BuddyCharacter.Liveliness = .full

    var body: some View {
        BuddyCharacter(
            colorIndex: StudyBuddyLook.colorIndex,
            size: size,
            mood: mood(for: controller.buddyFeeling),
            liveliness: liveliness,
            bounceTrigger: controller.buddyBounce,
            looksAtPointer: true
        )
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { controller.pokeBuddy() }
        .pointerCursor()
        .nativeTooltip("Poke me")
    }

    private func mood(for feeling: StudyBuddyFeeling) -> BuddyMood {
        switch feeling {
        case .idle, .focused, .resting: return .idle
        case .cheering: return .happy
        case .sleepy: return .sleepy
        case .waiting: return .waiting
        }
    }
}
