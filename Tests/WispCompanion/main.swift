//
//  Wisp companion suite: what the notch's cloud feels and when — mood
//  precedence, pokes turning into dizziness, where its eyes look, and blinking.
//

import CoreGraphics
import Foundation

var failureCount = 0
var checkCount = 0

func check(_ condition: Bool, _ description: String) {
    checkCount += 1
    if !condition {
        failureCount += 1
        print("FAIL: \(description)")
    }
}

let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

func signals(
    _ activity: WispCompanionActivity,
    approval: Bool = false,
    busy: Int = 0,
    quietFor: TimeInterval = 0,
    reaction: WispCompanionReaction? = nil
) -> WispCompanionSignals {
    WispCompanionSignals(
        activity: activity,
        hasPendingCodingAgentApproval: approval,
        busyWorkCount: busy,
        secondsSinceLastActivity: quietFor,
        activeReaction: reaction
    )
}

func mood(_ companionSignals: WispCompanionSignals) -> WispCompanionMood {
    WispCompanionMoodResolver.mood(for: companionSignals, at: now)
}

// MARK: - Moods from activity

check(mood(signals(.idle)) == .content, "idle and recently active → content")
check(mood(signals(.listening)) == .listening, "listening")
check(mood(signals(.thinking)) == .thinking, "thinking")
check(mood(signals(.working)) == .working, "working")
check(mood(signals(.succeeded)) == .happy, "a success flash → happy")
check(mood(signals(.failed)) == .sad, "an error flash → sad")
check(mood(signals(.answerShowing)) == .content, "an answer showing → content")
check(mood(signals(.awaitingConfirmation)) == .needsYou, "Wisp's own confirmation → needs you")
check(mood(signals(.idle, busy: 2)) == .working, "idle but agents/tasks busy → working")
check(mood(signals(.idle, quietFor: WispCompanionMoodResolver.secondsBeforeSleepy)) == .sleepy, "a long quiet → sleepy")
check(mood(signals(.idle, busy: 1, quietFor: 99_999)) == .working, "busy work keeps it awake")
check(mood(signals(.listening, quietFor: 99_999)) == .listening, "talking to it wakes it")

// MARK: - Precedence

let pokeReaction = WispCompanionReaction(mood: .annoyed, endsAt: now.addingTimeInterval(1))
check(mood(signals(.thinking, reaction: pokeReaction)) == .annoyed, "a live reaction beats ordinary activity")
check(mood(signals(.idle, approval: true, reaction: pokeReaction)) == .needsYou, "something needing you beats a reaction")
let expiredReaction = WispCompanionReaction(mood: .happy, endsAt: now.addingTimeInterval(-0.1))
check(mood(signals(.thinking, reaction: expiredReaction)) == .thinking, "an expired reaction is ignored")
check(mood(signals(.idle, quietFor: 99_999, reaction: WispCompanionReaction(mood: .greeting, endsAt: now.addingTimeInterval(2)))) == .greeting,
      "a greeting shows even after a long quiet")

// MARK: - Pokes

var pokeTracker = WispCompanionPokeTracker()
check(pokeTracker.registerPoke(at: now).mood == .annoyed, "one poke annoys")
check(pokeTracker.registerPoke(at: now.addingTimeInterval(0.3)).mood == .annoyed, "two pokes still only annoy")
let thirdPoke = pokeTracker.registerPoke(at: now.addingTimeInterval(0.6))
check(thirdPoke.mood == .dizzy, "three quick pokes make it dizzy")
check(thirdPoke.endsAt == now.addingTimeInterval(0.6 + WispCompanionPokeTracker.dizzySeconds), "dizziness lasts its full time")
check(pokeTracker.registerPoke(at: now.addingTimeInterval(0.8)).mood == .annoyed, "the count restarts after dizziness")

var slowPokeTracker = WispCompanionPokeTracker()
_ = slowPokeTracker.registerPoke(at: now)
_ = slowPokeTracker.registerPoke(at: now.addingTimeInterval(2))
check(slowPokeTracker.registerPoke(at: now.addingTimeInterval(4)).mood == .annoyed, "slow pokes never add up to dizzy")

// MARK: - Gaze

let faceCenter = CGPoint(x: 500, y: 900)
let lookRight = WispCompanionGaze.pupilOffset(faceCenter: faceCenter, cursorLocation: CGPoint(x: 1500, y: 900))
check(abs(lookRight.dx - 1) < 0.001 && abs(lookRight.dy) < 0.001, "a far cursor to the right → eyes fully right")
let lookDown = WispCompanionGaze.pupilOffset(faceCenter: faceCenter, cursorLocation: CGPoint(x: 500, y: 100))
check(abs(lookDown.dy - 1) < 0.001, "a cursor lower on screen (smaller y) → eyes look down")
let lookNear = WispCompanionGaze.pupilOffset(faceCenter: faceCenter, cursorLocation: CGPoint(x: 555, y: 900))
check(lookNear.dx > 0.2 && lookNear.dx < 0.3, "a nearby cursor deflects proportionally")
let lookOnFace = WispCompanionGaze.pupilOffset(faceCenter: faceCenter, cursorLocation: faceCenter)
check(lookOnFace.dx == 0 && lookOnFace.dy == 0, "a cursor on the face → looking straight on")

// MARK: - Blinking

let blinkSamples = stride(from: 0.0, to: 40.0, by: 0.01).map { WispCompanionBlink.eyeOpenness(at: $0) }
let shutSampleCount = blinkSamples.filter { $0 < 0.2 }.count
check(blinkSamples.allSatisfy { $0 >= 0 && $0 <= 1 }, "openness stays between 0 and 1")
check(shutSampleCount > 0, "it does blink")
check(Double(shutSampleCount) / Double(blinkSamples.count) < 0.02, "but its eyes are open almost all the time")

print(failureCount == 0
    ? "Wisp companion: all \(checkCount) checks passed"
    : "Wisp companion: \(failureCount) of \(checkCount) checks FAILED")
exit(failureCount == 0 ? 0 : 1)
