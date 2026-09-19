# Wisp MCP Marketplace — Architecture

Status: **Phase 1 complete** (remote Streamable HTTP transport + `mcp.json` superset landed &
building). Next: Phase 2 (marketplace UI + curated registry). See [Phasing](#7-phasing) and
[Change log](#10-change-log).

A browse-install-connect marketplace for MCP servers inside Wisp's dashboard, spanning a
curated public MCP registry **and** Composio's hosted, managed-OAuth toolkits — built on top
of Wisp's existing MCP client without breaking the local-first defaults.

---

## 1. Goals

- Let a user discover MCP servers (curated stdio/remote registry + Composio toolkits) and
  install/connect them from a dashboard tab, without hand-editing `~/.wisp/mcp.json`.
- Support **remote (Streamable HTTP) MCP servers**, which Composio requires — Wisp is stdio-only today.
- Use **Composio's managed OAuth** so Wisp never handles third-party credentials.
- Keep the app **local-first**: cloud/off-machine tools are opt-in, gated, and labeled.
- Respect the **small local model's tool budget** — installing many servers must not flood the prompt.

## 2. Constraints that shape the design

| Constraint | Source | Consequence |
|---|---|---|
| Local-first; cloud opt-in and **labeled** | `CLAUDE.md` | Composio is never a default; every off-machine tool is gated + badged |
| Small model degrades past **~8 tools** | `MCPManager.maximumExposedTools` | *Installed* must be decoupled from *exposed*; a budget/router layer is required |
| Client is **stdio only** | `MCPClient.swift` | A remote (Streamable HTTP) transport is the largest new piece |
| Config is Claude-Desktop-shaped `~/.wisp/mcp.json` | `MCPManager.loadConfigurations()` | Persistence must stay backward-compatible while gaining remote/auth fields |
| Secrets never in files/logs/UserDefaults | `ProviderKeychainStore` pattern | Composio `x-api-key` + tokens live in the login Keychain |
| MCP tools can't self-declare mutation | `MCPManager.registerTool()` | `requiresConfirmation: true` stays; cloud tools also show an off-machine warning |

## 3. Layered architecture

```
┌──────────────────────────────────────────────────────────────┐
│  UI            MarketplaceTab (browse / install / connect)     │
│                + budget meter + per-tool enable                │
├──────────────────────────────────────────────────────────────┤
│  Catalog       MCPCatalogProvider (protocol)                   │
│                ├─ CuratedRegistryCatalogProvider (bundled+CDN) │
│                └─ ComposioCatalogProvider (toolkits via API)   │
├──────────────────────────────────────────────────────────────┤
│  Install /     InstalledMCPServerStore  ← source of truth      │
│  Persistence   (mcp.json superset + Keychain for secrets)      │
├──────────────────────────────────────────────────────────────┤
│  Auth          ComposioClient (mgmt API: provision, connect,   │
│                poll, mint user-scoped URL)  +  Keychain store  │
├──────────────────────────────────────────────────────────────┤
│  Runtime       MCPManager  →  MCPServerConnection              │
│                └─ MCPTransport (protocol)                      │
│                   ├─ StdioMCPTransport   (extracted, existing) │
│                   └─ StreamableHTTPMCPTransport   (NEW)        │
├──────────────────────────────────────────────────────────────┤
│  Exposure      MCPToolGateway → AgentToolRegistry             │
│                (budget + per-turn relevance selection)         │
└──────────────────────────────────────────────────────────────┘
```

## 4. Load-bearing decisions

### 4a. Extract a transport protocol; keep stdio behavior identical
`MCPServerConnection` currently bundles JSON-RPC framing (`pendingRequests`, id issuing, the
25s timeout, error routing) *with* `Process`/pipe handling. The JSON-RPC logic is
transport-agnostic. Split into:

- `MCPTransport` protocol — `start()`, `send(_ messageJSON:)`, `incomingMessages()`,
  `recentDiagnostics()`, `close()`. The transport owns only byte transport + framing.
- `MCPServerConnection` keeps **all** JSON-RPC dispatch and the handshake, unchanged, talking
  to a `MCPTransport`.
- `StdioMCPTransport` — today's `Process`/pipe/`LoginShellEnvironment` code, moved verbatim,
  frames outbound messages as NDJSON (trailing `\n`).
- `StreamableHTTPMCPTransport` — POSTs JSON-RPC to a URL, reads the SSE/chunked response
  stream, carries `x-api-key`/`Authorization` and the MCP session id header.

Pure refactor with **no behavior change** — landed and verified first (Phase 0).

### 4b. `installed` ≠ `exposed to the model`
A marketplace makes 10 servers × 15 tools trivially installable, which would wreck the local
model's tool choice. So:

- `InstalledMCPServerStore` tracks everything installed/connected.
- `MCPToolGateway` sits between connections and `AgentToolRegistry` and enforces the budget.
  - Phase 2: user explicitly enables tools per server, with a live **budget meter**
    ("6 / 8 tool slots used").
  - Phase 4: **per-turn relevance selection** — keep the budget but choose *which* tools to
    expose from the transcript/query (Composio's `SEARCH_TOOLS`/router pattern), so a large
    library stays usable without flooding the prompt.

### 4c. Persistence: a superset of `mcp.json`, secrets in Keychain
Keep reading existing `command`-based entries so nothing breaks. Add optional fields:

```jsonc
"github": {
  "transport": "streamableHttp",         // default "stdio" when absent
  "url": "https://mcp.composio.dev/…",   // remote only
  "source": "composio",                  // "curated" | "custom" | "composio"
  "catalogId": "composio/github",
  "composio": { "serverId": "...", "toolkit": "github", "connectedAccountId": "..." },
  "enabled": true,
  "allowedTools": ["create_issue", "search_repos"]
}
```

The `x-api-key` and any bearer tokens are **never** written here — they live in a
`ComposioKeychainStore` (mirroring `ProviderKeychainStore`). The user-scoped URL may contain a
user id but no secret; still treated as sensitive (never logged).

### 4d. Composio managed-OAuth lifecycle (a small state machine)
```
notConfigured → (user pastes Composio API key → Keychain)
  → catalog browse (ComposioCatalogProvider lists toolkits)
  → install toolkit  → ComposioClient.provisionServer(toolkit)   // server config
  → connect account  → ComposioClient.initiateConnection()       // returns OAuth URL
                     → open browser (ASWebAuthenticationSession)
                     → poll ComposioClient.connectionStatus() until ACTIVE
  → mint user-scoped MCP URL (base + user id) → store
  → runtime: StreamableHTTPMCPTransport with x-api-key + URL
  → handle "not connected" / expired → reconnect prompt in Marketplace
```
Wisp never touches third-party credentials; Composio holds them.
`ModelDeployment.sendsDataOffThisMachine = true` for every Composio-backed tool, which drives
the existing local-only gates and the off-machine badge. As of March 2026, Composio rejects
MCP calls without a valid `x-api-key` (401), so the header is mandatory on every remote call.

## 5. Data model (target)

- `MCPTransportKind`: `.stdio` | `.streamableHttp`
- `MCPServerSource`: `.curated` | `.custom` | `.composio`
- `MCPServerConfiguration` (extended): `transport`, `url?`, `source`, `catalogId?`, composio metadata
- `MCPCatalogEntry`: `id`, `name`, `summary`, `publisher`, `kind`, `transport`, `iconSymbol`,
  `categories`, `authKind`, `homepage`
- `ComposioConnectionState`: `.disconnected` | `.connecting` | `.active` | `.expired(reason)`

## 6. New / changed files

| File | New? | Purpose |
|---|---|---|
| `MCPTransport.swift` | new | Transport protocol |
| `MCPStdioTransport.swift` | new (extracted) | Current stdio logic + `LoginShellEnvironment` |
| `MCPStreamableHTTPTransport.swift` | new | Remote HTTP MCP transport (Composio + custom remote) |
| `MCPClient.swift` | change | `MCPServerConnection` becomes transport-agnostic; config gains transport/url/source |
| `InstalledMCPServerStore.swift` | new | Source of truth for installed servers; `mcp.json` superset |
| `MCPCatalog.swift` | new | `MCPCatalogEntry` model + categories |
| `MCPCatalogProvider.swift` | new | Protocol + curated + Composio catalog providers |
| `curated-mcp-registry.json` | new (bundle) | Curated popular stdio/remote MCP servers |
| `ComposioClient.swift` | new | Composio mgmt API: provision, connect, poll, mint URL |
| `ComposioKeychainStore.swift` | new | `x-api-key` in login Keychain |
| `ComposioAccountStore.swift` | new | Connected-account + connection-state observable |
| `MCPToolGateway.swift` | new | Budget + (later) per-turn tool selection |
| `MarketplaceTab.swift` | new | Dashboard marketplace UI (adaptive, DS/Wisp tokens) |
| `MCPManager.swift` | change | Drive from `InstalledMCPServerStore`; connect via transport; route through gateway |
| `DashboardView.swift` | change | Add Marketplace to the sidebar |
| `CLAUDE.md` | change | Document the new architecture (self-update rule) |

## 7. Phasing

Each phase is independently shippable and verifiable.

- **Phase 0 — Transport refactor.** Extract `MCPTransport`; move stdio out. No new features;
  existing servers behave identically. *Verify: existing `~/.wisp/mcp.json` still connects.*
- **Phase 1 — Remote transport + custom remote install. (done, building)**
  `MCPStreamableHTTPTransport` + `mcp.json` superset (`url`/`headers`) + starter-config
  example. Manual install path = adding a `url` entry to `~/.wisp/mcp.json`; the dashboard
  form lands with the Marketplace UI in Phase 2. *Verify against a public remote MCP server
  before Composio.*
- **Phase 2 — Marketplace UI + curated registry + budget meter.** Browse/install stdio &
  remote; installed ≠ exposed.
- **Phase 3 — Composio.** API key, toolkit catalog, managed-OAuth connect flow, user-scoped
  URL, off-machine labeling.
- **Phase 4 — Tool router.** Per-turn relevance selection so a big library fits the budget.

## 8. Transport protocol (Phase 0 contract)

```
protocol MCPTransport: Sendable {
    func start() async throws                         // spawn / connect
    func send(_ messageJSON: Data) async throws       // transport frames it
    func incomingMessages() async -> AsyncStream<String>   // one JSON object per element
    func recentDiagnostics() async -> [String]        // stderr / connection errors
    func close() async
}
```
`MCPServerConnection` consumes exactly one `incomingMessages()` stream and owns id issuing,
`pendingRequests`, the 25s timeout, and the `initialize` / `notifications/initialized` /
`tools/list` handshake.

## 9. Open questions

1. Composio account: existing API key/org? Per-user URL keyed to a Wisp-generated stable id
   (single-user app → one entity)?
2. Curated registry hosting: bundle static JSON only, or also fetch updates from a controlled
   URL (needs the live-data gate)?
3. Tool router: defer to Phase 4 (recommended) — Phases 0–3 already yield a working marketplace.

## 10. Change log

- **Phase 1 (done, verified building):** Added `MCPStreamableHTTPTransport.swift` — remote MCP
  over Streamable HTTP (one JSON-RPC message per POST; parses both `application/json` and
  `text/event-stream` replies into the shared message stream; carries `Mcp-Session-Id`,
  `MCP-Protocol-Version`, and per-server auth headers; 401/404 surfaced as diagnostics).
  `MCPServerConfiguration` gained `transport`/`url`/`headers` with a remote initializer;
  `makeTransport(for:)` branches on `url`; `MCPManager.loadConfigurations` parses `url`/`headers`
  entries and the starter config shows a remote example. Existing stdio entries unchanged.
- **Phase 0 (done, verified building):** Added `MCPTransport.swift` (protocol) and
  `MCPStdioTransport.swift` (`LoginShellEnvironment` + the child-process/stdout/stderr code
  moved out of `MCPClient.swift`). `MCPServerConnection` now owns only JSON-RPC framing +
  handshake and talks to a `MCPTransport`; `makeTransport(for:)` returns stdio for now.
  `disconnect()` and `recentErrorOutput` became `async` (call sites already `await`).
  Behavior-preserving; headless Xcode build succeeds.
</content>
</invoke>
