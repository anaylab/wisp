# Note cards: annotations as movable windows

Status: phase 1 (spike, validated by hand) and phase 2 (model, placement, lifecycle, cards
replacing live notes) and phase 3 (follow-ups in the card: composer, streaming thread, history) are built.
Left from phase 3: speaking a follow-up into a focused card, and annotation tags in follow-up answers.
Phase 4 (chips, copy, save from a card, pop-out steps) is built; left from it: "Remind me", "Make automation",
and dragging a step out. Phase 5 (spring-in and fade-out motion, Reduce Motion, VoiceOver,
display changes, streaming markdown) is built. Never verified: a second display, and VoiceOver by ear
(only its accessibility tree).

## Why

Today an annotation is a drawing. `ScreenAnnotationLayer` paints boxes, circles and
handwritten notes into a click-through full-screen `Canvas`; the only interaction is
`AnnotationClickRouter` flipping the overlay to accept the mouse while the pointer is over a
note, so a click can open the composer. You can't drag a note, type into it, keep it, or
continue the conversation inside it. Notes also vanish on a timer, on scroll, and on the next
utterance, so they feel disposable.

Goal: when Wisp explains something on screen, the explanation is a small **card** you can
move, keep, and talk to. The shapes (box, circle, highlight, marker) stay as anchors on the
screen; the words move into the card.

## The experience

- A reply with notes becomes **one card per reply** (not one per note, which would clutter),
  placed beside the thing it explains, joined to it by a thin tether line.
- Multi-step working (>= 3 notes, today's "Next ›" stepping) becomes a step list inside the
  card. Numbered pins on the screen mark each step's target; clicking a pin or Next
  highlights that step. Later: drag a step off to tear it into its own card.
- The card has a header you drag, a pin (keep it), collapse, and close. Body: the
  explanation, then a short thread of follow-ups, then a composer ("Ask about this…").
- Follow-ups are about the card's anchor (its region, with the native-resolution close-up,
  exactly like Ask About a Part) and the answer streams into the card, not the notch. Any
  new `[BOX]`/`[CIRCLE]`/`[POINT]` tags in the answer attach to that card as new anchors.
- Action chips under the answer: Simpler, Give an example, Quiz me, Copy, Save worked
  solution, Remind me, Make automation. Chips are deterministic prompts or existing
  features, not new model machinery.
- Voice still works: hold the Talk chord with a card focused and the question goes to it.

## Key design decision: each card is its own window

Do not make cards views inside the full-screen overlay. That panel must stay
`ignoresMouseEvents = true` or the desktop becomes unclickable, and a text field needs
keyboard focus plus real drag handling.

Instead: one small `NoteCardPanel` per card (borderless, non-activating `NSPanel`, floating
level, all Spaces, hosting SwiftUI through `NSHostingView`). Everything outside the card
stays click-through for free. It becomes key only while the composer is focused, reusing the
`NotchPanel.allowsBecomingKey` / `OverlayWindowManager.setAllowsKeyboardFocus` precedent
(non-activating, so typing works while the user's app stays active; order out/in on release
to hand focus back). The overlay keeps drawing shapes and now also the **tether**, from the
card's published frame to the anchor, so dragging a card redraws the line live.

Surface: dark glass pinned to `.dark` like the notch and overlay (they sit over arbitrary
content). Tokens from `WispColor.OnGlass` / `Island`, no hardcoded hex.

## Model

Pure, in `NoteCards/NoteCard.swift`, tested by `Tests/NoteCards`:

- `NoteCard`: id, displayFrame, anchor annotation ids, steps (text + anchor), user offset,
  state (floating / pinned / collapsed / loading), thread of `NoteCardMessage`.
- `NoteCardPlacement`: pick a frame beside the anchor that stays on screen, clear of the
  anchored rect and other cards (reuse the idea in `AnnotationNoteLayout`).
- `NoteCardLifecycle`: which cards survive what (below).
- Grouping: `ScreenAnnotation`s with `.note` style in one reply fold into one card; shapes
  stay annotations. Parsing of tags does not change.

## Lifecycle (the big behaviour change)

| Event | Today (notes) | Cards |
|---|---|---|
| Dwell timer (120s for notes) | notes fade | untouched cards fade; a card that was dragged, pinned, focused or replied to stays |
| Scroll in another app | all drawings dropped | anchors and tether dropped, card stays and shows "detached" (it is no longer pointing at anything) |
| New utterance | clears drawings | clears untouched cards only; pinned/engaged cards stay |
| Esc | clears drawings | closes unpinned cards; Esc inside a focused composer just leaves it |
| Many cards | n/a | cap at 4; evict the oldest unpinned |

Cards are in memory only, never persisted: they contain screen-derived text. Follow-up turns
are ordinary turns, so History records them as usual.

## What changes in the code

- `ScreenAnnotationLayer`: stop drawing `.note` and the Next pill live; draw numbered pins
  and tethers. Keep the handwritten rendering for `isForExport` until the export is moved.
- `AnnotationClickRouter` / `AnnotationClickTarget`: notes and the Next button leave the hit
  test; boxes and circles stay clickable. This removes the hover/cursor hack for notes.
- `CompanionManager`: `applyAnnotations` (~3666) builds a card from the notes;
  `visibleNoteLimit` and `stepNoteReveal` move into the card's step state;
  `clearScreenAnnotations`, `dropAnnotationsAfterContentScrolled`, `dropDrawingsAfterEscape`
  and `clearScreenAnnotationsForNewUtterance` consult `NoteCardLifecycle`.
- New turn routing: `answerDestination` (`.notch` default, `.noteCard(id)`) so a follow-up
  streams into the card and skips the notch reply, SAY, and annotation clearing.
- Screenshots and OCR for follow-ups must exclude the card windows (capture already excludes
  Wisp's windows; verify the card panels are in that set, or the model reads its own card).
- New files under `leanring-buddy/NoteCards/`: `NoteCard.swift` (pure),
  `NoteCardPanelController.swift`, `NoteCardView.swift`, `NoteCardTetherLayer.swift`.
- Save Worked Solution: composite the card's steps over the capture instead of handwritten
  notes (one drawing path, as today).

## Phases

1. **Spike (go/no-go).** One hard-coded card: drag, tether, composer with key focus. Check
   click-through elsewhere, multiple displays, Spaces, full-screen apps, and that typing
   never steals the user's app focus. This is where the design could fail, so do it first.
2. **Model and placement.** `NoteCard`, grouping, placement, lifecycle, `Tests/NoteCards`.
   Replace live note drawing with card + pins + tether.
3. **Follow-ups.** `answerDestination`, streaming into the thread, anchor-region close-up,
   new tags attaching to the card, voice into a focused card.
4. **Actions and steps.** Chips, step list with pin links, Save Worked Solution from a card,
   tear-off steps.
5. **Polish.** Spring motion (honours Reduce Motion), VoiceOver (card is a labelled group,
   appearance announced like the confirmation card), light edge cases, `CLAUDE.md` update.

## Risks

- Focus: a non-activating panel that sometimes takes the keyboard is the delicate part.
- Clutter on busy screens; mitigated by one card per reply, the cap, and collapse.
- The default local 3B model writes weak explanations and weaker follow-ups. The card is
  best with Claude (subscription or key); local still works, just plainer.
- Annotation accuracy is unchanged: a card anchored to a wrong box is still wrong.

## Open decisions (recommended default first)

1. One card per reply with numbered pins, or one card per note? Recommend per reply.
2. Keep the Bradley Hand look anywhere? Recommend clean type in the card; handwriting only
   as an optional "sketch" style for math pins, or drop it.
3. Should pinned cards survive app restart? Recommend no (privacy, stale anchors).
4. Add a card for non-annotated answers too (every reply)? Recommend no for now: cards are
   for answers that point at something on screen.
