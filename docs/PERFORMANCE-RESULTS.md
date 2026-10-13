# Performance results — v2.1.9

Every number below was observed on this machine. Where something could not be
measured, it says so rather than estimating.

Baseline is `PERFORMANCE-BASELINE.md` (commit `4c7c2c3`).

## Idle

| Metric | Baseline | After | Method |
|---|---|---|---|
| Idle CPU% | 0.00 | 0.00 | `top -l 3 -pid` |
| RSS | 254 MB | 78 MB | `ps -o rss` |
| Physical footprint | 206 MB | **23 MB** | `footprint -p` |
| Threads | 7 | 8 | `top -stats threads` |
| `/tmp/EliaTopBar.log` | 4.24 MB and unbounded | 0.80 MB, capped at 2 MB | `stat -f%z` |
| Power assertion | `PreventUserIdleSystemSleep` held forever | **none while idle** | `pmset -g assertions` |
| Idle CPU% while a popover was open | 2.00 | 0.00 | `top -l 3 -pid` |

The assertion was `.userInitiated` + `.idleSystemSleepDisabled`, begun at
launch and never ended — the highest-priority nap assertion there is. It is now
held only while a menu, popup, panel, settings window or running agent needs
live updates, and re-acquired in `applicationDidBecomeActive`.

## 200k log lines

```
swift run -c release PerfTests
  200k lines -> 1073841 bytes (1048 KB) in 1.74s
```

Under the 2 MB cap. Before: no cap existed, so the file grew by roughly the
full line count.

## 100 popup cycles + 100 log-viewer cycles

Driven by `ELIATOPBAR_SELFTEST_CYCLES=100`, which calls the same
`RunPopupController.show` / `showSubworkerLogPopover` / `closeAllLogPopovers`
the menu items call.

| | Baseline | After |
|---|---|---|
| RSS after 100 popup cycles | 180.6 MB | **24.7 MB** |
| RSS after 100 log-viewer cycles | 484.0 MB | 43.8 MB |
| RSS after a 30 s drain | 394.7 MB | **39.4 MB** |
| Threads at end | 8 | 7 |

Baseline figures come from a worktree at `4c7c2c3` built with the same harness.

> Correction: an earlier run of this table reported 23.8 MB after 100 popup
> cycles. That number was meaningless — the harness passed `duration: 0` to
> `show()`, which aborts on zero, so every popup cycle silently did nothing.
> The harness now passes a real duration and `pooled=1` in the output confirms
> panels are actually being created. The 24.7 MB above is a real measurement.

## 30-popup burst

`ELIATOPBAR_SELFTEST_BURST=30`, repeated to check for accumulation.

| | Before | After |
|---|---|---|
| RSS after burst 1 | 45.3 MB | 29.7 MB |
| RSS after burst 10 | 218.0 MB | 32.0 MB |
| Growth across 300 popups | +173 MB | **+2.3 MB** |

This leak is now fixed. Two causes, found by bisecting one variable at a time:

**1. The `NSPanel` objects were never freed.** A closed, invisible,
content-less panel that was *never even ordered in* was still alive 30 s
later. `leaks` classified the memory as **reachable**, not leaked, so
something held a live reference. Ruled out by direct experiment: the data
path (server dead, same growth), pacing (250 ms/cycle, same growth), the
notch anchor panel (island off, same growth), `orderFront` vs
`orderFrontRegardless`, the `animator()` animation blocks (removed
entirely, same growth), autorelease-pool draining, and panel configuration
(`level`, `collectionBehavior`, `contentView`, SwiftUI content).

Because AppKit will not release them, the fix is to stop creating them.
`close()` now retires the panel into a pool and `show()` takes one from
there, capped at 12 for the life of the process.

**2. Every popup built a new SwiftUI render graph.** With the panel pooled
but the content rebuilt each time, memory was flat at 20 MB with the
content omitted and still grew 19 MB per burst with it present — so the
whole remainder was the view graph. `show()` now reuses the existing
`NSHostingView` and swaps its `rootView` instead of instantiating a new one.

## Regression suite

`swift run -c release PerfTests` → **12 passed, 0 failed**, exit 0.

XCTest and Swift Testing are both unavailable on this machine (Command Line
Tools only; `_Testing_Foundation` ships without a swiftmodule), so the suite is
an executable target that asserts and exits non-zero.

It covers the log cap, the in-memory buffer bound, that trimming keeps the
*newest* lines, that `log()` does no file I/O on the calling thread, and — for
the two timer leaks — that an abandoned repeating `Timer` keeps firing forever
while a stored, invalidated one stops. That last pair is the leak being fixed,
asserted directly rather than inferred from a count.

## What did not produce a win

- **15 fps running-icon timer.** Already correctly gated on
  `runningCount > 0`; no change made.
- **Tunnel status polling.** Skipping the network call while no menu is open
  is correct in principle, but the 30 s cadence is low enough that it is not
  visible in any measurement here. Kept — it costs one request per 30 s.
- **MarkdownView block cache / GrokStyles frame cache.** Both already bounded
  (200 entries; 512 phase buckets). No change needed.
- **`~/Library/Application Support/EliaTopBar` (18 MB).** All of it is
  `agent_photos`, which is user-supplied content, not cache. Deleting it would
  delete the user's avatars. The real problem was decode cost, fixed below.

## Avatars

`ProfilePhotos.photo(for:)` used `NSImage(contentsOf:)`, which fully decodes
the source. The largest agent photo is 3.4 MB — roughly 48 MB decoded in RGBA —
and `circularPhoto` was called from SwiftUI `body` at **size 16**, so a menu row
could re-decode a multi-megabyte PNG on every body evaluation.

Now decoded via `CGImageSourceCreateThumbnailAtIndex` at the size actually
drawn, behind an `NSCache`. Storing the originals at full resolution is
unchanged, because they are the user's files.

**Not measured:** the resulting RSS delta in isolation. Idle footprint moved
206 MB → 23 MB overall, but that figure combines every change above and cannot
be attributed to the avatar path alone.

## Behaviour preserved

Verified by running the shipping build against the live server, plus a
screenshot of popups on screen: the header rendered the correct agent name,
with its state dot and live badge, and a recycled panel showed the *new*
agent rather than the previous one.

Panel reuse is the riskiest change here, so it is asserted rather than assumed.
`verifyBindings()` checks on every stress checkpoint that no panel is still
wired to the previous agent's view and that the panel and view maps have not
diverged. Across 5 bursts and 30 cycles using a distinct agent name each cycle:

```
bind=[wrongAgent=0 orphanViews=0 orphanPanels=0]
```

**Not measured:** a human clicking through live streaming, agent
trigger/enable/disable, the server controls and the log viewer. The harness
drives the popup and log-viewer show/close paths 200 times and the panel cap
under burst, but that is not a substitute for using the app.