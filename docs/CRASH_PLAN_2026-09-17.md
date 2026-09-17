# Crash Plan — 2026-09-17 14:38 (NSException in SwiftUI layout)

## What happened
- App dead, fresh report `EliaTopBar-2026-09-17-143841.ips` (`bug_type 309`).
- Crash = `EXC_BREAKPOINT` / `SIGTRAP` on main thread via
  `+[NSApplication _crashOnException:]` — an uncaught **NSException**, not a
  Swift trap and not the old Combine stack overflow.
- Throw site: `-[NSWindow _postWindowNeedsUpdateConstraints]`, driven by a
  SwiftUI `NSHostingView` layout pass (`requestUpdate` → `setNeedsUpdateConstraints`
  → view-graph invalidate → `updateConstraints`). No EliaTopBar frame on the
  stack — the exception comes from AppKit/SwiftUI machinery itself.
- Timeline: crash ~5 min after 3 manual RunPopup panels were opened by dot-click
  (13:33 UTC trace) on top of 4 simultaneous auto-Drop panels. 7 live SwiftUI
  panels, each with 1 s / 1.5 s / 4 s repeating timers + streaming WS updates.

## Root-cause hypothesis (ranked)
1. **Layout request racing panel teardown (most likely).** A SwiftUI update
   posted before `orderOut` is processed during/after window teardown, and
   AppKit raises inside `_postWindowNeedsUpdateConstraints` on a window that is
   closing/closed. Uncaught ObjC exception = instant kill (no recovery possible
   in Swift).
2. **Panel accumulation raising the odds.** Manual miniBubble panels pass
   `disableAutoClose: true`, so they live forever with all live timers firing.
   Auto-drops piled up too (`panelsBefore=0→3` within one second in
   `/tmp/EliaTopBar.log`). More live panels = more constraint churn = more
   teardown races.
3. **Stale animation completions.** `retract()` animates 0.42 s then calls
   `close()` in the completion handler with no identity check — a completion
   from a superseded panel object can `orderOut`/nil state out from under a
   newer panel for the same agent.
4. Why now and not for weeks: requires the confluence (many simultaneous live
   panels + teardown racing an update). No code change identified as the single
   trigger; treat as a latent race exposed by load.

## Mitigation plan (in order)
1. **Safe teardown in `RunPopupController.close()`** (`Sources/RunPopupController.swift:70`):
   after `orderOut`, set `panel.contentView = nil` to detach the SwiftUI graph
   synchronously (forces `onDisappear` cleanup) before the window finishes
   tearing down.
2. **Identity-guard animation completions** in `retract()` (:64–68): capture the
   panel and only `close()` if `panels[name] === panel`, so stale completions
   no-op instead of closing a replacement panel mid-layout.
3. **Quiesce live timers at retract start**: stop the agent's subagent/traffic/
   status timers when retract begins (they currently fire through the 0.42 s
   animation and until `onDisappear`), shrinking the race window.
4. **Cap live panels**: enforce `maxConcurrentDrops` for manual panels too
   (auto-retract the oldest), and give manual panels a long retract timer
   (e.g. 60 s) instead of never closing.
5. **Capture the exact AppKit complaint**: install `NSSetUncaughtExceptionHandler`
   at launch logging name + reason + stack to `/tmp/EliaTopBar-exceptions.log`.
   It still dies on the next occurrence, but we learn the precise reason string
   (this report's stub did not include it).
6. Same `contentView = nil` treatment for the LogViewer popovers
   (`showSubviewerLogPopover` / `showLogs` in `Sources/EliaTopBarApp.swift`) —
   same NSHostingView-in-transient-container shape, same risk.

## Status: implemented in v2.0.4
- Items 1–3 (safe teardown, identity guard, cap) and 5 (exception trap) done.
- Cap set to 10 max (`runPopupMaxConcurrent`, hard ceiling).
- Item 4 (long retract timer for manual panels) deferred: manual panels stay
  persistent, cap handles accumulation. Item 6 (popover detach) done.

## Repro & verification
- Repro: DEBUG build, open 5+ panels (manual clicks + triggers), rapid
  open/close clicks while livestreams update; watch Console for NSException.
- Verification: 48 h with panels open and zero new `.ips` reports, plus
  `/tmp/EliaTopBar-clicks.log` showing clean retract/close cycles.
- No changes to the dot hit-test, viewer routing, icon pipeline, or any
  feature behavior — teardown-only changes.
