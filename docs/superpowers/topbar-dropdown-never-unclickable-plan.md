# Plan — Topbar Dropdown Never Unclickable Again (v2 — after code audit 2026-09-04)

> Audited: Sources/EliaTopBarApp.swift (~1980L) + SubworkerManager.swift + LogPopoverView.swift
> Current: v1.5.6-ish watchdog + ensureStatusItemAlive already landed. Still fails ~20-30% after lid close/reopen + WiFi roam.

## What IS already implemented (don't redo)

- `ensureStatusItemAlive()` recreates NSStatusItem if `button==nil || window==nil`, reinstalls `target=self action=#selector(mainItemClicked) sendAction(.leftMouseUp)` + `updateStatusIcon()`.
- `setupMenu()` starts with `ensureStatusItemAlive()`, sets `statusItem.menu=nil` (popUp mode), rebuilds from cached `subworkers` + Colima + tunnel even when `wsConnected==false`.
- `throttledSetupMenu()` idempotent: bails if `isMenuOpen||popoverShown`, hash-dedups `name:enabled:running:nextRun` ^ instances.count, throttled 0.3s DispatchWorkItem.
- `mainItemClicked` self-heals: `ensureStatusItemAlive()` + sync `setupMenu()` if `mainMenu==nil||empty`, then `menu.popUp(at:in:)`.
- `startStatusItemWatchdog()` 60s Timer on `.common` checks `buttonNil/windowNil/menuEmpty/targetWrong/actionWrong`, logs to `~/Library/Logs/EliaTopBar/health.log` if `topbarHealthLog==true`, then `ensure+setupMenu`.
- Wake/display: `installWakeObservers()` on `screensDidWake/screensDidSleep/didWake/didBecomeActive/didChangeScreenParameters/clockChanged` → `handleDisplayChange` + `healAfterWake` (ensure+rescheduleTunnelPoll+forceReconnect+setupMenu).
- App Nap held via `beginActivity(.userInitiated|.idleSystemSleepDisabled)`; all timers added to `.common`.
- `Publishers.MergeMany` 10 publishers → `updateStatusIcon()+throttledSetupMenu()+reconcile`.
- `AppLog.debug=true` hardcoded, health.log path exists but 0B (flag off, never written since Aug 29 19:44).

## Why it STILL fails (remaining gaps vs earlier plan)

1. **Watchdog never fires when you need it** — `Timer.scheduledTimer` on RunLoop even with `.common` is still coalesced/suspended during lid-closed App Nap + display sleep. The 60s check doesn't run until you already clicked. Health.log stays 0B because `topbarHealthLog` defaults false and predicate `log show --predicate 'process == "EliaTopBar"'` fails for LSUIElement helper (must use `log stream` or `predicate 'sender == "EliaTopBar"'`).
2. **Network roam not healed** — `NWPathMonitor` in SubworkerManager only calls `forceReconnect()` on `.satisfied && !wsConnected`, but never calls `ensureStatusItemAlive()` or `throttledSetupMenu()`. WiFi cut/restore invalidates the statusItem button's window without a `screensDidWake` event.
3. **Display target incomplete** — observes `didChangeScreenParameters` but not `NSScreen.screensDidChangeNotification` nor `NSStatusBar.system` item-count changes. Unplug/plug monitor or resolution change can rebuild the system status bar without firing the observed notification.
4. **Click path races throttledSetupMenu** — `throttledSetupMenu()` bails if `isMenuOpen==true`. When WS flaps during `menuDidClose` → `throttledSetupMenu()` schedules rebuild but click arrives before workItem fires, `mainItemClicked` sees `mainMenu` still empty and rebuilds sync, but the pending throttled work later overwrites it with stale hash.
5. **No fallback if popUp fails** — `statusItem.menu=nil` is correct for popUp, but if `popUp` silently fails (button.window nil transient), there is no fallback `statusItem.menu = mainMenu` + `button.performClick(nil)` retry.
6. **Hash blind to connection state** — `lastMenuHash` only hashes `enabled/running/nextRun`. A `Disconnected` → `Connected` flip with same subworkers is deduped and menu never refreshes its header.

## Goal (same as before, stricter)

Dropdown is clickable and renders full list (active/inactive agents, server health, tunnel, Colima, settings) within 200ms of click, after any of: lid sleep/wake, WiFi off/on, display reconfigure, server restart, 24h background + App Nap. No restart required. Verifiable via health.log.

## Phase 0 — One-time audit logging (ship today, keep for 24h)

- Enable `topbarHealthLog` by default for this build (or set `UserDefaults.standard.set(true,forKey:"topbarHealthLog")` on launch). Fix predicate: instruct to `log stream --predicate 'process == "EliaTopBar" OR sender == "EliaTopBar"' --level debug` and `tail -f ~/Library/Logs/EliaTopBar/health.log`.
- Add `AppLog.d` at every `statusItem.button` access: log `buttonNil/windowNil/menuEmpty/targetWrong/actionWrong/button.superview==nil` in `mainItemClicked` entry, `watchdogCheck` entry, `handleDisplayChange`, `healAfterWake`, `forceMenuRebuild`.
- Add `os_signpost` interval around `mainItemClicked` → `popUp` to measure click-to-menu latency.

## Phase 1 — Make watchdog actually run during App Nap (1h, critical)

- Replace `Timer.scheduledTimer` watchdog with `DispatchSource.makeTimerSource(queue: .main)` (dispatch timers are not coalesced by App Nap the same way). Keep 60s interval, still check 5 invariants, still write health.log. Keep `.common` RunLoop timer as secondary but not primary.
- On `NSApplication.didBecomeActive` and `NSWorkspace.didWake`, immediately fire `watchdogCheck()` sync (not throttled) before any menu build.

## Phase 2 — Harden the click path (self-healing, sync, with fallback)

In `mainItemClicked` at the very top (before anything else):
```swift
watchdogCheck() // sync heal if needed
ensureStatusItemAlive()
if mainMenu==nil || mainMenu!.numberOfItems==0 {
  setupMenu() // sync, not throttled
  AppLog.d("click-heal rebuilt menu items=\(mainMenu?.numberOfItems ?? 0)")
}
```
After `menu.popUp`:
```swift
if !isMenuOpen { // popUp failed (window nil transient)
  AppLog.d("popUp failed — fallback to statusItem.menu assignment")
  statusItem.menu = mainMenu
  statusItem.button?.performClick(nil)
  DispatchQueue.main.asyncAfter(.now()+0.1){ self.statusItem.menu = nil }
}
```
- Never let `throttledSetupMenu` overwrite a sync rebuild: set `lastMenuHash` after sync rebuild and cancel pending `menuRebuildThrottleWorkItem`.

## Phase 3 — Fix throttling + publisher storm

- `throttledSetupMenu`: include `wsConnected/hasError/statusError/serverHealth.state` in hash so connection flips rebuild header.
- Change `Publishers.MergeMany` sink to debounce 0.3s properly: use `.debounce(for: .milliseconds(300), scheduler: RunLoop.main)` instead of manual DispatchWorkItem, or keep workItem but reset `lastMenuHash` on `forceMenuRebuild`.
- `forceMenuRebuild()` (toggled notification) should set `lastMenuHash=0` + `setupMenu()` sync, not throttled.

## Phase 4 — Observe the real invalidation events (missing notifications)

Add to `installWakeObservers`:
- `NSScreen.screensDidChangeNotification` (via NotificationCenter.default)
- `NSStatusBar.system` didChange via KVO or `NSApplication.didChangeScreenParameters` already covered but add `NSWorkspace.screensDidWake` already there
- `NWPathMonitor` pathUpdateHandler: on any transition `satisfied↔unsatisfied`, call `ensureStatusItemAlive()+throttledSetupMenu()` on main (not just forceReconnect).

Keep `handleDisplayChange` but make it call `ensure+watchdogCheck+throttledSetupMenu`.

## Phase 5 — Server restart isolation (already ~done, tighten)

- Assert `addSubworkerItems` never early-returns on `statusError` without rendering cached subworkers. Currently it shows error + returns only if `subworkers.isEmpty`; keep that but also show cached count in header: `Active Agents (n) — Disconnected`.
- `statusError`/`lastError` only affect server health section, never gate `mainMenu` existence.

## Phase 6 — Verification (repro checklist, 30 min)

Repro matrix (each: click icon within 2s, assert menu appears <200ms with full list):
1. `pmset sleepnow` 5s wake
2. WiFi off 10s → on
3. Unplug external monitor / change resolution
4. `docker restart elia-subworker-srv` (ws flap)
5. Background 2h (simulate: `caffeinate -d` off, leave app idle, then click)

Ship v1.5.7 with `AppLog.debug=false` but keep `topbarHealthLog` watchdog file. Health.log should show `watchdog heal ...` lines only when healing, otherwise silent. If any repro fails, capture `log stream` + health.log timestamp.

## Files to touch (only)

- `Sources/EliaTopBarApp.swift` (watchdog, mainItemClicked fallback, observers, throttledSetupMenu hash, forceMenuRebuild)
- `Sources/SubworkerManager.swift` (pathMonitor heal hook, scheduleTimer already .common)

## Non-goals

- No change to LogPopoverView scrolling (separate fix already landed).
- No Keychain migration for `EliaAuth.defaultToken` (separate security track).
- No new dependencies, no Xcode project.

## Ship

- `swift build -c release --arch arm64` + `build-app.sh v1.5.7` (ad-hoc sign, bundle AppIcon.icns)
- `cp -R EliaTopBar.app /Applications/ && open /Applications/EliaTopBar.app`
- `defaults write com.elia.elia-topbar topbarHealthLog -bool true && tail -f ~/Library/Logs/EliaTopBar/health.log`
