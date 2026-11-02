# OpenBot → Wisp Buddies: research and plan

Researched 2026-11-01 from the local checkout at `~/Downloads/openbot` (README, `docs/ARCHITECTURE.md`,
`docs/architecture/*.md`, `src/backend/agent/`). Nothing here is copied from OpenBot's source.

## What OpenBot is

OpenBot (Synthetify Labs / nightly-labs) is a "local-first desktop workspace for persistent AI
teammates". Each **agent** is a long-lived identity — name, title, instructions, avatar, its own
workspace folder, memories, routines — backed by an **external coding-agent CLI session**: the Codex
App Server, Claude Code, or an ACP agent (Grok, Gemini, Cursor, Cline, OpenCode, custom
OpenAI-compatible endpoints, local Ollama/LM Studio). OpenBot doesn't run its own model loop; it
orchestrates those CLIs and gives them extra `openbot.*` tools.

**Stack and size:** Bun workspace, Electron + React (desktop), Effect-TS services over SQLite with an
event log and projections, a React Native phone app, Cloudflare Workers (accounts, billing), a
self-hosted "Signal" relay, and Slack/Discord/Telegram bots. About **860,000 lines** of
non-test TypeScript (backend 115k, main 96k, renderer 133k, mobile 104k, shared packages 339k).

**Safety model:** agents run with `danger-full-access` and `approvalPolicy: never` once you've given
consent at first launch. They read and write files, run commands, use the network and drive the
browser, with no confirmation for each action.

**License:** PolyForm **Noncommercial** 1.0.0, with Required Notices (copyright Synthetify Labs;
commercial licence via licenses@openbot.run). Wisp is **MIT**.

### Feature inventory

| Area | What OpenBot does |
|---|---|
| Agents | Persistent teammates. You create them by asking (`create_agent`, `update_profile`) or from templates. Each has its own provider, model, effort, backup models with failover, an avatar, notifications, hide/restore, import, and transfer between instances. |
| Execution | One provider session per conversation. Context fill is monitored and the session compacts at 80%. When a provider rotates or switches, the new session gets a handoff of the history. |
| Side threads ("tasks") | Up to 50 open, at most 2 running at once per agent (`taskLimit`). The agent can start one itself (`start_task`). Threads can be archived, renamed and deleted with undo, and each has its own queue. |
| Mailbox | A persistent FIFO for each agent and lane, safe across crashes. Pause/resume/cancel, plus a **steer** mode that injects a message into the running turn. Hold reasons are shown (task-limit, usage-limit, busy…). |
| Agent-to-agent | `send_message`/replies/reactions/files, `list_agents` (status, queue, activity), `interrupt_agent`. When a request goes to several agents, the answers are gathered into one turn. A delegation policy says when to delegate and how to report a blocker (Status/Result/Evidence/Unblock). |
| Channels | Group chats with a lead. Routing is deterministic first (`@Name`, `@everyone`, reply-to, sole open task) and only then a routing call to the lead's model. Each member answers in its own reply. Supports continue/resume, reassign, archive/restore. |
| Memory | Per-agent memories (essential + searchable), plus a **background memory review** every N turns that emits add/update/forget as JSON. It's checked against user-owned memories. |
| Routines & flows | Scheduled, webhook and calendar-feed routines, quiet runs, failure reporting, and routine flows that pass one agent's answer on to another. |
| Workflows | A canvas graph: trigger, agent, model, condition, approval and output nodes, with loops, versions and webhook triggers. |
| Browser | An embedded Chromium per agent/thread, driven over CDP. Browser profiles, and a sign-in **takeover** request to the user. |
| Computer use | `cua-driver` started as a child process and given to every provider. |
| Tools | MCP servers (agents can add/test them with approval), a plugin marketplace and a skill library. |
| Everything else | Team servers, accounts, a hosted/self-hosted server, Docker, Windows/Linux, the phone app, Live Activities, messaging bots, a local scripts HTTP API, analytics. |

## What Wisp already has

Wisp has already re-implemented the shape of much of this, as noted in CLAUDE.md: the messenger
layout and icon rail, the sidebar groups and badges, side threads, the message line (FIFO, pause,
cancel), group chats with deterministic `@Name` routing and `[HANDOFF:]`, `ask_buddy` delegation,
templates, workflows, run trace, the Graphite theme, per-buddy model/tools/apps/memory/files,
cua-driver, MCP + Composio, and schedules/automations.

## What's still missing

1. **CLI-backed buddies.** A buddy could run on its own Claude Code / Codex / ACP session with a
   workspace folder. Wisp today runs every buddy through its own `AgentTurnRunner`, with
   `ClaudeSubscriptionProvider` as a one-shot CLI with all tools turned off.
2. Persistent provider sessions per thread, with context monitoring, compaction and a history
   handoff.
3. Background memory review (every N turns → add/update/forget, never touching user-owned notes).
4. Steer mode (inject a message into a running turn), and parallel side threads per buddy (`taskLimit`).
5. Buddy-facing tools: `list_buddies` (status/queue), `interrupt_buddy`, `start_thread`, and
   `create_buddy`/`update_buddy` by asking. A multi-recipient request whose answers are gathered into one turn.
6. Backup models with failover on usage limits or provider errors.
7. Hidden buddies refusing new messages and pausing their routines (Wisp hides from the list only).
8. Blocker reporting (Status / Result / Evidence / Unblock) in delegated answers.
9. Routine flows (answer → next buddy) as a lighter form of workflows, and webhook triggers.

Out of scope for a menu-bar companion: Windows/Linux, Docker, hosted servers, team accounts, billing,
the phone app, Slack/Discord/Telegram bots, the embedded Chromium (Wisp drives the user's own
Chrome/Safari), and analytics (Wisp has none, on purpose).

## Constraints that shape the plan

- **License.** A line-by-line Swift translation of OpenBot's code is a derivative work. It would
  have to stay under PolyForm Noncommercial and carry its notices, and it couldn't ship in MIT Wisp.
  Re-implementing the *behaviour* from its docs, in Wisp's own code, is how Wisp has worked so far.
  This plan follows that approach.
- **Safety.** OpenBot's full-access, never-ask model conflicts with Wisp's confirmation floor
  (`ToolCallSafety`, always-ask tools, unattended runs that never prompt). Wisp keeps its floor. A
  CLI-backed buddy would run in a sandboxed workspace folder with the CLI's own approval mode on,
  or with Wisp's tools only, never with `danger-full-access`.
- **Local-first.** Codex and Claude Code are off-machine. The default buddy stays on the local model,
  and a CLI-backed buddy is opt-in per buddy and labelled "leaves your Mac".
- **Label.** The UI keeps "Buddies" everywhere. Internal types keep their `Buddy*` names.

## Proposed phases

Each phase is its own `feature/…` branch with a `Tests/` suite for the pure parts.

1. **Buddy runtime — built on `feature/buddy-runtime`.** Shipped as `BuddyRuntimeKind` on `WispBuddy` (Wisp's loop, or
   its own Claude Code session per conversation) rather than a protocol: the agent loop already abstracts over
   `ModelProvider`, so the session backend is a provider (`ClaudeCodeSessionProvider`) and nothing else had to change.
   Claude Code's own tools stay off in this phase; tools still run through Wisp's registry and cards. Codex app-server and
   letting the CLI use its own file tools inside the workspace are left for a later phase. Original plan:
   **Buddy runtime protocol.** Add a `BuddyRuntime` abstraction with two backends. The first is
   `WispLoopRuntime`, which is today's `AgentTurnRunner` path with no behaviour change. The second
   is `CLISessionRuntime`, which keeps a Claude Code (stream-json, persistent `--resume` session) or
   Codex app-server session per buddy thread, inside `~/Library/Application Support/Wisp/buddy-workspaces/<id>/`.
   Its tool calls are routed through Wisp's `ToolPermissionBroker`.
2. **Session lifecycle — built.** Claude Code compacts its own sessions, so Wisp tracks how full each one is (shown
   in the buddy's settings) and only starts over with a handoff when a session is still ≥95% full or overflows.
   Crash recovery needed nothing new: session ids persist, and a gone session is replaced. Original plan:
   **Session lifecycle.** Context-fill tracking, compaction (native where the CLI supports it,
   otherwise a handoff to a fresh session), and recovery after a crash or relaunch.
3. **Queue upgrades.** Steer mode, parallel threads per buddy (default 2), and visible hold reasons.
4. **Buddy tools.** `list_buddies`, `interrupt_buddy`, `start_thread`, `create_buddy`/`update_buddy`
   (each creation asks first), multi-recipient asks with gathered answers, and the blocker report format.
5. **Memory review.** Background add/update/forget over `BuddyMemoryStore`, local model by default,
   `ModelAccessGate` background priority, with a setting (10/20/40/off).
6. **Resilience.** Backup models and failover, plus hidden buddies that pause their routines and refuse new messages.
7. **Routine flows.** A buddy's scheduled answer is handed to the next buddy, reusing the workflow engine.
