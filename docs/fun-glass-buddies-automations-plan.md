# Fun glass look, buddies back, easy automations

Goal: Wisp should feel playful, look like liquid glass, bring the buddies back as the
faces of everything it does, and let anyone set up an automation in one sentence. It must stay
convenient: few places, few taps, no explaining paragraphs.

## Inspiration, and what we take from it

| Source | Take | Leave |
|---|---|---|
| Grok Automations / Tasks | Describe the job once in plain words, pick a schedule (once, daily, weekdays, weekly, monthly), results land in a run history, you choose how to be notified. Each run is a fresh request with the saved instruction and current data. | Subscription gating, email-trigger-only focus. |
| Grok companions (Ani, Rudi) | Characters with a distinct personality, a moving avatar and a voice that shows emotion. | The romantic/roleplay angle. Personalities here are work styles (coach, chill, hype, deadpan, teacher). |
| Playful buddies | Named, coloured buddies that own one job, shown in the notch, with a lively cloud character. | The cursor companion (rejected earlier, do not bring back). |

Sources are third-party write-ups, not vendor docs, so treat the Grok details as the general shape
rather than exact behaviour.

## Decisions to confirm before building

1. **Island colour.** Earlier you chose a solid black island that blends into the notch. Default
   stays black. Themes tint the window, buddies and the opt-in glass island. A new "Tint the island
   with my theme" switch (off by default) lets the notch itself go colourful.
2. **Fun vs restrained.** The buddy characters were deliberately calm (no glow, sparkle, confetti).
   This plan allows small celebrations (a bounce and a soft burst when you finish a checklist) behind
   a "Playful" switch that is on by default and honours Reduce Motion.
3. **Buddies stay first-class.** The Advanced switch stops hiding characters; it only hides
   delegation, per-buddy models and sharing.

## 1. Themes with real liquid glass (package T)

- `WispTheme`: id, name, accent, second accent, AI-activity accent, backdrop gradient stops, buddy
  palette, glass tint strength. Six to start: Sage (current default), Candy, Sunset, Mint, Berry
  Night, Mono. Stored in a `WispThemeStore` (UserDefaults), picked in Settings → General → Appearance
  with live preview swatches.
- Tokens: `WispColor` accent/lavender/gradient read the current theme through dynamic `NSColor`
  providers, so every existing call site reskins without edits. No new hardcoded hex outside the
  theme definitions.
- Glass: the window gets a soft theme-coloured backdrop (blurred gradient blobs, slow drift, paused
  when the window is inactive or Reduce Motion is on). Cards, the top bar and pills move to
  `.glassEffect` inside `GlassEffectContainer` so they refract the backdrop. Pills keep the lit-edge
  look. Text contrast is checked for every theme in light and dark.
- Notch: black by default, as chosen. With "Tint the island with my theme" on, the surface and rim
  use the theme; the Liquid Glass island option picks up the tint too.

## 2. Buddies back, with personality (package B)

- Nav: Today, Chat, Buddies, Settings. Jobs/automations live inside Buddies (see 3) and as a tile on
  Today. Routines, History and the rest stay under Settings as they are now.
- `BuddyPersonality` presets: Coach, Chill, Hype, Deadpan, Teacher. Each sets the persona line,
  reply length and tone, a Kokoro voice and speaking speed, and how the character reacts (mood
  mapping already exists in `BuddyMoodPolicy`). Chosen when summoning, changeable any time.
- Built-in starter buddies so the first run is not an empty rail: a Planner (Canvas + checklist),
  a Briefer (morning brief), a Focus buddy (study blocks). Each starts with its automations
  ready to switch on.
- Buddies show in the notch: the working buddy's character sits in the left flank while its
  automation runs and bounces when it finishes (the "Playful" switch). The hover panel's NEW list
  shows the buddy's face next to each result.
- Playful touches: checklist streak count, a soft completion burst, greeting by the day's buddy.

## 3. Automations that are easy to set up (package A)

One model replaces three overlapping ones (Routines, buddy jobs, Jobs):

`Automation` = **Trigger → Source → Action → Output → Notify**, owned by a buddy.

- Triggers: schedule (once, daily, weekdays, weekly, monthly, with time and zone), event (new Canvas
  item, meeting starting in N minutes, text appears on screen using the existing watchers, file
  dropped in a folder), or manual (button, notch chip, routine digit shortcut).
- Outputs: notch card, Reminders checklist, Calendar block (always asks), notification, a message in
  the buddy's thread, a spoken line.
- Setup, three ways, all ending on the same editable draft card:
  1. **Say it:** one text box, "every weekday at 8 tell me what's due today". A deterministic parser
     (`AutomationDraftParser`, built on `BuddySchedule.inferred` and the routine blank syntax) fills
     the card; only when it is unsure does the model help, and it only fills the card, never runs
     anything.
  2. **Pick a template:** gallery of Morning brief, Canvas deadlines, Daily checklist, Weekly review,
     Meeting prep (10 minutes before), Focus block, Study plan, Screen watch.
  3. **Teach by example:** "Save as automation" on any History answer.
- Draft card: chips for trigger, source, output, buddy and notify, each tappable. **Test run** shows
  the result without saving or writing anything. Save turns it on.
- Run history per automation (last result, time, failures with the reason), a pause switch, and a
  Today tile showing next runs. Failures surface in "Needs you" instead of failing silently.
- Safety: anything outward-facing (sending, calendar writes, posting) still goes through the
  confirmation floor, even when scheduled. A scheduled run never auto-approves.
- Migration: routines become manual-trigger automations, existing buddy jobs become scheduled
  automations on their buddy, Canvas/Today checklist become the Planner's two automations. Data is
  kept; old stores are read once and left in place.

## 4. Convenience (package C)

- Quick add anywhere: the notch composer and ask bar recognise "remind me…", "every…", "when…" and
  open the draft card instead of answering.
- First-run setup, four steps: pick a theme, pick a buddy personality, connect Canvas (optional),
  switch on three templates.
- Menu bar: Ask Wisp, New automation, Pause listening. Nothing else new.

## File ownership (disjoint, so packages can be built in parallel)

| Package | Owns |
|---|---|
| T | `DesignSystem/WispColors.swift`, new `DesignSystem/WispTheme*.swift`, `Components/WispGlass*`, `Components/WispBento.swift`, Settings → Appearance page |
| B | `Buddies/*`, `WispWindow/Buddies/*`, `WispWindow/WispNavigation.swift`, `WispAdvancedFeaturesPreference.swift`, buddy parts of the notch flank |
| A | new `Automations/*`, `WispWindow/AutomationsPage*.swift`, store migration, `BuddyStore` scheduling hook |
| C | `FastCommandRouter` hook, composer routing, first-run flow, menu bar menu |

Cross-package contracts (Swift signatures for `WispTheme`, `Automation`, `AutomationDraft`,
`BuddyPersonality`) are written first by the plan step of the workflow.

## Tests and checks

- Pure suites: `Tests/AutomationDraft` (phrases → drafts, ambiguous → asks, no model needed for the
  common ones), `Tests/AutomationSchedule` (next run, DST, missed runs run once), `Tests/WispTheme`
  (contrast ratio for every theme, light and dark), migration round trip.
- Full compile through `Tests/AgentRuntimeIntegration`, then an Xcode build via `osascript`.
- Visual pass of every theme in the real app (not yet possible headless; done by hand).

## Order of work

1. Contracts, then T, B and A in parallel (disjoint files).
2. C after A lands (it routes into the draft card).
3. Review lenses (correctness, privacy/safety, build), then fixes and a `CLAUDE.md` update.
4. Hand-test every theme and the three setup paths in the app.

## Risks

- Dynamic theme colours touch every screen; contrast must be tested per theme.
- `.glassEffect` over animated backdrops can cost GPU; the backdrop pauses when inactive.
- Merging three stores into one model risks losing data; migration is read-only on the old files.
- The local 3B model is weak at parsing; the deterministic parser carries the common cases.
