# Workflows

The canvas, the graph rules, saving and the runner are built (see CLAUDE.md, "Workflows"). Not built: image/file steps, webhook and message triggers, per-run history, retrying a failed step, and an LLM-written workflow. Notes from the installed OpenBot app (Oct 31 2026) so the work starts from what exists.

## What OpenBot has
- A **Workflows** tab on the icon rail (also pinnable from the "…" menu beside Routines, Tasks, Schedule, Usage).
- An empty **canvas** (dotted grid, "Start with a trigger", **Add trigger**), a bottom toolbar (select, pan, pen, note, shape, text, search, **Add node**), zoom controls (− 100% + / fit / map), and a title ("Untitled workflow") in the top bar.
- Source to read first: `packages/ui/src/features/workflows/` (`workflows.css`, `workflow-nodes.css`) and `src/renderer/src/features/routine-flows/` (`RoutineFlowsCanvas.tsx`).

## What Wisp already has that a workflow can reuse
- **Automations**: Trigger → Source → Action → Output → Notify (`Automations/`), with a draft card, templates, run history and the unattended-safe tool policy. A workflow is the multi-step, branching version of this.
- **Buddies** as the actors for a step, **group chats** and `ask_buddy` for hand-offs, `BuddyRunRequest` for running one step.
- Learned shortcuts (`LearnedShortcuts/`) for replaying recorded tool calls without a model.

## Suggested first cut
1. A `Workflow` model: nodes (trigger, buddy step, tool step, condition, output) and edges; pure, Codable, tested like `Automation`.
2. Run it by walking the graph, one buddy step per `BuddyGroupEngine`-style assignment; never auto-approve outward actions (same floor as automations).
3. A canvas page (SwiftUI `Canvas` + drag) — read-only first, then editable.
4. Keep it local: no hosted publish, same privacy rules as the rest of Wisp.
