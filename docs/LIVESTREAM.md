# LIVESTREAM — LogViewer Live Streaming Repair Plan

> **Focus:** one thing only — the LogViewer livestream (LogPopoverView + RunPopup + server `runner._stream_progress` + `websocket.broadcast_run_log`). Historical messages render fine; the live incremental stream does not.

---

## 1. What we observe (user report)

| # | Symptom | Severity |
|---|---------|----------|
| 1 | Reasoning and assistant text look identical in the live panel | high |
| 2 | Tool calls never appear in the live stream (only in historical fetch) | high |
| 3 | Same sentence repeats many times while streaming | high |
| 4 | Markdown jumps / re-parses on every keystroke instead of flowing | medium |

Panel to fix: `Sources/LogPopoverView.swift` `liveStreamPanel` + `Sources/RunPopupController.swift` bubble.
Server to fix: `subworkers/server/app/services/runner.py:_stream_progress` + `routes/websocket.py:broadcast_run_log`.

---

## 2. Root causes (code-verified)

### 2.1 Repeating text — naive `+=` on possibly-cumulative deltas

Server reads opencode SSE `message.part.delta` at `runner.py:495–505`:

```python
if evt.get("type") != "message.part.delta": continue
field = props.get("field") or "text"
delta = props.get("delta") or ""
await ws_manager.broadcast_run_log(name, delta, field)
```

Client appends blindly at `LogPopoverView.swift:775`:

```swift
liveBuffers[name]?[field, default: ""] += delta
```

Two things make this repeat:

1. **Opencode's SSE can emit cumulative snapshots, not just incremental slices**, depending on model/provider (some providers re-emit the full `text` prefix + new token each tick). Appending the full snapshot each time produces `hello` → `hello world` (append) → `hello world!` (append) = `hellohello worldhello world!`.
2. **No idempotency guard.** The same SSE `data:` line can be delivered twice (reconnect, buffering, duplicate broadcast). Without a `partID/seq` key the client doubles it.

Both match user report: "repeat the same sentence again and again a lot".

**Fix:** stop assuming `delta` is always a suffix. Treat it as:
- fast path: `delta` is an incremental slice → append.
- cumulative path: `delta` starts with current buffer → replace with full string.
- duplicate path: `delta` equals tail of buffer → drop.
Implement at both layers: server normalizes before broadcast; client deduplicates on receipt.

### 2.2 Reasoning vs text not differentiated

`liveStreamPanel` (LogPopoverView:435–467) renders two bare `MarkdownView`s stacked vertically:

```swift
if !reasoning.isEmpty { MarkdownView(text: reasoning, baseColor: .secondary) }
if !text.isEmpty       { MarkdownView(text: text, baseColor: .primary) }
```

- Same card, same typography size, no left bar, no label — unlike the historical `messageRow → messageEntry(.reasoning)` which uses a grey bar + `secondary` color. Visually identical.
- `RunPopupController.swift:bubble` subscribes to the same `runLogNotification` but only watches unfiltered `text` (ignores `field`), so reasoning never appears there either and the popup shows mixed text.

**Fix:** give the live panel the same entry types as the history path: a typed stream of `reasoning / text / tool` blocks with distinct visuals (reasoning = thin grey bar + secondary + italic caption "THINKING"; text = primary; tool = banner). Reuse the existing `toolBanner` vocabulary.

### 2.3 Tools never stream

`runner._stream_progress` explicitly drops anything whose `field ∉ {text, reasoning}`. Tool calls surface in opencode's SSE as separate event families (tool part creation / updates) — they are filtered out. The client therefore never sees them and no `LiveEntry.tool` is ever produced. Fix on server: map tool-related SSE events to a `run_log` with `field="tool"` carrying `tool=name` + `input/output` (or a dedicated `run_tool` WS event). Keep the existing `text/reasoning` fast path intact for backwards compat.

### 2.4 Markdown reparsing on partial fragments

`MarkdownView` caches by full `text` string and re-parses all blocks each time live text grows. On a streaming prefix like ```` ```js\nconst ```` the parser sees an unclosed fence and may keep that block open, then re-close it on the next tick — producing flicker. Large buffers are re-parsed character-by-character. This is not the main bug but compounds the "doesn't follow flow".

**Fix:** keep markdown parsing but make the live path **append-only rendering**: each live `text` delta appends to one long string but the view renders it as a single `MarkdownView` with stable id; adopt micro-guards (don't show empty table fence, don't render a dangling ```` ``` ```` as a block). Plus the dedup above prevents the biggest jitter (repeated prefix re-parse).

---

## 3. How opencode streaming actually works (what to verify before touching code)

Opencode server (port 5655) SSE at `GET /event?directory=<dir>` emits typed events:

```
data: {"type":"message.part.delta","properties":{"sessionID":"ses_…","field":"text","delta":" Hel"}}
data: {"type":"message.part.delta","properties":{"sessionID":"ses_…","field":"reasoning","delta":"We need…"}}
data: {"type":"message.part.updated","properties":{"sessionID":"ses_…","part":{"type":"tool","tool":"bash",…}}}
```

Our current tap only forwards `message.part.delta` with `field ∈ {text,reasoning}` at `runner.py:495–505`.

**Pre-implementation verification checklist** (do in code, not by guessing):

1. `curl` or `httpx` stream a real running session's `/event?directory=/tmp/<name>` and log every `type` + `properties.field` + `delta` length observed across a full provider reply (text + reasoning + at least one tool call). If the host is not running, launch `subworkers/server` or replay a captured SSE log.
2. Confirm whether the provider's `delta` is incremental or cumulative: inspect two consecutive `delta`s for the same `sessionID+field` — does the second start with the first? Record answer here in the doc before writing code.
3. Confirm the tool surface: do tools come as `message.part.delta` with `field=tool` or as `message.part.created|updated`? Adapt server mapping accordingly.
4. Confirm that historical `GET /session/{id}/message` shape already partitions `parts: [{type,text},{type,reasoning},{type,tool}]` — LogPopoverView's `parseMessage` assumes this. Keep that contract for parity.

If verification contradicts any assumption above, update this section and adjust the fix — do not paper over it.

---

## 4. Target behavior (definition of done)

- Live panel streams **three block kinds** in order: `reasoning` (grey left-bar, secondary text, "THINKING" caption), `text` (primary markdown), `tool` (icon+color banner like the historical `toolBanner`). Each kind updates incrementally without rerendering the others.
- `reasoning` and `text` are visually distinct — a reviewer can tell them apart at a glance.
- Tool calls appear live (start + output), using the same icon/color/name vocabulary as `toolIcon/toolColor/toolDisplayName`. Output is trimmed at 600 chars like `formatToolContent`.
- No repeating sentences: sending the same substring twice in a row does not grow the visible text; cumulative deltas do not produce exponential duplication.
- Markdown flows: partial fences / tables do not flicker; auto-scroll follows the tail (`live-stream` anchor).
- Concurrent runs for different agents never clobber each other's buffers (already per-agent, preserve it).
- RunPopup bubble shows the same live taxonomy (at minimum reasoning + text; tool as a one-line summary) instead of only `text`.

---

## 5. Changes (minimal, scoped to livestream)

### 5.1 Server — `subworkers/server/app/services/runner.py`

- Harden `_stream_progress`:
  - Keep the current `message.part.delta → broadcast_run_log(name,delta,field="text|reasoning")` path, but add **normalization**: per `sessionID+field` remember the last broadcast string. If new `delta` already contains the buffer as prefix, broadcast only the suffix; if it's identical to the suffix just sent, skip.
  - Add a **tool branch**: for SSE events that carry tool activity (`message.part.created|updated|delta` with tool payload), extract `tool name + input/output` and call `broadcast_run_log` with `field="tool"` (or a new `broadcast_run_tool` → WS `event="run_tool"` — pick one and keep client in sync). Keep existing `run_banner` path unchanged.
  - No change to `_reinject_on_provider_error` banner flow.

### 5.2 Server — `subworkers/server/app/routes/websocket.py`

- Extend `broadcast_run_log` to accept `field ∈ {text,reasoning,tool}` (and optional `tool` meta). Or add `broadcast_run_tool(name, toolPayload)` → `{"event":"run_tool",...}`. Client needs a single place to branch on `field`.
- Keep `ws_manager.broadcast` as is — no protocol break for non-live clients.

### 5.3 Client — `Sources/LogPopoverView.swift`

Replace the flat `liveBuffers: [String:[String:String]]` string bag with an ordered entry list:

```swift
enum LiveEntry: Identifiable {
  case reasoning(String)          // accumulated
  case text(String)               // accumulated + markdown
  case tool(name: String, input: String?, output: String?)  // one banner per call
}
@State private var liveEntries: [String: [LiveEntry]] = [:]
```

- `observeRunLogs()` switches on `field`:
  - `reasoning` → append to (or create) the trailing `.reasoning` entry; dedup if identical to tail; if server sent cumulative, replace.
  - `text` → same for `.text` (render once as `MarkdownView(text: text, baseColor: .primary)`).
  - `tool` → append a `.tool` entry using the existing `toolBanner(icon:title:color:content:)` and `formatToolContent` helpers.
- `liveStreamPanel` renders `ForEach(liveEntries[name] ?? [])` in order with the same visuals as `messageEntry` does for history (reasoning = `Rectangle()` left bar + secondary; text = MarkdownView; tool = toolBanner + divider). Preserve `id("live-stream")` for auto-scroll.
- Dedup helper: `normalizedDelta(for:text:field:delta:) -> String?` (returns nil if duplicate, otherwise suffix to append). mirrors server logic so a misbehaving server cannot force a loop.
- `resetLiveBuffer(for:)` clears both maps when switching sessions.

RunPopup: mirror the field filter there or extract a shared observer so reasoning doesn't leak into popup twice.

### 5.4 Client — `Sources/RunPopupController.swift` + `Sources/SubworkerManager.swift`

- `SubworkerManager.handleWSMessage` for `run_log`: keep posting `runLogNotification` but include `field`. No change to pong/health paths.
- `RunPopupController.observeLogs`: filter `field=="text"` for bubble live text, optionally render a faint reasoning line under it (keep minimal since the popup is small). If `field=="tool"`, append a one-line bullet `🔧 <tool>` truncated at 80 chars.

---

## 6. Verification (must pass before shipping)

### 6.1 Code-level (no running server required)

- `swift build` / `swiftc` syntax check on the two Swift files.
- Unit / preview: synthesize a sequence of fake `run_log` notifications:
  `[text:"Hel", text:"lo", reasoning:"think…", tool:"bash {cmd}", text:" world"]`
  — assert `liveEntries` length = 3 and rendering order matches, and that re-sending `delta:"Hello"` when buffer is already `"Hello"` does not double it.

### 6.2 Live (requires a running agent)

- Trigger any subworker with reasoning + at least one tool call (e.g. a grep or bash). Observe LogViewer live panel: reasoning shows with grey bar + caption, text flows without repetition, tool banner appears live, historical fetch matches live after completion (no divergence).
- Run two agents concurrently — switching sessions in LogViewer does not reset the other's live tail.
- Leave markdown-heavy reply (code block + table) — no flicker as the fence opens/closes.

### 6.3 Blast radius

- No changes to session listing, `fetchMessages`/`parseMessage`, `MarkdownView` parser, or `AppDelegate` menu. Only the stream tap + live panel.

---

## 7. Rollout

1. Verify SSE shape (§3) and fill in findings.
2. Land server changes first, restart FastAPI, capture a short SSE trace.
3. Land Swift changes, build `EliaTopBar.app` with `./build-app.sh`, manual smoke with a triggered run.
4. Close this doc with a one-line outcome note on what was actually observed.

---

## 8. Open questions (answer during verification, not before)

- Does the active provider emit cumulative `delta` for this model? If yes, server normalization is load-bearing; if no, client dedup alone is enough.
- Exact SSE type for tool calls on the running host (capture, don't assume).
- Whether to use `field="tool"` vs a separate `run_tool` WS event — align server+client in the same commit.

---

## 9. Implementation record (2026-08-27)

**Server** `subworkers/server/app/services/runner.py:_stream_progress`:
- Added per-field `last_emitted` dedup: cumulative `delta` (full prefix) → emit only suffix; pure duplicate / substring → drop. Prevents the "same sentence again and again" bug when a provider sends cumulative snapshots.
- Added tool branch: `message.part.created|updated` with `part.type==tool` → broadcast as `field="tool"` with JSON `{tool,input,output}`. Previously filtered out, now live banners appear. `websocket.broadcast_run_log` already forwards any `field` value, no protocol break.

**Client** `Sources/LogPopoverView.swift`:
- Replaced `liveBuffers:[String:[String:String]]` with `liveEntries:[String:[LiveEntry]]` (`liveReasoning/liveText/liveTool` in order). Reasoning now renders as `THINKING` caption + grey left bar (`Rectangle gray 0.35` + `secondary`), distinct from primary text. Tools render via existing `toolBanner` vocabulary (icon/color/title). Markdown uses `streamingSafeMarkdown` to close dangling ` ``` ` fences instead of flickering.
- Client-side dedup mirrors server (prefix / tail / substring guards) so a misbehaving server cannot force duplication. Per-agent keying preserved so concurrent runs don't clobber.
- `RunPopupController.observeLogs` now filters `field`: ignores `reasoning`, renders `tool` as `🔧 <name>` line, dedupes `text` the same way.

**Verification**: `swift build` ✅, `py_compile` ✅, synthetic dedup unit checks ✅. Live SSE capture not yet run (server at 127.0.0.1:5655 unreachable in this env); tool SSE shape assumed from `message.part.created|updated` — confirm with a real `GET /event?directory=/tmp/<name>` trace on next live trigger and adjust `ptype` key if opencode uses a different field name.

---

## 10. TodoList Live Tracker — `todowrite` dots module (2026-08-27)

**Goal:** when the agent drives its work via `todowrite`, surface the todo list as a live, glanceable tracker inside the LogViewer without stealing messagesPanel space.

**Source of truth:** `tool == "todowrite"` (case-insensitive) in both historical `messages[].parts[]` and live `liveEntries` (`field == "tool"`). Payload is `input: { todos: [{ content: String, status: "pending"|"in_progress"|"completed"|"cancelled", priority: "high"|"medium"|"low" }] }` — verified against `refund-hunter` `ses_fbb6817…` (6 todowrite calls, 7 todos, status evolves `pending → in_progress → completed`). Output echoes the same array as a stringified JSON; we parse `input.todos` and keep the *last* todowrite per session as current state. Also handles `TodoWrite` casing and `output` fallback.

**UI:** vertical dots module **stuck to the left border of `messagesPanel`, centered vertically** (overlay, not pushing content). Collapsed: thin strip ~14pt wide, one dot per todo (fixed 10pt height, `max 10` visible → scrollable), colors `pending=gray`, `in_progress=blue pulsing`, `completed=green`, `cancelled=red/0.4`. Hover: expands horizontally to fit todo texts (`dot + content` rows, priority as subtle suffix), **clamped to `760 - sidebar 210 ≈ 550` so it never overflows the popover**, animated `.easeOut`, collapses on exit. Hidden when session has no todowrite.

**State & live sync:** derived from `displayItems` + `liveEntries` for the selected session; rebuilds on session switch (clears on `selectedSessionId` change) and on every live `tool` delta. Respects the same session-race guard (`lastMessagesFingerprint` per `sessionId`) and bottom-anchor pin logic, so it doesn't fight scroll.

**Files:** `Sources/LogPopoverView.swift` (new `TodoState` + overlay), `Sources/SubworkerManager.swift` (no change, reuses `run_log` `field=tool` path), verification via `curl /sessions/{name}?session_id=` + `sqlite3 /root/.local/share/opencode/opencode.db` `SELECT data FROM part WHERE data LIKE '%todowrite%'`.

