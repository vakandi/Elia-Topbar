# Overnight prompt — make EliaTopBar the lightest, fastest Swift app it can be

> Copy everything below this line into a fresh agent session working in
> `~/Documents/EliaTopBar`. Do not read this file's preamble again; the prompt is
> self-contained.

---

You are working on **EliaTopBar**, a native macOS menu bar app (Swift 5.9, macOS 13+,
`LSUIElement=true`, no dock icon). It is the control surface for the Elia agent ecosystem:
it runs and monitors the OpenCode Rust server, and shows and controls agents.

**The problem:** macOS energy diagnostics consistently report EliaTopBar as one of the
highest battery consumers. It is a menu bar app that should be nearly free. Users observe
three concrete symptoms:

1. **Lag after repeated use.** Opening and closing the run popup or the log viewer many
   times makes the app progressively slower and eventually visibly stutter.
2. **Many simultaneous popups break it.** If run popups are triggered while agents are
   running — the drop animation spawns one per agent — a burst can produce ~30 run popups
   at once, and the app loses track of them and degrades badly.
3. **Disk usage grows without bound** over long uptime.

Your job is to fix the real causes, not to paper over them, and to leave the app
*measurably* lighter in **CPU, RAM, disk and battery**.

---

## Ground rules — read before touching anything

1. **Measure before and after.** Every claim you make about a saving must be backed by a
   number you actually observed. "This should be faster" is not a result.
2. **Never remove a feature to win a benchmark.** If a fix would drop live streaming,
   agent control, the log viewer or server management, find another way.
3. **Never kill a process you did not start.** When you clean up stray processes during
   testing, only ever target ones you launched, and record their PIDs first.
4. **Do not touch `~/Documents/subworker-opencode-rust` or `~/Documents/opencode-rust`.**
   They are separate repositories. EliaTopBar only talks to the built server binary.
5. **Build early and often.** After every change: `./build-app.sh v2.1.9`. A clean build
   with no `error:` lines is the minimum bar. Note that this machine has Command Line
   Tools without Xcode, so the script always prints an `xcbuild` error and falls back to an
   arm64-only build — **that message is expected and pre-existing, not your bug.**
6. **Leave the tree committed in small, reviewable commits** with messages that state the
   measured effect, not just the change.

---

## Phase 0 — Baseline (do not skip this)

Before changing code, establish a baseline you can compare against. Write the numbers down.

```bash
# Build and run the app so you are measuring the shipping configuration.
cd ~/Documents/EliaTopBar && ./build-app.sh v2.1.9
open EliaTopBar.app      # record the PID: pgrep -f EliaTopBar.app
```

Record, for the **idle** app (menu bar only, no popup open) and again after driving the
popup and log viewer in a loop:

- **Idle CPU%** — `top -l 3 -pid <PID> -stats pid,cpu,mem,threads | tail -3`
- **Idle RSS** — `footprint -p <PID>` (gives real + compressed, which is what the OS bills)
- **Thread count** — `top -l 1 -pid <PID> -stats threads`
- **Log size** — `ls -lh /tmp/EliaTopBar.log`
- **Wakeups** — `pmset -g assertions` and Activity Monitor's "Wakeups" column if available

Then drive the leak reproducers **100 times each** and re-measure:

```bash
# roughly: open and close the run popup 100 times, and the log viewer 100 times,
# then compare RSS and thread count against the baseline.
```

Write `docs/PERFORMANCE-BASELINE.md` with the before numbers and the exact commands used.
Every later claim cites this file.

---

## Phase 1 — The three confirmed leaks

These were found by reading the code and are the highest-confidence wins. **Verify each one
still exists in the current tree before fixing it** — the file may have moved. Each has a
matching regression test you must write.

### 1.1 `RunPopupController.startTick()` leaks a timer per open/close

`Sources/RunPopupController.swift` — `startTick()`:

```swift
private func startTick(){ Timer.scheduledTimer(withTimeInterval:1.0, repeats:true){ _ in if liveRunning { liveTick+=1 } } }
```

The `Timer` is **constructed and thrown away**. Nothing stores a reference, so nothing can
ever invalidate it. The view's `onDisappear` cleanup invalidates `trafficTimer`,
`statusTimer` and the subagent poll timers — but **not this one**.

Consequence: every time a run popup appears and disappears, a permanent 1-second repeating
timer is registered on the main run loop forever, still mutating `liveTick` on a view that
no longer exists. After 100 open/close cycles you have 100 timers firing every second.

**Fix:** store it in a property (e.g. `private var liveTickTimer: Timer?`), invalidate the
previous one before starting a new one, and invalidate it in `onDisappear` next to the
existing cleanups.

**Test:** a regression test that opens/closes the popup N times and asserts the timer count
for the owner does not grow with N.

### 1.2 `LogPopoverView.startLiveTick()` leaks a timer *and* retains the whole view

`Sources/LogPopoverView.swift` — `startLiveTick()`:

```swift
private func startLiveTick() {
    let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
        if self.liveRunning { self.liveTick += 1 }
    }
    RunLoop.main.add(timer, forMode: .common)
}
```

`timer` is a **local variable**. There is no `stopLiveTick()` and no `liveTickTimer`
property anywhere in the file — there is no way to stop it. The closure captures `self`
strongly, so every open leaves both a live 1-second timer *and* a strong reference to the
entire popover view alive. This is a genuine retain cycle plus an unstoppable timer.

Compare the function directly below it, `startLiveMessagesPolling()`, which does the right
thing by assigning `liveMessagesPollTimer = t`. That is the pattern to follow.

**Fix:** store the timer in a property, invalidate the previous one, and add a
`stopLiveTick()` that is called on close. Ensure the closure does not create a cycle.

**Test:** open/close the log viewer N times, assert the instance deallocates and the timer
count does not grow. Use `weak var probe` and `XCTAssertNil(probe)` after the last close.

### 1.3 `logDrop` writes an unbounded log file on the main thread

`Sources/EliaTopBarApp.swift` — `logDrop(_:)`:

```swift
let line = "[\(Date())] \(msg)\n"
... FileHandle(forWritingTo: url) → seekToEndOfFile() → write → close
```

It appends to `/tmp/EliaTopBar.log` with **no size cap and no rotation**. The file is
already several megabytes on a machine that has not been up long, and it grows for the
lifetime of the boot. Worse, every drop does four synchronous file operations **on the main
thread**, which is exactly the path that runs while a drop animation is playing.

**Fix:**
- Cap the file (e.g. keep the last ~1–2 MB) by truncating or rotating when it exceeds a limit.
- Move the write **off the main thread** — buffer lines in memory and flush on a background
  queue, coalescing bursts. A drop burst of 30 popups must not mean 30 main-thread file
  writes.
- Consider dropping the duplicate `print()` in release builds.

**Test:** generate 200k drop lines and assert the file never exceeds the cap.

---

## Phase 2 — Burst safety (the "30 popups" symptom)

When many agents start at once, the drop animation spawns one popup per agent and the app
loses track.

Audit and fix:

1. **The cap is `maxPanels`, capped at 10** in `show(for:dropX:duration:...)`
   (`RunPopupController.swift`). Confirm the eviction path when the cap is hit actually
   releases the evicted panel's **timers and NotificationCenter observers** — evicting the
   panel from the dictionary while its timers keep running is the same leak as Phase 1.
2. **Every `addObserver` must have a matching `removeObserver`**, including the three in
   `RunPopupController` and the live-start/live-complete pair in `LogPopoverView`. Audit
   every add/remove pair in the app and make the counts match per view lifecycle.
3. **Bound the animation fan-out.** A burst should coalesce, not queue 30 independent
   animations. Decide and implement a policy: show the newest N, collapse the rest into a
   summary row, or defer them. State the policy in the commit message.
4. **Audit `subagentPollTimers` and `retractTimers`** — both are dictionaries keyed by agent
   or session. Confirm entries are removed on completion, not only on clean close. A long
   burst with many session keys is an unbounded dictionary.

---

## Phase 3 — Idle cost reduction

Target the background work that runs whether or not the user is looking.

1. **Audit every timer in the app.** There are roughly a dozen across
   `EliaTopBarApp.swift`, `LogPopoverView.swift`, `RunPopupController.swift`,
   `SubworkerManager.swift`, `ColimaManager` and `OpenCodeServerManager`. For each,
   record: interval, what triggers it, whether it is invalidated, and whether it needs to
   run when no window is visible.
2. **Suspend polling when nothing is displayed.** When no popup, popover, menu or panel is
   visible and no agent is running, drop to a slow heartbeat. Polling a hidden UI is pure
   waste. Keep liveness guarantees for anything the menu bar itself displays.
3. **The running-agent icon animates at 15 fps** (`1.0/15.0` in `EliaTopBarApp.swift`).
   Only run that timer while an agent is actually running, and invalidate it the moment the
   last one stops.
4. **Coalesce redraws.** The menu bar redraws on many independent publishers; make sure a
   burst of state changes causes one frame, not one frame per change.
5. **Prefer one shared timer** driving a switch over many independent timers. Independent
   timers drift and each one wakes the process.

---

## Phase 4 — Memory and disk

1. **Measure with `footprint`, not `ps`.** `footprint -p <PID>` reports compressed and real
   memory separately; the OS bills the larger of the two for jetsam purposes. Target the
   number macOS actually charges.
2. **Bound every cache.** Look for unbounded arrays/dictionaries holding messages, logs,
   session keys or image data. Give them explicit caps and an eviction policy.
3. **Images and avatar loading** — verify photos are downsampled to the size actually drawn
   and are not re-decoded per frame.
4. **Disk:** cap `/tmp/EliaTopBar.log`, and audit the 18 MB in
   `~/Library/Application Support/EliaTopBar` — decide what is cache (prunable) versus
   configuration (must keep), and add a prune step if the cache dominates.

---

## Phase 5 — Verify and report

Before you call it done, produce `docs/PERFORMANCE-RESULTS.md`:

| Metric | Baseline | After | Method |
|---|---|---|---|
| Idle CPU% | | | `top -l 3 -pid` |
| Idle RSS (footprint) | | | `footprint -p` |
| Threads | | | `top -stats threads` |
| RSS after 100 popup open/close | | | repro script |
| RSS after 100 log viewer open/close | | | repro script |
| Timer count after 100 cycles | | | test |
| `/tmp/EliaTopBar.log` after 200k drops | | | repro script |
| Wakeups/hour | | | `pmset -g assertions` |

Rules for this report:
- Every cell is a number you actually observed, with the command that produced it.
- If you could not measure something, write **"not measured"** and say why. Never estimate.
- If a phase produced no measurable win, say so plainly and either revert it or explain why
  it is still worth keeping. Do not keep changes justified only by intuition.

---

## Definition of done

- [ ] `./build-app.sh v2.1.9` completes with no `error:` lines
- [ ] No timer in the codebase is created without a stored reference and an invalidation path
- [ ] Every `addObserver` has a matching `removeObserver` on the same lifecycle
- [ ] `/tmp/EliaTopBar.log` is size-capped and written off the main thread
- [ ] A burst of 30 popups stays bounded and cleans up fully
- [ ] Polling suspends when nothing is visible
- [ ] `docs/PERFORMANCE-BASELINE.md` and `docs/PERFORMANCE-RESULTS.md` exist and contain
      real measurements
- [ ] Regression tests cover each leak you fixed
- [ ] Existing behaviour is unchanged: live streaming, agent trigger/enable/disable, the log
      viewer, the server controls, and the run popup all still work

---

## Things that will bite you

- **`EliaTopBarApp.swift` is 3161 lines** and is a God object containing the AppDelegate,
  menu construction, icon rendering, hover handling and every UI callback. Editing it is
  fine; do not attempt a broad refactor in the same pass as the performance work, or you
  will not be able to tell which change caused a regression. If you must split it, do it in
  a separate commit with the app fully working in between.
- **The SwiftUI view lifecycle is the trap.** `onDisappear` does not always fire when a
  panel is torn down via `contentView = nil`. Do not rely on it as the only cleanup path;
  make the teardown path itself release resources.
- **Timers on the main run loop in `.common` mode keep firing when a menu is open.** Closing
  a popover is not enough to stop them; they must be invalidated.
- **Do not "fix" a leak by adding a `DispatchQueue.main.asyncAfter` to clean up later.** That
  just moves the leak and adds a race.
- Swift concurrency warnings already present in the build (`Sendable`, actor isolation) are
  **pre-existing**. Do not chase them as part of this work, but do not make them worse.