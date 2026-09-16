# Subagent Livestream — Nested Bubbles Below RunPopup

> **Date:** 2026-09-16
> **Status:** PLAN — no code yet, do not implement until approved
> **Scope:** `Sources/RunPopupController.swift` (RunPopupView), `Sources/LogPopoverView.swift`, `Sources/Livestream/*`, `Sources/SubworkerManager.swift`, `subworkers/server/app/services/runner.py` (if WS needed)
> **Goal:** when a subworker session spawns subagents (`call_omo_agent` / `task`), detect them and render each subagent's livestream as its own special bubble below the main RunPopup bubble — same rendering, same autoscroll/arrow/todo logic, per-subagent
> **Reference:** `docs/LIVESTREAM_CENTRALIZATION_OPTIMIZATION_PLAN.md` (centralized append-only LivestreamStore) — this plan reuses that store, it does not replace it

---

## 1. What we have today

* **Centralized livestream already lands:** `LivestreamStore` (`streams: [agent: AgentStream]`, `todos`, `throttled` 80 ms) is the single append-only source. `SubworkerManager.handleWSMessage(.run_log)` dual-writes to `store.appendDelta` and the legacy `NotificationCenter`. Both `LogPopoverView` and `RunPopupView` now read `store.stream(for:)` and `store.todo(for:)` instead of local `liveEntries`. Burst `0 msg` flash is fixed via `mergeHistory` no-op on empty snapshot and stable IDs.

* **Subagents are invisible:** A parent turn like cve-hunter's `call_omo_agent` launches 3 background tasks:

  ```
  Tool: call_omo_agent { description: "CVE Research - WordPress", prompt: "You are a security research agent..." }
  Output: "Background agent task launched successfully. Task ID: bg_d76214b3 Session ID: ses_f586dc025ffeIvzrgudkSstfz2 Agent: explore Status: pending"
  ```

  The parent session (`ses_f5871e8daffeTo7Uwz67Ualx9W`) shows the tool banner for `call_omo_agent` and later `background_output` with the subagent's result, but the subagent's own `text/reasoning/tool` deltas (`ses_f586dc...` with 4–5 msgs of `websearch` etc.) are **not streamed** as live — they are only visible after `background_output` completes. No per-subagent bubble, no per-subagent scroll, no per-subagent todo.

* **Why it's a pain (same as the main plan, but nested):** Each subagent needs the same dedup (cumulative vs incremental), same caps (12k), same banner vocabulary (`toolIcon` etc.), same scroll-pin (`isPinnedToBottom` + `BottomAnchorPreferenceKey` + `requestScroll` 0.05s throttle + debounced `pendingPinnedFalse` 0.08s), same todo regex for truncated 800-char payloads, and same `400 ms` history-vs-live merge. Doing it twice without a shared store reintroduces the 3× duplication we just removed.

---

## 2. How to detect subagents (verified on cve-hunter right now)

* **Live, cve-hunter is RUNNING** (`/status/cve-hunter` `running:true`, `next_run 08:00`, `model ling-3.0-flash`). Its current session `ses_f5871e8daffeTo7Uwz67Ualx9W` has 15 msgs; msg 6 contains 3× `call_omo_agent`, each output contains `Session ID: ses_f586...` and `Agent: explore` + `Description`.

* **Subagent sessions are fetchable via the same REST the main uses:** `GET /sessions/cve-hunter?session_id=ses_f586dc025ffeIvzrgudkSstfz2&limit=20` returns the subagent's own 4–5 msgs (websearch ×6), even though that session_id is not in `GET /sessions/cve-hunter/list` (which only lists the 3 parent sessions). The FastAPI proxy forwards any `session_id` to the opencode server (`127.0.0.1:5655/session/{id}/message`), so detection is:

  1. Parse the parent session's `parts[].type=="tool" && tool=="call_omo_agent"` (and also `tool=="task"` with `subagent_type` for other agents).
  2. From `part.input` (dict or JSON string) read `description` and from `part.output` (string) extract `Session ID: ses_...` via regex `Session ID:\s*(ses_[a-zA-Z0-9]+)` and `Task ID: bg_...`, `Agent: ...`.
  3. For each extracted `session_id`, treat it as a subagent stream keyed by `"\((parentAgent)):\(sessionId)"` or `"\((parentAgent)):\(description)"` (description is human-readable for the bubble header).

* **Subagent `task` variant:** Other agents use `tool=="task"` with `subagent_type` (e.g. `explore`, `librarian`) and `prompt` — same extraction, but `input` contains `subagent_type`, `description`, `prompt`. Handle both.

* **Live vs history for subagents:** Today subagents have no dedicated WS `run_log` channel — the parent's `_stream_progress` only subscribes to the parent's `sessionID`. Subagent deltas are therefore **not** broadcast on `field=="tool"` for the parent. To get live, either (a) poll the subagent session via REST every 1.5 s (same as `liveMessagesPollTimer` in LogViewer) while the parent is `running`, or (b) extend `runner.py` to also subscribe to each subagent's `directory`+`sessionID` and broadcast with `field=="tool"` and `name=="\(parent):\(subagentDesc)"` (heavier, needs server change). For the first iteration, **poll** — it reuses the existing `mergeHistory` path and needs no server change.

---

## 3. Target UI — special bubble below RunPopup

```
RunPopup (existing, 310×260)
┌─ photoBadge (above / left / right / tiny) ─┐
├─ stickerHeader (full-width, live dot + traffic + tools/msgs) ─┤
├─ mainCard: [ todoStrip (28→180 overlay) | bubble (text/reasoning/tool banners) ] ─┤
│  // NEW: subagent stack, appears only when parent has ≥1 subagent
├─ Divider (if subagents) ─┤
├─ SubagentBubble 1 ──────────────────────────────────────────────┤
│  header: [ ● explore  "CVE Research - WordPress"  12 tools  4 msgs  live/error ] │
│  body: ScrollView 90pt, same Markdown + toolBanner vocabulary (compact) │ isPinned + arrow │
├─ SubagentBubble 2 ──────────────────────────────────────────────┤
│  header: [ ● explore  "CVE Research - Wix and Vibecoded" ... ] │
├─ SubagentBubble 3 (if any) ─────────────────────────────────────┤
└─ (closeAll on primary click still closes the whole Drop including sub-bubbles)
```

* Each sub-bubble is a **mini copy of the main bubble**: same `LivestreamStore` rendering (`toolIcon`, `editDiff`, `writeFile`, `todoWrite`, `terminal`, `skill`), same `streamingSafeMarkdown`, same `hostPath`, same per-bubble `isPinnedToBottom` + `BottomAnchorPreferenceKey` + `requestScroll` throttle + `pendingPinnedFalse` 0.08s debounce + bottom-center `arrow.down` that re-pins. Size is compact: `height 90` for the ScrollView (vs 145 main), `cornerRadius 10`, `regularMaterial` with `primary.opacity(0.12)` stroke, `compact:true` for banner fonts (7/6 pt). Header shows subagent `description` (from `call_omo_agent` input), `Agent: explore` badge, live dot, tool/msg counts, and traffic mini (`↓ ko/s`).

* The stack is `VStack(spacing:8)` below `mainCard`, inside the same `RunPopupView` VStack, still inside the 310-wide panel. If >3 subagents, the whole Drop becomes scrollable or capped at 3 with `+N more` (like the todo strip). For cve-hunter's 3, all 3 show.

* LogViewer gets the same sub-bubbles **below its `liveStreamPanel`**, inside `messagesPanel`'s `LazyVStack` tail, so the historical `displayItems` + main live tail + subagent tails are one continuous scroll with a single `bottomAnchor`. Alternatively, LogViewer can show sub-bubbles in a collapsible `DisclosureGroup("Subagents (3)")` — pick one and keep it.

---

## 4. Centralized store extension (no new dedup)

```swift
// LivestreamStore.swift additions (still @MainActor, still append-only)
struct SubagentKey: Hashable { let parentAgent: String; let sessionId: String; let description: String }
@Published private(set) var subagentStreams: [SubagentKey: AgentStream] = [:]
@Published private(set) var subagentTodos: [SubagentKey: [TodoItem]] = [:]

func subagentStream(for key: SubagentKey) -> [LivestreamEntry]
func subagentTodo(for key: SubagentKey) -> [TodoItem]

func registerSubagent(parent: String, sessionId: String, description: String, agent: String)
func appendSubagentDelta(key: SubagentKey, field: String, delta: String) // same dedup as appendDelta, same caps
func mergeSubagentHistory(key: SubagentKey, rawMessages: [[String:Any]]) // same as mergeHistory, same fingerprint, never clears

// Detection helper (shared)
func extractSubagents(from rawMessages: [[String:Any]]) -> [SubagentKey] // scans parts[].tool=="call_omo_agent"||"task", parses input/output for sessionId
```

* The existing `appendDelta`/`mergeHistory` dedup (cumulative prefix → replace, duplicate tail → drop, 12k cap) is reused verbatim for subagents — no new logic to diverge.

* Throttling is per-subagent too: `throttleWork[SubagentKey]` 80 ms, and each sub-bubble subscribes to `throttled` filtered by its key (or just observes `subagentStreams`).

---

## 5. Wiring — how live gets in without a server change (poll first, WS later)

**Poll-first (no server change):**

* In `RunPopupView`, after `fetchRunHistory` merges the parent, call `let subs = LivestreamStore.shared.extractSubagents(from: rawMessages)` and for each `key` start a `Timer` (1.5 s, like `liveMessagesPollTimer` in LogViewer) that does `GET /sessions/\(parentAgent)?session_id=\(key.sessionId)&limit=30` → `store.mergeSubagentHistory`. While `subManager` reports `parent running` or `store.stream(for: parent)` is still growing, keep polling. Cap at 3 concurrent polls.

* In `LogPopoverView`, same: after `fetchMessages` merges parent history, extract subagents and start polling their histories. The left sidebar does not need subagent sessions.

**WS-later (optional server change, if poll proves too laggy):**

* Extend `runner.py:_stream_progress` to, after launching a `call_omo_agent` background task, also `asyncio.create_task(_stream_progress(subagentSessionId, directory))` and broadcast with `{"event":"run_log","name":"\(parent):\(description)","field":field,"text":delta}`. Then `SubworkerManager.handleWSMessage` would call `store.appendSubagentDelta` instead of polling. This is a 10-line server change and can be added after the poll version proves the UI.

---

## 6. Files to touch (ordered, reversible)

1. `Sources/Livestream/LivestreamStore.swift` — add `SubagentKey`, `subagentStreams/todos`, `register/append/merge` for subagents, `extractSubagents` helper (regex for `Session ID:` + JSON parse for `description`).
2. `Sources/Livestream/LivestreamParsing.swift` — add `extractSubagentInfo(from:)` used by the store helper (no new toolIcon needed).
3. `Sources/RunPopupController.swift` — add `@State subagentKeys: [SubagentKey]`, `subagentPollTimers: [SubagentKey: Timer]`, `stickerHeader` stays, then below `mainCard` add `ForEach(subagentKeys)` rendering `SubagentBubble` (new `View` struct in same file, 90pt ScrollView, same `isPinned` + `arrow.down` logic, compact banners). Wire `onReceive(livestream.$subagentStreams)` + `onAppear` extraction + polling.
4. `Sources/LogPopoverView.swift` — same sub-bubble stack below `liveStreamPanel`, inside `messagesPanel`'s `LazyVStack` tail, sharing the single `bottomAnchor`. Add `subagentKeys` state and polling there too (or observe the parent's extracted keys via store).
5. `Sources/SubworkerManager.swift` — no change for poll-first; for WS-later, one branch in `handleWSMessage` to route `name` containing `:` to `store.appendSubagentDelta`.
6. `docs/LIVESTREAM_TECHNICAL.md` — add §11 with subagent wire shape and reuse recipe.

No `AppDelegate` menu change, no `TopbarSettingsView` change (unless we add a toggle for "Show subagents" — default ON).

---

## 7. Verification (must pass before shipping)

* **Live cve-hunter right now:** trigger cve-hunter, wait for the 3 `call_omo_agent` to appear in the parent bubble as tool banners, then within 2 s the 3 sub-bubbles appear below the main bubble, each header shows its description and live dot, each body streams its own `websearch` etc. without clearing the parent. `background_output` for the failed Target Identification shows `encrypted_content` error inside its sub-bubble, not in the parent.
* **Burst + subagents:** while subagents stream `websearch` ×6 each, the parent still streams its own `reasoning` — no `0 msg` flash in either level (store's `mergeHistory` no-op on empty).
* **Autoscroll per bubble:** scroll the parent up → parent arrow appears, parent stops chasing, sub-bubble still chases (its own `isPinned`). Tap parent arrow → parent snaps to end and re-pins, sub-bubble unaffected. Same for sub-bubble.
* **Session switch in LogViewer:** picking a different parent session clears parent live tail and all sub-bubbles for that parent (via `store.clear` for parent + its subagent keys), then repopulates from the new parent's history.
* **`swift build` + `swift build -c release --arch arm64` green.**

---

## 8. Non-goals

* Server-side subagent WS broadcast — poll-first is enough to prove the UI; WS can be added after.
* New banner types — subagents reuse the same `toolBanner` vocabulary (no new icons).
* Persisting subagent positions — they move with the parent Drop (draggable) as one card.

---

## 9. Decision needed before Phase 1

* Poll interval for subagents: 1.5 s (like LogViewer's `liveMessagesPollTimer`) vs 1.0 s (like traffic timer) — 1.5 s is preferred to avoid hammering `opencode.db`.
* Cap for sub-bubble ScrollView height: 90 pt (compact) vs 110 pt — 90 keeps the whole Drop under 500 pt even with 3 subagents.
* Whether to collapse sub-bubbles behind a `DisclosureGroup` in LogViewer when >2 — keep expanded for now, collapse later if noisy.

Once approved, start with store extension + RunPopup sub-bubble (poll-first) and capture a live cve-hunter run as the golden trace.

