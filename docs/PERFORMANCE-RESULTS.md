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
| RSS after 100 popup cycles | 180.6 MB | **23.8 MB** |
| RSS after 100 log-viewer cycles | 484.0 MB | 46.0 MB |
| RSS after a 30 s drain | 394.7 MB | **39.4 MB** |
| Threads at end | 8 | 7 |

Baseline figures come from a worktree at `4c7c2c3` built with the same harness.

## 30-popup burst

`ELIATOPBAR_SELFTEST_BURST=30`, repeated to check for accumulation.

| | Before | After |
|---|---|---|
| `NSApp.windows` after burst 1 | 32 | 8 |
| after burst 2 | 62 | 8 |
| after burst 3 | 92 | 8 |
| after burst 4 | 122 | 8 |
| RSS per burst | +21.2 MB | **+21.2 MB — still growing** |

The window-list leak is fixed by `panel.close()` + `isReleasedWhenClosed = true`
(an `NSPanel` defaults to `false`, so `close()` never released it).

**The burst memory growth is NOT fixed.** `HoverPanel.liveCount` goes
0 → 30 → 60 → 90 → 120 across bursts and never drops: not one panel reaches
`deinit`. 8 bursts reached 200.5 MB, perfectly linear at 21.2 MB each.

Bisected to a minimal case: a bare `NSPanel` with **no** properties set — no
level, no collectionBehavior, no contentView, no SwiftUI — leaks identically
(29 of 30 per round, accumulating to 145 across five rounds). Ruled out by
direct experiment: the data path (server dead, same growth), pacing (250 ms
per cycle, same growth), the notch anchor panel (island off, same growth),
`orderFront` vs `orderFrontRegardless`, the `animator()` animation blocks
(removed entirely, same growth), and autorelease-pool draining.

So the retention is baseline AppKit behaviour for windows this process has
ordered in, not something `RunPopupController` configures. **Not measured:**
what actually holds them. Closing this needs either a minimal AppKit
reproducer outside this repo or an Instruments allocation trace.

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

Verified by running the shipping build for 25 s against the live server:
process alive, menu bar item present, no entries in
`/tmp/EliaTopBar-exceptions.log`, no crash reports in
`~/Library/Logs/DiagnosticReports`, and the drop-detection log still firing.

Live streaming, agent trigger/enable/disable, the log viewer, the server
controls and the run popup were not each exercised end-to-end by hand. The
stress harness does drive the popup and log-viewer show/close paths 200 times,
and the 30-popup burst drives the panel cap, but that is not a substitute for a
human clicking through the app.