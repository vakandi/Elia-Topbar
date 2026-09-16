# Livestream Centralization & Stability Plan — LogViewer + RunPopup

> **Date:** 2026-09-16
> **Status:** ✅ IMPLEMENTED 2026-09-16 — LivestreamStore centralized, burst throttle, append-only merge, primary-icon close toggle
> **Scope:** `Sources/LogPopoverView.swift`, `Sources/RunPopupController.swift`, `Sources/SubworkerManager.swift`, `Sources/Livestream/*`
> **Goal:** one append-only livestream engine, zero full-clear flicker under burst load

---

## 1. What we have today (why it hurts)

| Aspect | LogViewer (`LogPopoverView.swift`) | RunPopup (`RunPopupController.swift:RunPopupView`) |
|---|---|---|
| `LiveEntry` enum | `liveReasoning / liveText / liveTool` (per-agent `[String:[LiveEntry]]`) | `text / reasoning / tool` (flat `[RunLiveEntry]`) — **duplicate, diverged names** |
| Append + dedup | `appendLiveDelta(for:name:field:delta:)` 120 lines, per-agent, handles cumulative prefix / substring / tail | `appendLiveDelta(field:delta:)` 60 lines, flat, slightly different guards (`delta.count<40` vs `<80`) |
| Caps | reasoning/text 12k → 8k suffix, tools 40 entries | same caps but separate constants |
| Todo extraction | `extractTodosForLive` + `parseTodoWritePayload` | `runExtractTodos` + `runScanTodosFromString` — **second parser added for truncated 800-char payloads, not shared** |
| History preload | `fetchMessages(sessionId:)` 5-page pagination (limit 20→40), `hasMoreMessages`, fingerprint dedup | `fetchRunHistory() → fetchMessagesForHistory()` limit 30, no pagination, separate mapping |
| Scroll pin | `isPinnedToBottom` + `BottomAnchorPreferenceKey` + `requestScroll(proxy:force:)` throttle 0.05s | Just added `RunBubbleBottomKey` + `isPinnedToBottom` copy — **third copy of same logic** |
| Rendering | `liveStreamPanel` (THINKING bar + Markdown + toolBanner + editDiff + writeFile + todoWrite) | `popupEntry` (same vocabulary but compact, duplicated `toolIcon/toolColor/formatToolContent`) |

**Result:** 3× the same dedup, 2× the same banner vocabulary, 2× the same scroll-pin, 2× the same todo parser. Fixing a truncation bug in one place does not fix the other. Burst load exposes divergent caps and clearing semantics.

### The reported bug

> When a lot of msgs arrive, the livestream bugs — display shows **0 msg 0 tools**, whole UI of both LogViewer and RunPopup clears for a few seconds until the stream comes back. Clearing the whole chat is the opposite of appending.

Both panels clear at the same time → source is not rendering, it is **state being replaced with an empty snapshot**.

Current clear paths (all are "replace all", not "append"):

1. **LogViewer `fetchMessages` polling** (`liveMessagesPollTimer` 1.8s while `liveRunning`) replaces `messages` with `filtered` derived from the last REST `?limit=20` snapshot. If that REST snapshot is temporarily empty / truncated under load (server still writing, SQLite WAL, or list pagination returns 0 rows for 300–800 ms), `messages = []` clears the historical tail. `displayItems` (messages + banners) becomes 0, and `hasLiveContent` may also be false during the same window → "0 msg 0 tools" empty state renders for ~1 poll interval.

2. **`isLoadingMore` / `hasMoreSessions` batch loading** in the left sidebar triggers `loadNextBatch()` on scroll. The batch uses a second `GET /sessions/.../list` and appends, but `loadedBatchCount` races with live `fetchRunHistory()` that does `liveEntries = capped` (replace). Under burst, the two histories race and the loser wins with an older empty slice.

3. **`resetLiveBuffer(for:)` on session switch** (`selectedSessionId` change) does `liveEntries[name]=nil`. If a provider error triggers a `run_banner` reinjection ("continue the tasks") while the same sessionID is still considered "new", the LogViewer may briefly treat the session as just-switched and clear live tail.

4. **Cap truncation** (`suffix(40)` / `suffix(200)`) is a *silent replace*. When 60 tool events arrive in 2 s, the oldest 20 are dropped in one coalesced update. Rendering sees a single atomic replace, not 20 appends, and SwiftUI diffing may recycle row IDs (`id:\.offset`) causing a perceived flash.

All are **full-replace where append was expected**.

---

## 2. Target: one centralized, append-only store

```
SubworkerManager (WS .run_log) ──► LivestreamStore (single source of truth)
                                       │  append-only, throttled, capped
                                       ├─► LogPopoverView (observes)
                                       └─► RunPopupView   (observes)
History REST (sessions/list + messages) ──► same store via merge, not replace
```

### 2.1 File

```
Sources/Livestream/
├── LivestreamStore.swift      // @MainActor ObservableObject, the only livestream state
├── LivestreamEntry.swift      // single enum + helpers (shared)
├── LivestreamParsing.swift    // todowrite / edit / write / toolIcon+color (shared)
└── LivestreamBanner.swift     // SwiftUI banner views (shared, size via modifier)
```

Alternatively keep one file `Sources/LivestreamStore.swift` if 4 files feels heavy — but the split keeps the banners testable in Previews.

### 2.2 State (append-only, never clear on burst)

```swift
@MainActor final class LivestreamStore: ObservableObject {
    struct AgentStream {
        var entries: [LivestreamEntry] = []   // ordered, append-only
        var version: UInt64 = 0               // monotonic, for diffing
        var cappedAt: Int = 0                 // how many dropped from head
    }
    @Published private(set) var streams: [String: AgentStream] = [:]
    @Published private(set) var todos: [String: [TodoItem]] = [:] // per-agent latest todowrite
    @Published private(set) var banners: [String: [RunBanner]] = [:]

    // Throttled Publisher for UI: emits at most 10 Hz per agent, coalesced
    let throttled = PassthroughSubject<String,Void>() // agentName

    func appendDelta(agent: String, field: String, delta: String) // dedup + suffix logic, single place
    func mergeHistory(agent: String, sessionId: String, rawMessages: [[String:Any]]) // appends history entries, updates todos, NEVER clears live tail
    func clear(agent: String, reason: String) // explicit, logged, only on session switch or explicit close
}
```

Invariants:

* `appendDelta` **never** sets `entries = []` or `entries = cappedHistory` — it only `append` or `replace last` (for coalesced reasoning/text). No code path does `liveEntries[agent] = historyEntries`.
* `mergeHistory` **merges**, not replaces: it diffs `rawMessages` against current `streams[agent].entries` by fingerprint (sessionId+partID) and inserts only missing history rows at the head, leaving the live tail intact. Live tools/text that are not yet in the REST snapshot are not dropped.
* `clear` is only called from `sessionRow` tap (explicit switch) or `subworkerCompleted` after 1.5 s — both log at `AppLog.d`. No implicit clear from polling or batch load.

### 2.3 Dedup + truncation (one place)

Move current `last_emitted` + `appendLiveDelta` guards into `LivestreamStore.appendDelta`:

```swift
- cumulative snapshot (delta.hasPrefix(cur)) → replace last with delta
- duplicate tail (cur.hasSuffix(delta) || (cur.contains(delta) && delta.count < 40)) → drop
- incremental slice → cur + delta
- cap text/reasoning at 12k → suffix 8k (same as now, but counted once)
- cap tools at 80 entries total, truncate head (+ `cappedAt` counter for "… N older" banner)
```

The truncated 800-char `todowrite` payload handling (`runScanTodosFromString` regex) moves to `LivestreamParsing.extractTodos(from:)` and is shared.

### 2.4 Rendering (shared vocabulary, size via modifier)

`LivestreamBanner.swift` exposes the same functions both views use today, but once:

* `toolIcon(_:)`, `toolDisplayName(_:)`, `toolColor(_:)`, `formatToolContent(...)`
* `todoWriteBanner(todos:compact:)`, `editDiffBanner(...)`, `writeFileBanner(...)`, `terminalBanner(...)`, `skillBanner(...)`
* `verticalTodoStrip(todos:expanded:)` (the left border strip) — one implementation, used by both (RunPopup 28→180 overlay, LogViewer 18→220 overlay)

Call sites pass `compact: Bool` to shrink fonts/padding for the Drop (8/7 pt vs 11/10 pt), but the parser and colors are identical.

### 2.5 Throttled rendering (the burst fix)

High-throughput failure today: 40 WS frames in 300 ms → 40 `objectWillChange` → 40 body recomputations → SwiftUI drops frames and the `ScrollViewReader` `proxy.scrollTo` races with `LazyVStack` recycling, producing the empty flash.

Fix in the store, not in the views:

```swift
// inside appendDelta
streams[agent].entries.append(...) // or replace last
throttleState[agent, default: 0] += 1
// debounce 80 ms
throttleWork[agent]?.cancel()
throttleWork[agent] = DispatchWorkItem { self.throttled.send(agent) }
DispatchQueue.main.asyncAfter(deadline: .now()+0.08, execute: throttledWork)
// view subscribes with .onReceive(store.throttled) { _ in proxy.scrollTo ... }
```

Views subscribe to `throttled` instead of to `streams` directly. This coalesces 40 deltas into ~4 renders, each an append, not 40 replace renders. The same throttle drives `isPinnedToBottom` scroll (only when pinned, like today).

Plus: use stable IDs (`partID` or `UUID` per entry, not `id:\.offset`) so `ForEach` does not recycle rows on cap truncation.

---

## 3. How history and live coexist without clearing

| Event | Today | After |
|---|---|---|
| App launch, no session yet | `fetchRunHistory` sets `liveEntries = cappedHistory` (replace) — wipes live tail if it already had 3 deltas | `mergeHistory` inserts history rows at head, live tail stays |
| Polling `GET .../messages?limit=20` while streaming | `messages = filtered` (replace entire historical pile, including tools that live already showed) → 0 during empty window | `store.mergeHistory` inserts missing historical rows at head; live entries are not in `messages`, they are in `streams[agent]` and rendered below `displayItems` |
| Session switch | `liveEntries[name]=nil` + `messages=[]` explicit | `store.clear(agent:reason:)` explicit, same but logged and animated, not via polling side-effect |
| Cap at 40/200 | `Array(suffix(40))` atomic replace → SwiftUI sees all rows replaced → flash | `entries.removeFirst(n); cappedAt+=n; throttled.send` → rows removed from head, tail appended, no full replace |

The "0 msg 0 tools for a few seconds" window is exactly the `messages = filtered` replace with `filtered=[]` when the REST snapshot is momentarily empty. After centralization, that path is `mergeHistory` which is a no-op (no new history rows, no clear), so the UI keeps its previous `messages` + `live tail` until the next non-empty snapshot arrives.

---

## 4. Migration plan (incremental, reversible)

### Phase 0 — instrumentation (no behavior change)

1. Add `AppLog.d("livestream.append agent=\(name) field=\(field) deltaLen=\(delta.count) entriesBefore=\(count)")` at top of both `appendLiveDelta`s and `AppLog.d("livestream.mergeHistory session=\(id) rawCount=\(n) filteredCount=\(m)")` in both `fetchMessages` paths.
2. Repro: trigger an agent that emits many tools (e.g. `refund-hunter` with grep+edit+write loop) and capture `/tmp/EliaTopBar.log` + time when "0 msg" appears. Confirm whether it correlates with a `rawCount=0` merge.
3. Add a temporary overlay label in both panels: `Text("\(store.streams[agent]?.entries.count ?? 0) live • \(messages.count) hist")` to see which zero flips.

### Phase 1 — extract shared types (no behavior change)

4. Create `Sources/Livestream/LivestreamEntry.swift`:
   ```swift
   enum LivestreamEntry: Equatable, Identifiable {
     case reasoning(id: String, text: String)
     case text(id: String, text: String)
     case tool(id: String, name: String, input: String?, output: String?)
     var id: String { ... }
   }
   struct TodoItem: Equatable { let content, status, priority: String }
   ```
   Copy helpers `toolIcon/toolColor/toolDisplayName/formatToolContent` and parsing (`extractTodos`, `parseEdit`, `parseWrite`, `hostPath`, `runScanTodosFromString`) from whichever file is newer (RunPopup's regex version wins). Keep both views compiling against their local copies, but new file is the canonical import.

5. Create `Sources/Livestream/LivestreamParsing.swift` with the shared parsers, unit-tested with the truncated 800-char fixture (input `"…` suffix). Add a Swift `Preview` that feeds the fixture and asserts 2 todos are still extracted.

### Phase 2 — introduce `LivestreamStore` (behavior change: append-only)

6. Create `Sources/Livestream/LivestreamStore.swift` as `@MainActor ObservableObject` with `streams`, `todos`, `appendDelta`, `mergeHistory`, `clear`, `throttled` publisher and 80 ms debounce. Move the dedup logic there verbatim, single copy. No view changes yet — just the store compiles.

7. Wire `SubworkerManager.handleWSMessage(.run_log)` to `store.appendDelta(agent:field:delta:)` **and** keep the existing `NotificationCenter.post(.SubworkerRunLog)` for one release (dual-write). This lets old views keep working while the new store is validated via logs.

### Phase 3 — switch LogViewer to the store (first consumer)

8. In `LogPopoverView`, replace `@State liveEntries` + `appendLiveDelta` + `extractTodosForLive` with `@StateObject var store: LivestreamStore` (or `@EnvironmentObject` injected from `EliaTopBarApp`). Subscribe:
   ```swift
   .onReceive(store.throttled) { agent in if agent==subworkerName { requestScroll(proxy:) } }
   ```
   `messagesPanel` renders `store.streams[subworkerName]?.entries` instead of `liveEntries[subworkerName]`. `fetchMessages` calls `store.mergeHistory(agent:sessionId:rawMessages:)` instead of `messages = filtered`.

9. Keep `sessions` sidebar and `messages` historical list as is for now, but `displayItems` becomes `messages (history) + store.streams` tail. Verify "0 msg" no longer appears via the instrumented log (poll with `rawCount=0` should be a no-op).

### Phase 4 — switch RunPopup to the same store (second consumer, then de-dupe)

10. In `RunPopupView`, delete its `liveEntries`, `appendLiveDelta`, `runExtractTodos`, `fetchRunHistory`/`fetchMessagesForHistory` duplication and subscribe to the same `store`. Its `observeLogs` is deleted — the store is the only observer of `SubworkerManager`. The todo strip now reads `store.todos[agentName]`.

11. Delete the duplicated banner helpers from both files; import from `LivestreamBanner.swift`. `compact: true` for the Drop, `compact: false` for the LogViewer.

### Phase 5 — delete the old paths and the dual-write

12. Remove `NotificationCenter` `runLogNotification` dual-write (or keep it as a deprecated shim for one release). Delete the local `appendLiveDelta`/`runScanTodosFromString` copies. `fetchRunHistory` is now just `store.mergeHistory` (single call). Verify both panels still render.

13. Add a SwiftUI Preview for `LivestreamStore` that replays a captured burst (40 tool events in 500 ms) and asserts `entries.count == 40` (or capped 80) and no zero-state frame was emitted (`XCTest` expectation: `store.$streams` never emits an empty array when previous count was >0 except via explicit `clear`).

---

## 5. What to verify before calling done

* **Burst test:** trigger `refund-hunter` (or any agent that does grep+edit+write in a loop) and watch both panels. Previously the "0 msg 0 tools" flash appears within 3–5 s of the first tool burst; after, it must not appear for 60 s of continuous streaming. Check `/tmp/EliaTopBar.log` for `clear` only on session switch.
* **Scroll pin:** scroll LogViewer up, let live continue — bottom arrow appears, no auto-jump; scroll to bottom or tap arrow → auto-scroll resumes. Same for Drop (new arrow behavior already added).
* **Session switch:** tapping a different session clears the live tail **once**, then shows that session's history + its own live tail. No ghost todos from the previous session (the per-agent `todos` map ensures it).
* **Truncated todowrite:** a todowrite with 7 todos clipped to 800 chars still shows 2+ todos in the strip (regex fallback). Compare Drop vs LogViewer — they must show the same dot colors/counts.
* **`swift build` + `swift build -c release --arch arm64` green, no `actor-isolated` warnings beyond the pre-existing one in `SubworkerManager.scheduleTimer`.**

---

## 6. Files to touch (ordered)

1. `Sources/Livestream/LivestreamEntry.swift` — new
2. `Sources/Livestream/LivestreamParsing.swift` — new
3. `Sources/Livestream/LivestreamStore.swift` — new
4. `Sources/Livestream/LivestreamBanner.swift` — new (or inline in Store for now)
5. `Sources/SubworkerManager.swift` — one line: call `store.appendDelta` in `handleWSMessage`
6. `Sources/LogPopoverView.swift` — replace live state with `store` observation
7. `Sources/RunPopupController.swift` — same, delete duplicated parsers
8. `docs/LIVESTREAM_TECHNICAL.md` — add §10 with the new file map

No server change. No `AppDelegate` menu change.

---

## 7. Primary-icon click closes Drops (setting)

When the user clicks the **primary menu-bar icon** (the brain / Elia icon that opens the dropdown), all open RunPopups (Drops) should be dismissed. This is controlled by a checkbox in **Topbar Settings**, default **ON**.

* **Setting:** `UserDefaults "closeDropsOnPrimaryClick"` — `Bool`, default `true` (missing key → `true`). Exposed as `Toggle("Close all Drops when opening menu")` in `TopbarSettingsView` → `Layout` or `Run animation` group. Changing it posts `Notification.Name.eliaCloseDropsOnPrimaryClickChanged`.
* **Trigger:** `EliaTopBarApp.AppDelegate.statusItem.button` target/action (or `NSMenuDelegate menuWillOpen`) — the single place that opens the main menu. Guard with the setting: if `closeDropsOnPrimaryClick` is `false`, do nothing; if `true`, call `RunPopupController.shared.closeAll()` on the main actor before showing the menu.
* **Controller:** add `RunPopupController.closeAll()` that iterates `panels.values`, invalidates `retractTimers`, `orderOut`, clears `panels/hoverStates/durations/noAutoClose`. No animation (instant) when triggered by primary click — the menu opening is the visual feedback. Log at `AppLog.d("primaryClick closeAll count=\(n) setting=\(on)")`.
* **Edge cases:** if a Drop is in `noAutoClose` (pinned), it is still closed — primary click is an explicit dismiss. If draggable Drops have been moved, their positions are not persisted. If no Drops are open, it is a no-op (no log spam).
* **Verification:** with setting ON, open 3 Drops, click primary icon → all 3 disappear before menu appears, `panelCount == 0`. With setting OFF, same scenario → Drops stay. Toggle persists across relaunch.

This is **orthogonal to the livestream store** — no dependency on `LivestreamStore`. It can land in Phase 0 or as a standalone commit before Phase 1.

---

## 8. Non-goals (explicitly out of scope)

* Server-side dedup or tool payload shape — already landed (per-field clip, `field="tool"` branch).
* Markdown parser rewrite — `streamingSafeMarkdown` + `MarkdownView` block cache stays.
* Session list pagination — left as is (limit 20 + 40 caps).

---

## 9. Decision needed before Phase 1

* Single file `LivestreamStore.swift` vs `Livestream/` folder — folder is preferred for maintainability (the Drop vs LogViewer size switch lives in Banner, not Store).
* `ObservableObject` vs `@Observable` (iOS 17) — stay on `ObservableObject` for macOS 13 deployment target.

Once approved, start with Phase 0 instrumentation on the next run.

