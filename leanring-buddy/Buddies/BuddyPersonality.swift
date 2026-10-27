//
//  BuddyPersonality.swift
//  leanring-buddy
//
//  How a buddy works, not who it pretends to be. Five work styles (Coach, Chill,
//  Hype, Deadpan, Teacher) each set the persona line added to the buddy's prompt,
//  how long and in what tone its replies run, the voice and speed it would speak
//  with, and how big its celebration is when Playful is on. Nothing here is
//  romantic or roleplay: a personality changes tone and brevity, never what the
//  buddy is allowed to do.
//
//  Foundation only and `nonisolated`, so the prompt projection is tested by
//  `Tests/BuddyPersonality` and `Tests/BuddyThread` without the app.
//

import Foundation

nonisolated enum BuddyPersonality: String, Codable, CaseIterable, Identifiable, Sendable {
    case coach
    case chill
    case hype
    case deadpan
    case teacher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coach: return "Coach"
        case .chill: return "Chill"
        case .hype: return "Hype"
        case .deadpan: return "Deadpan"
        case .teacher: return "Teacher"
        }
    }

    /// One short line for the picker.
    var tagline: String {
        switch self {
        case .coach: return "Direct and encouraging"
        case .chill: return "Easy, unhurried, short"
        case .hype: return "Big energy, big cheers"
        case .deadpan: return "Dry and to the point"
        case .teacher: return "Explains the why"
        }
    }

    var symbolName: String {
        switch self {
        case .coach: return "figure.run"
        case .chill: return "leaf.fill"
        case .hype: return "party.popper.fill"
        case .deadpan: return "face.dashed"
        case .teacher: return "graduationcap.fill"
        }
    }

    var replyStyle: BuddyReplyStyle {
        switch self {
        case .coach: return BuddyReplyStyle(maximumSentences: 4, tone: "warm, direct and action-first", usesEmoji: false)
        case .chill: return BuddyReplyStyle(maximumSentences: 3, tone: "relaxed, calm and low-pressure", usesEmoji: false)
        case .hype: return BuddyReplyStyle(maximumSentences: 3, tone: "upbeat, energetic and celebratory", usesEmoji: true)
        case .deadpan: return BuddyReplyStyle(maximumSentences: 2, tone: "dry, flat and very brief", usesEmoji: false)
        case .teacher: return BuddyReplyStyle(maximumSentences: 6, tone: "patient, clear and explanatory", usesEmoji: false)
        }
    }

    /// Added to the buddy's system prompt after the specialty line. It states a
    /// work style only, and says outright that it grants nothing else.
    var personaLine: String {
        let style = replyStyle
        let emojiRule = style.usesEmoji ? "An occasional emoji is fine." : "Don't use emoji."
        let styleSpecificLine: String
        switch self {
        case .coach:
            styleSpecificLine = "Lead with the next concrete step and say what is going well."
        case .chill:
            styleSpecificLine = "Keep the pressure off: name the one thing that matters and let the rest wait."
        case .hype:
            styleSpecificLine = "Celebrate real progress, and keep the cheering to the facts."
        case .deadpan:
            styleSpecificLine = "State things plainly with a dry edge. No exclamation marks."
        case .teacher:
            styleSpecificLine = "Give the reason behind each suggestion in a sentence, so the user learns it."
        }
        return """
        Work style: \(style.tone). \(styleSpecificLine) Keep replies to about \(style.maximumSentences) \
        sentences unless the user asks for more. \(emojiRule) This is only how you phrase things; it never \
        changes what you are allowed to do or what you need approval for.
        """
    }

    var voice: BuddyVoiceProfile {
        switch self {
        case .coach: return BuddyVoiceProfile(kokoroVoiceIdentifier: "af_heart", speakingRate: 1.05)
        case .chill: return BuddyVoiceProfile(kokoroVoiceIdentifier: "af_sky", speakingRate: 0.92)
        case .hype: return BuddyVoiceProfile(kokoroVoiceIdentifier: "af_bella", speakingRate: 1.15)
        case .deadpan: return BuddyVoiceProfile(kokoroVoiceIdentifier: "am_adam", speakingRate: 0.95)
        case .teacher: return BuddyVoiceProfile(kokoroVoiceIdentifier: "bf_emma", speakingRate: 0.97)
        }
    }

    var reaction: BuddyReactionProfile {
        switch self {
        case .coach: return BuddyReactionProfile(personality: self, celebrationLevel: 1)
        case .chill: return BuddyReactionProfile(personality: self, celebrationLevel: 0)
        case .hype: return BuddyReactionProfile(personality: self, celebrationLevel: 2)
        case .deadpan: return BuddyReactionProfile(personality: self, celebrationLevel: 0)
        case .teacher: return BuddyReactionProfile(personality: self, celebrationLevel: 1)
        }
    }
}

nonisolated struct BuddyReplyStyle: Equatable, Sendable {
    /// A soft cap stated in the prompt; the model is asked, not forced.
    let maximumSentences: Int
    /// Used inside `personaLine`, e.g. "warm, direct and action-first".
    let tone: String
    let usesEmoji: Bool
}

nonisolated struct BuddyVoiceProfile: Equatable, Sendable {
    /// A Kokoro voice id. Stored as the buddy's chosen voice. The speech engine
    /// currently loads one voice (`KokoroSynthesisEngine.voiceIdentifier`, because
    /// other voices are a further download), so this is not yet audible and the
    /// picker makes no promise that it is.
    let kokoroVoiceIdentifier: String
    /// 1.0 is normal; always within `allowedSpeakingRateRange`.
    let speakingRate: Double

    static let allowedSpeakingRateRange: ClosedRange<Double> = 0.8...1.25

    init(kokoroVoiceIdentifier: String, speakingRate: Double) {
        self.kokoroVoiceIdentifier = kokoroVoiceIdentifier
        self.speakingRate = min(max(speakingRate, Self.allowedSpeakingRateRange.lowerBound), Self.allowedSpeakingRateRange.upperBound)
    }
}

nonisolated struct BuddyReactionProfile: Equatable, Sendable {
    fileprivate let personality: BuddyPersonality

    /// How big the finish celebration is when Playful is on:
    /// 0 = none, 1 = a bounce, 2 = a bounce and a soft burst.
    let celebrationLevel: Int

    fileprivate init(personality: BuddyPersonality, celebrationLevel: Int) {
        self.personality = personality
        self.celebrationLevel = celebrationLevel
    }

    /// The one word that says how this buddy feels, in its own voice.
    func moodWord(for mood: BuddyMood) -> String {
        switch (personality, mood) {
        case (.coach, .idle): return "ready"
        case (.coach, .working): return "on it"
        case (.coach, .happy): return "nailed it"
        case (.coach, .sleepy): return "resting"
        case (.coach, .oops): return "regrouping"
        case (.coach, .waiting): return "need your call"

        case (.chill, .idle): return "chilling"
        case (.chill, .working): return "easing in"
        case (.chill, .happy): return "all good"
        case (.chill, .sleepy): return "napping"
        case (.chill, .oops): return "no stress"
        case (.chill, .waiting): return "whenever"

        case (.hype, .idle): return "stoked"
        case (.hype, .working): return "locked in"
        case (.hype, .happy): return "pumped"
        case (.hype, .sleepy): return "recharging"
        case (.hype, .oops): return "next one"
        case (.hype, .waiting): return "need a yes"

        case (.deadpan, .idle): return "present"
        case (.deadpan, .working): return "working"
        case (.deadpan, .happy): return "fine"
        case (.deadpan, .sleepy): return "dormant"
        case (.deadpan, .oops): return "it broke"
        case (.deadpan, .waiting): return "waiting"

        case (.teacher, .idle): return "curious"
        case (.teacher, .working): return "thinking it through"
        case (.teacher, .happy): return "learned something"
        case (.teacher, .sleepy): return "off duty"
        case (.teacher, .oops): return "let's review"
        case (.teacher, .waiting): return "your decision"
        }
    }
}
