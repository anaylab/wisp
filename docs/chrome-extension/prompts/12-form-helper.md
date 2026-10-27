# Phase 12: Form helper (fill from what Wisp knows about you, behind a card)

You're implementing phase 12 of the Wisp Chrome extension roadmap in `/Users/m3pro/Downloads/clicky`.
First read `CLAUDE.md`, `docs/chrome-extension/README.md` and `docs/chrome-extension/contracts.md`.
Phase 03 is merged. Branch `feature/chrome-ext-12-form-helper` from `feature/chrome-extension`, and
open a PR back into it. This is the most safety-sensitive phase. Read contracts §6 twice.

## Goal

"Fill this form" on a sign-up, application or contact form: Wisp reads the form's fields, proposes
values from the brain's `me` page / Me contact card (name, email, school, address lines, phone, short
bio), and shows them in an editable confirmation card. Only after Allow does it type them in. It
**never submits**: the user presses the page's own submit button.

## Hard rules

- Never fill or read: passwords, payment/card fields, government IDs (SSN, passport, licence), one-time
  codes, security questions, or any field whose label matches those, even if the brain holds such a
  value. The content script refuses these fields itself, and the Swift planner refuses them again.
- Never submit, never click a button, never press Enter in a field.
- Values come only from the user's own sources (the `me` page, Me card), never from the page and never
  invented. A field with no known value stays empty and is listed as "you'll fill this".
- A cloud model may be used to *map* field labels to known keys, sending labels only, never values.
  The local model or deterministic matching is preferred. Values are inserted by Swift, not written by
  the model.

## Extension

`handlers/form-helper.js`:
- `describeForm({tabId, formElementId?})` returns fields: id, label, type, autocomplete,
  required, options, current value present (bool).
- `fillFormFields({tabId, values:[{elementId, value}]})` uses phase 03's React-safe setters and
  refuses forbidden fields.

Tests cover the refusal list.

## Wisp

1. `ChromeExtension/FormFillPlanner.swift` (pure):
   - autocomplete-token mapping first (`given-name`, `email`, `address-line1`, …), then label word
     matching; the model mapping only for leftovers;
   - the refusal list;
   - the proposal model.
2. A confirmation card via `ToolConfirmationCardBuilder` + `EditableConfirmationFields`: one editable
   row per proposed field, "won't fill" rows for refused ones, and a footer "Wisp won't submit". It's
   always asked, so add `fill_form` to `ToolCallSafety.alwaysAskBareToolNames`.
3. Agent tool `fill_form` (`.browser`) and a phrase route ("fill this form", "fill in my details").
4. Suites: `Tests/ChromeExtFormHelper/` for the mapping, refusals (including adversarial labels like
   "Email (or your password)"), and edited values winning.

## Manual checks

A test sign-up form on a local fixture page (serve `chrome-extension/tests/fixtures/form.html` from
localhost) and one real contact form, stopping before submit.
