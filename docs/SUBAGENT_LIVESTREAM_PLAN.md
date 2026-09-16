# Subagent Livestream — Nested Bubbles Below RunPopup (Implemented 2026-09-16)

> **Date:** 2026-09-16 — Updated to reflect shipped code
> **Status:** ✅ IMPLEMENTED — RunPopup vertical subagent strip + expandable bubble, LogViewer tail, centralized store
> **Scope:** `Sources/Livestream/*`, `Sources/RunPopupController.swift` (`RunPopupView` + `SubagentBubbleView`), `Sources/LogPopoverView.swift`, `Sources/SubworkerManager.swift`, `subworkers/server/app/services/runner.py` (poll-first, WS later)
> **Goal:** when a subworker session spawns subagents (`call_omo_agent` / `task` / `team_create` → `team_task` + `call_omo` background), detect them and render each subagent's livestream as its own special bubble — same rendering, same autoscroll/arrow/todo logic, per-subagent, without moving the main Drop

---

## 1. What shipped

* **Centralized store already landed:** `LivestreamStore` (`streams: [agent: AgentStream]`, `todos`, `subagentStreams: [SubagentKey: AgentStream]`, `subagentTodos`, `throttled`/`subagentThrottled` 80 ms) is the single append-only source. `SubworkerManager.handleWSMessage(.run_log)` dual-writes to `store.appendDelta` and the legacy `NotificationCenter`. Both `LogPopoverView` and `RunPopupView` read `store.stream(for:)` / `store.todo(for:)` / `store.subagentStream(for:)` instead of local `liveEntries`. Burst `0 msg` flash is fixed via `mergeHistory` no-op on empty snapshot, stable IDs, and `historyReady` gating (strips hidden until history loads, so a new session with no `todowrite` shows no todo).

* **Subagents are now visible (poll-first, no server change):**
  - Parent `call_omo_agent` with `run_in_background=true` → output `Session ID: ses_f58...` → `SubagentKey(parentAgent, sessionId, description, agent, kind:"call_omo", teamRunId:nil)` polled via `GET /sessions/{parent}?session_id={sub}&limit=30` every 1.5 s while parent `running`, merged via `mergeSubagentHistory` (same dedup/caps, never clears live tail).
  - `team_create` → `runtimeState.members[].sessionId` → 2–3 `SubagentKey(kind:"team", teamRunId: teamRunId)` — shown immediately as `pending:team:{parent}:{teamName}` placeholder when output is still `None`, replaced by real `ses_...` members when output arrives. Duplicate `team_create` calls with same name are de-duped by `seen` set.
  - `team_task_create` → `SubagentKey(kind:"team_task", teamRunId, description: subject)` — shown as orange `task` badge; `TopbarSettings.teamTasksPosition` (`above`/`side`, default `side`) controls whether those tasks live in the right-side vertical strip or in a full-width horizontal bar above `mainCard` (`teamTasksAboveBar`).

* **Why it was a pain before:** Each subagent needs the same dedup (cumulative vs incremental), caps (12k), banner vocabulary, scroll-pin (`isPinned` + `BottomKey` + `requestScroll` 0.05s + debounced `pendingPinnedFalse` 0.08s), todo regex for truncated 800-char payloads, and history-vs-live merge. Doing it 3× without a shared store reintroduced the duplication we just removed.

## 2. Detection (verified live)

* **cve-hunter still the golden trace:** `ses_f5871e8daffeTo7Uwz67Ualx9W` with 3× `call_omo_agent` → `ses_f586dc...` / `ses_f586db...` / `ses_f586da...` each 4–5 msgs (`websearch`×6) fetchable via `GET /sessions/cve-hunter?session_id={sub}&limit=20` even though not in `.../list` — FastAPI forwards any `session_id` to `opencode` (`127.0.0.1:5655/session/{id}/message`).

* **test-delegator team mode (the verification subworker):** `ses_f58104248...` (triggered 02:58) did `team_create` → `09807d00...` (alpha+beta, `ses_f58020e0...`/`ses_f58020df...`) + 2× `call_omo_agent` background (`ses_f58023b...`/`ses_f580239...`) — total 4 subagents: 2 team members + 2 bg tasks. `extractSubagents` now handles all three: `call_omo_agent`/`task` via `Session ID:` regex, `team_create` via `runtimeState.members`, `team_task_create` via `task.id`/`subject` + `teamRunId`.

* **Live vs history:** No dedicated WS for subagents — parent's `_stream_progress` only subscribes to parent `sessionID`, so subagent deltas are **not** broadcast as `run_log` for the parent. Poll-first reuses `mergeHistory` path and needs no server change. WS-later would be `runner.py` subscribing to each `subagentSessionId` and broadcasting `{"event":"run_log","name":"\(parent):\(description)","field":...}` → `store.appendSubagentDelta`.

## 3. UI — what the user sees now

```
RunPopup (340×260 base, grows downward when subagent expanded, top stays at barBottom-260)
┌─ photoBadge (above / left / right / tiny per TopbarSettings dropIconPosition) ─┐
├─ stickerHeader (full-width, live dot + ↓/↑ ko/s — 1000ko=1Mo — + tools/msgs, hidden until historyReady) ─┤
├─ teamTasksAboveBar (if teamTasksPosition=="above" and team tasks exist, horizontal orange pills) ─┤
├─ mainCard: [ subagentStripLeft? | todoStrip (28→180 overlay) | bubble (145pt ScrollView) | subagentStripRight? ] ─┤
│   todoStrip: purple checklist 28→180, isHoveringTodoModule, shows TodoList banner + priority pills
│   subagentStrip: pink person.2 28→180, isHoveringSubagent, shows SUBAGENTS count + per-subagent rows:
│                GrokWorkingDot (square 8pt orbit + pulsing dot) when isWorking else ✅, description, kind badge (team=blue, bg=purple, task=orange), tools⧉ msgs
│                grouped by teamRunId → multiple thin columns (12pt) when >1 team, each column 6 dots, hover widens to show team name
├─ subagentStack (below mainCard, only when expandedSubagent != nil) ─┤
│   SubagentBubbleView(key, baseURL, onClose) — header with xmark at top-left to collapse back to pill bar, pink person.2, description, agent, tools/msgs, live dot
│   body: ScrollView 90pt, same Markdown + toolBanner vocabulary (compact 7/6pt), isPinned + arrow.down re-pin, same todo regex
└─ (closeAll on primary click still closes whole Drop including sub-bubbles; draggable via native performDrag when enabled)
```

* **Main Drop never jumps:** `RunPopupController.updateHeight(for:to:)` keeps `y = barBottom - newHeight` (top pinned to menu bar), height grows downward only for the expanded subagent bubble (`baseH 260 + sticker 36 + subH 110`). Vertical strips are overlays (28→180) that don't push the bubble.

* **Topbar Settings additions:**
  - `Subagents` picker: `Left of bubble` / `Right of bubble` (default `right`) → `subagentPosition`
  - `Team tasks` picker: `Above RunPopup` / `Right side bar` (default `side`) → `teamTasksPosition`; `above` shows `teamTasksAboveBar` horizontal orange bar, `side` merges team tasks into the same vertical strip.

* **LogViewer:** same `subagentKeys` + `SubagentBubbleView` stack below `liveStreamPanel` inside `messagesPanel`'s `LazyVStack` tail, sharing the single `bottomAnchor`; session switch clears `subagentKeys` + `expandedSubagent` and repopulates from the new parent's history.

## 4. Store extension (no new dedup)

```swift
struct SubagentKey: Hashable {
    let parentAgent: String; let sessionId: String; let description: String
    let agent: String; let kind: String // team, call_omo, task, team_task
    let teamRunId: String?
}
@Published private(set) var subagentStreams: [SubagentKey: AgentStream] = [:]
@Published private(set) var subagentTodos: [SubagentKey: [TodoItem]] = [:]
func subagentStream(for key: SubagentKey) -> [LivestreamEntry]
func extractSubagents(parentAgent: String, rawMessages: [[String: Any]]) -> [SubagentKey] // scans call_omo_agent|task|team_create|team_task_create
func mergeSubagentHistory(key: SubagentKey, rawMessages: [[String: Any]])
```

Dedup/caps/throttle are reused verbatim; `team_create` pending placeholder (`pending:team:{parent}:{teamName}`) appears instantly on `team_create` seen in live stream, replaced by real `ses_...` members when output arrives. Per-session `historyReady` gating ensures a new session with no `todowrite`/`call_omo` shows no strips until it actually calls them.

## 5. Wiring (poll-first, no server change)

* `RunPopupView.fetchMessagesForHistory` → `store.mergeHistory` + `updateSubagents(from: rawMessages)` → `subagentKeys = keys` (replace, not append, per-session) + `startPollingSubagent` for each `ses_...` (1.5 s, `GET /sessions/{parent}?session_id={sub}&limit=30` → `mergeSubagentHistory`). `refreshSubagentsFromLive` does the same from `store.stream(for: parent)` on every `throttled` tick, so a `team_create` that appears live shows the pending pill within 80 ms.
* `LogPopoverView` does the same after `fetchMessages`.
* Poll timers are torn down on `onDisappear` and when `subagentKeys` loses a key.

## 6. Files touched (this iteration)

1. `Sources/Livestream/LivestreamStore.swift` — `SubagentKey` + `teamRunId`, `subagentStreams/todos`, `extractSubagents` (team_create + team_task_create), `mergeSubagentHistory`, `sessionForAgent` + `historyReady` per-session gating for `todos`
2. `Sources/Livestream/LivestreamParsing.swift` — shared `extractTodos`/`parseEdit` etc. (no new icons)
3. `Sources/RunPopupController.swift` — `GrokWorkingDot` (square 8pt orbit + pulsing dot, same as Topbar grok without icon), `isWorking` helper (Grok vs ✅), `groupedSubagents` thin columns per team, `subagentVerticalStripCollapsed/Expanded` with kind badges, `stickerHeader` + `teamTasksAboveBar`, `mainCard` with left/right subagent strips (attached radii), `subagentStack` as single expanded bubble with `xmark` close, `updatePanelForSubagents` keeping top pinned, per-session `historyReady` + `effectiveTodos`/`subagentKeys` gating
4. `Sources/TopbarSettingsView.swift` — `subagentPosition` and `teamTasksPosition` pickers
5. `Sources/LogPopoverView.swift` — `historyReady` gating for `verticalTodos`/`subagentKeys` (per-session, not per-agent)

No `AppDelegate` menu change beyond the existing `closeAll` + `Clean RAM` + `Launch at Login` moves.

## 7. Verification

* **Live cve-hunter:** 3 `call_omo_agent` → 3 sub-bubbles appear within 2 s below main bubble, each header shows `bg` badge and live dot, each body streams its own `websearch` without clearing parent. `background_output` error for the failed Target Identification shows inside its sub-bubble.
* **Live test-delegator team:** `team_create` → pending `Team creating…` pill appears instantly on live, replaced by 2 `team` pills (`alpha`/`beta`) + 2 `bg` pills (`parallel_a`/`parallel_b`) once `runtimeState.members` arrives; `team_task_create` → 2 orange `task` pills either in side strip or above bar per setting. Burst `websearch`×6 in subagents doesn't flash parent.
* **Autoscroll per bubble:** scroll parent up → parent arrow, parent stops chasing, sub-bubble still chases (its own `isPinned`). Tap parent arrow → parent snaps to end and re-pins, sub-bubble unaffected. Same for sub-bubble.
* **Session switch:** picking a different parent session clears parent live tail and all sub-bubbles for that parent, then repopulates from the new parent's history; a new session with no `todowrite` shows no todo strip.
* **`swift build` + `swift build -c release --arch arm64` green.**

## 8. Non-goals (still)

* Server-side subagent WS broadcast — poll-first proves the UI; WS can be added after.
* New banner types — subagents reuse the same `toolBanner` vocabulary.
* Persisting subagent positions — they move with the parent Drop (draggable) as one card.
