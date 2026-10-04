# WraithTerm — HARNESS_OMP (P2.1)

Recon of the **real installed omp** (no synthesis): version, lifecycle
event surface, settings format, extension location. Drives the Tier 1
vs Tier 3 decision per D6 state (D6).

## 1. Environment (measured 2026-10-05)

| Property | Value |
|---|---|
| `omp --version` | `omp/18.4.4` |
| Binary | `~/.local/bin/omp` (user-local install) |
| Agent home | `~/.omp/agent/` (`config.yml`, `extensions/`, `history.db`, `models.yml`, `mcp.json`, …) |
| Extension dir | `~/.omp/agent/extensions/*.ts` (auto-discovered; `--no-extensions` disables, `-e/--extension` adds explicit files, `--hook` loads a hook file) |
| Settings | `~/.omp/agent/config.yml` (YAML, **not** `settings.json` — no `settings.json` exists anywhere under `~/.omp` or `~/.config`) |
| JS runtime for extensions | `bun` 1.4.2 present (extension code is plain TS with `node:` imports) |

## 2. Extension API shape (from shipped extensions)

An extension is a TS module with a default-export function receiving
the `pi` object:

```ts
export default function (pi) {
  pi.on("agent_start", (event, ctx) => { … });
  pi.on("tool_approval_requested", (event, ctx) => { … });
  pi.events.on("herdr:blocked", (data) => { … });   // custom bus also exists
}
```

Key facts (all observed in `herdr-omp-agent-state.ts`,
`orca-agent-status.ts`, `orca-titlebar-spinner.ts`, `orca-prefill.ts`):

- `pi.on(name, (event, ctx) => …)` — lifecycle subscriptions.
  `ctx` offers at least `ctx.hasUI`, `ctx.isIdle()`,
  `ctx.ui.setEditorText(…)`.
- `pi.events.on(name, …)` — a secondary custom event bus
  (`herdr:blocked` observed; producer unknown, out of scope).
- Environment contract used by real extensions: gate on env vars
  (`HERDR_ENV`, socket path, pane id), detect nested sessions via an
  inherited marker (`OMPCODE=1`), fire-and-forget Unix-socket
  JSON-lines writes with short timeouts (500 ms + 1500 ms retry),
  `timer.unref?.()` so hooks never hold the process open.
- No token/cost data flows through any extension event. Token usage
  is a TUI/statusline concern (`display.showTokenUsage` in
  `config.yml`); the D6 `tokens` field therefore stays **optional /
  best-effort** (omitted when unknown).

## 3. Real lifecycle events (all handlers observed in the wild)

| Event | Payload fields seen | Fires when |
|---|---|---|
| `session_start` | `event.reason` (`"startup"`/…), `ctx.hasUI`, `ctx.isIdle()` | session opens / reloads |
| `session_switch` | `event.reason` | session resumed/switched |
| `session_shutdown` | — | session teardown |
| `before_agent_start` | `event.prompt` | before the agent loop runs |
| `agent_start` | `ctx` | agent loop starts working |
| `agent_end` | `event.willContinue`, error text (matched against retryable-error patterns: rate-limit/`429`/`5xx`/timeout/connection…) | loop ends; `willContinue` = continuation already scheduled (not a settle) |
| `agent_settled` | — | loop fully settled (newer builds; orca treats as authoritative end) |
| `tool_call` | `event.toolName`, `event.input` | a tool is invoked |
| `tool_execution_start` | `event.toolName`, `event.args` | tool execution begins |
| `tool_execution_end` | `event.toolName` | tool execution finishes |
| `tool_approval_requested` | `event.toolName`, `event.reason` | tool call awaits user approval |
| `tool_approval_resolved` | — | approval answered |
| `message_end` | `event.message.role`, assistant text | an assistant message completes |
| `auto_compaction_start/end` | — | context compaction runs |

## 4. D6 state mapping (Tier 1 vs Tier 3)

D6 states: `idle | thinking | executing_tool | awaiting_approval | error`.

| D6 state | Tier | Source events (Tier 1) | Notes |
|---|---|---|---|
| `idle` | **Tier 1** | `agent_settled`, `agent_end` (with `willContinue != true` and no retryable error), `session_start` (before first start) | Debounce ~250 ms like herdr (avoids flicker between `agent_end` → next `agent_start`) |
| `thinking` | **Tier 1** | `agent_start`, `before_agent_start`, `message_end` (assistant text, no tool call following yet) | `agent_start` = loop working; text without tool calls = thinking |
| `executing_tool` | **Tier 1** | `tool_call` / `tool_execution_start` → `tool_execution_end`; `tool` = `event.toolName` | Exact tool name available on the event |
| `awaiting_approval` | **Tier 1** | `tool_approval_requested` → `tool_approval_resolved`; special case `tool_execution_start` with `toolName == "ask"` (+ `args.questions[0].question` as label) | The `ask`-tool pattern is proven by herdr in production |
| `error` | **Tier 1** | `agent_end` carrying a non-retryable error; retryable errors (rate-limit/`5xx`/timeout…) hold `thinking` through a grace window (~2.5 s) before flipping to `error` | herdr's `retryableErrorPattern` + grace-hold design is reused |

**Tier 3 (ANSI fallback) is not needed for any state**: every D6
state has a real Tier 1 event source on omp 18.4.4. Tier 3 stays as
the documented last resort (P2.10) for harnesses without an event
API, and for `tokens`/`tool` details when an event omits them
(`"confidence":"low"`, never guessed states).

## 5. Consequences for P2.3–P2.6

- Bridge (P2.5) subscribes: `agent_start`, `agent_end`,
  `agent_settled`, `tool_call`/`tool_execution_start`/`end`,
  `tool_approval_requested`/`resolved`, `session_start`/`shutdown`.
  It keeps the herdr state machine shape (blocked-count,
  retry-hold, idle debounce) but emits D6 JSON-lines to
  `$WRAITH_HARNESS_SOCK` instead of a vendor socket.
- Fire-and-forget budget from the field: two attempts
  (500 ms + 1500 ms); P2.5 tightens to a single ≤50 ms attempt
  (D6/P2.5: daemon must never be able to stall the agent).
- Install location (P2.6): a new file beside the existing ones in
  `~/.omp/agent/extensions/` (e.g. `wraith-omp-bridge.ts`), with a
  marker comment for idempotent uninstall; `--hook` also works but
  the extensions dir is the discovered default.
- Fixture strategy (P2.3 tests): replay the event names + payload
  shapes in §3 as JSON-lines fixtures (no live omp needed);
  files synthesized from this doc are labeled `synthetic` per spec.
