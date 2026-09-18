# Plan — Overflow detection + agents LEFT of notch

## 1. Goal
Detect when EliaTopBar right-side icons are pushed off-screen (too many agents = too much width, Stats/other apps take the space), report it, and render agents in a notch-centered island with icons on the LEFT wing. New Topbar Settings option `agentIconsPlacement`: `left` (default ON per Wael) / `auto` / `right`.

## 2. Detection (right side)
- `NSStatusItem.isVisible` is USELESS (returns true even when clipped by notch/crowding — Apple docs + Ice/Thaw confirm).
- Real signal: observe `NSWindow.didChangeOcclusionStateNotification` on each `statusItem.button.window`, check `occlusionState.contains(.visible) == false` while `isVisible == true` = force-hidden by system (Apple FB7087526 workaround). Debounce ~1s (display reconfig noise) like Thaw `ControlItemOcclusion.Evaluator`.
- Backups: 5s poll of occlusionState + garbage-frame tell (blocked item window height 22 / origin `(0,-17)` vs hosted 33 on Tahoe); width estimate `agents * (dot+pad)` vs `screen.visibleFrame` as early warning.
- Report: `isOverflowed` bool in AppDelegate → menu banner row "⚠️ Icons hidden — N agents moved LEFT", `UNUserNotification` once per transition, `AppLog` + `/tmp/EliaTopBar.log`, optional auto-switch when placement=`auto`.

## 3. LEFT island (open-vibe-island pattern, no NSStatusItem)
- New `NotchIslandController`: borderless `NSPanel` (`.borderless`, `.nonactivatingPanel`), `level = .statusBar`, `collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle, .stationary]`, transparent, fixed max size, all animation inside SwiftUI.
- Position: `x = screen.frame.midX - w/2`, `y = screen.frame.maxY - h` (top-center, NOT right). Target screen: first `safeAreaInsets.top > 0`, else `NSScreen.main`.
- Geometry: `notchSize.height = safeAreaInsets.top` (~32-38); `notchWidth = frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width + 4` (macOS 14+ API); non-notch fallback 190×38. Closed pill width = `notchWidth + 88` (44pt LEFT wing + 44pt RIGHT wing).
- LEFT wing content: running-agent dots (monogram + state color, existing `updateStatusIcon` renderer reused at 24pt) + `UnifiedBars`-style pulse; RIGHT wing: count/error badge; center: nothing (notch covers it). Opened state expands downward like current Drop panels.
- Click LEFT dot = same as today (LogViewer popover anchored under island); hover = live log overlay. Reuse `RunPopupController` panel style (level `.statusBar` already proven over fullscreen video).

## 4. Settings (TopbarSettingsView)
- Segmented `Agent icons`: `Left (default)` / `Auto` / `Right`. Keys: `agentIconsPlacement` (default `left`), `overflowAutoSwitch` (default true when auto). Live preview: mini notch bar with dots left vs right.
- `left`: right `NSStatusItem`s removed (keep ONE minimal primary for menu access) + island always on. `auto`: island appears only when `isOverflowed==true`, retracts when clear. `right`: current behavior (legacy).
- Profiles: Minimal forces `left` (dots only, no Drops) — kills the width problem at the source.

## 5. Files to touch (minimal)
- `Sources/EliaTopBarApp.swift`: add `OverflowMonitor` (observer+poll), `isOverflowed` state, show/hide island, menu banner row.
- NEW `Sources/NotchIslandController.swift` + `Sources/NotchIslandView.swift` (panel + SwiftUI pill, ~300L total).
- `Sources/TopbarSettingsView.swift`: placement segmented control + preview.
- Zero changes to SubworkerManager/Colima/RunPopup.

## 6. Verify
- `swift build`, `./build-app.sh`, overflow simulated by shrinking visibleFrame / spawning 10 fake dots → banner + notification + island appears; click dot → LogViewer; setting Left/Right/Auto each respected; `open` screenshot PNG proof (never inline).
