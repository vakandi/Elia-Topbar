# Performance baseline — v2.1.9

Captured **before** any performance work, on the tree at commit `4c7c2c3`
(the in-flight work tree, committed first so the perf pass has a revert point).

Machine: MacBook Pro, Apple M5, macOS 26.2, Command Line Tools only (no Xcode).
Subworker server `localhost:5656` was up with 22 agents, so this is the
real operating condition, not an idle-no-server best case.

## Commands

```bash
cd ~/Documents/EliaTopBar && ./build-app.sh v2.1.9
open EliaTopBar.app
PID=$(pgrep -f "EliaTopBar.app/Contents/MacOS/EliaTopBar")

top -l 3 -pid $PID -stats pid,cpu,mem,threads
footprint -p $PID
ls -lh /tmp/EliaTopBar.log
pmset -g assertions
```

## Idle, ~30 s after launch (menu bar only, no popup open)

| Metric | Value | Source |
|---|---|---|
| Idle CPU% | 0.00 | `top -l 3 -pid` |
| RSS | 254 MB | `ps -o rss` |
| Physical footprint | 206 MB | `footprint -p` |
| Threads | 7 | `top -stats threads` |
| `/tmp/EliaTopBar.log` | 4.24 MB | `stat -f%z` |
| Power assertion | `PreventUserIdleSystemSleep 00:00:54` "EliaTopBar status-bar live updates" | `pmset -g assertions` |

The log was already 4.24 MB minutes after launch and had **no size cap** —
it grows for the lifetime of the boot.

## Leak reproducers

GUI automation cannot reach a `LSUIElement` status item
(`System Events` → process has one menu bar and no menu bar item 2), so the
cycles are driven through the app's own entry points by the stress harness
added in `Sources/SelfTest.swift`, gated on env vars and inert otherwise.

The harness was added **after** this baseline. To get a true before/after for
the popups it reproduces, a git worktree at `4c7c2c3` was built with the same
harness patched in. Those numbers are in `PERFORMANCE-RESULTS.md`.

## Pre-existing problems confirmed in this tree

1. `RunPopupController.startTick()` — `Timer.scheduledTimer(...)` with no
   stored reference. Nothing could ever invalidate it.
2. `LogPopoverView.startLiveTick()` — `let timer = Timer(...)`, a local. No
   `liveTickTimer` property and no `stopLiveTick()` existed.
3. `logDrop(_:)` — four synchronous `FileHandle` ops **on the main thread**
   per line, no cap, no rotation. Two copies of it existed (one in
   `EliaTopBarApp`, one in `RunPopupController`).
4. `LogPopoverView.releaseResources()` did not exist; observer removal only
   happened in `onDisappear`, which is skipped when the popover's
   `contentViewController` is nil'd.
5. `AppLog` already capped at 2 MB and was `#if DEBUG` gated, but
   `health.log` (written by `watchdogCheck`) had **no cap at all**.