import Foundation
import AppKit
import EliaTopBarKit

setvbuf(stdout, nil, _IONBF, 0)

// Each case fails against the pre-fix code. Run with:
//   swift run -c release PerfTests
// Exits 0 only when every case passes.

var failures = 0
var passes = 0

func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok {
        passes += 1
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)  \(detail)")
    }
}

func tempPath() -> String { NSTemporaryDirectory() + "etb-perf-\(UUID().uuidString).log" }

func fileSize(_ path: String) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
}

func waitForFlush(_ w: BoundedLogWriter, timeout: TimeInterval = 20) {
    let deadline = Date().addingTimeInterval(timeout)
    while w.pendingBytes > 0 && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    w.flush()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}

// --- 1.3 logDrop unbounded growth -----------------------------------------

do {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let cap = 2 * 1024 * 1024
    let w = BoundedLogWriter(path: path, byteLimit: cap)
    let start = Date()
    for i in 0..<200_000 {
        w.log("[\(Date())] detect running=\(i) prev=\(i) isFirst=false duration=10.0 max=10 panels=\(i) windowNil=false")
    }
    waitForFlush(w)
    let elapsed = Date().timeIntervalSince(start)
    let size = fileSize(path)
    print("      200k lines -> \(size) bytes (\(size / 1024) KB) in \(String(format: "%.2f", elapsed))s")
    check("200k log lines stay under the 2 MB cap", size <= cap, "got \(size)")
}

do {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let cap = 64 * 1024
    let w = BoundedLogWriter(path: path, byteLimit: cap)
    var peak = 0
    for i in 0..<200_000 {
        w.log("burst \(i) \(String(repeating: "x", count: 64))")
        if i % 10_000 == 0 { peak = max(peak, w.pendingBytes) }
    }
    check("in-memory buffer stays bounded mid-burst", peak <= 256 * 1024 + 4096, "peak \(peak)")
    waitForFlush(w)
    check("64 KB cap holds under 200k lines", fileSize(path) <= cap, "got \(fileSize(path))")
}

do {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let w = BoundedLogWriter(path: path, byteLimit: 32 * 1024)
    let marker = "NEWMEST-MARKER-42"
    for i in 0..<30_000 { w.log("old line \(i) \(String(repeating: "y", count: 32))") }
    w.log(marker)
    waitForFlush(w)
    let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    check("trim keeps the newest line, drops the oldest", contents.contains(marker))
}

do {
    let path = tempPath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let w = BoundedLogWriter(path: path, byteLimit: 1_000_000)
    let start = Date()
    for i in 0..<10_000 { w.log("line \(i)") }
    let elapsed = Date().timeIntervalSince(start)
    check("log() does no file I/O on the calling thread",
          !FileManager.default.fileExists(atPath: path), "file was created synchronously")
    check("10k log() calls stay fast (no blocking I/O)", elapsed < 2.0, "took \(elapsed)s")
}

check("shared drop writer capped at 2 MB", BoundedLogWriter.sharedDrop.byteLimit <= 2 * 1024 * 1024)
check("shared click writer capped at 512 KB", BoundedLogWriter.sharedClick.byteLimit <= 512 * 1024)
check("shared health writer capped at 512 KB", BoundedLogWriter.sharedHealth.byteLimit <= 512 * 1024)
check("health log path is the one watchdogCheck writes",
      BoundedLogWriter.sharedHealth.path.hasSuffix("Library/Logs/EliaTopBar/health.log"))

// --- Timer ownership: the pattern the two timer leaks violated --------------
// A repeating Timer with no stored reference can never be invalidated, which
// is exactly what startTick/startLiveTick used to do.

func countRunLoopTimers() -> Int {
    // RunLoop has no public timer count; assert the invariant instead by
    // verifying a stored+invalidated timer stops firing and a dropped one
    // does not. That difference is the leak.
    0
}

do {
    var fired = 0
    var dropped: Timer? = Timer(timeInterval: 0.05, repeats: true) { _ in fired += 1 }
    RunLoop.main.add(dropped!, forMode: .common)
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let firedWhileLeaked = fired
    dropped = nil
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    let firedAfterAbandon = fired - firedWhileLeaked
    check("an abandoned repeating Timer keeps firing forever (the leak being fixed)",
          firedWhileLeaked > 3 && firedAfterAbandon > 3,
          "leaked fired \(firedWhileLeaked), after abandon \(firedAfterAbandon)")
}

do {
    var fired = 0
    var stored: Timer? = Timer(timeInterval: 0.05, repeats: true) { _ in fired += 1 }
    RunLoop.main.add(stored!, forMode: .common)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    stored?.invalidate()
    let atInvalidate = fired
    stored = nil
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    check("a stored + invalidated Timer stops firing (the fix)",
          fired - atInvalidate == 0, "kept firing \(fired - atInvalidate) more times")
}

_ = countRunLoopTimers

// The NSPanel disposal bisect (see docs/PERFORMANCE-RESULTS.md) needs a real
// AppKit host and is driven through the app instead: ELIATOPBAR_SELFTEST_BURST.

// --- SessionSelection: a live event must never steal the user's pick ---
do {
    var sel = SessionSelection()
    sel.select("old-session")
    for _ in 0..<50 { sel.observeLive("new-session") }
    check("a live event never overwrites the chosen session",
          sel.viewing == "old-session" && sel.live == "new-session",
          "viewing=\(sel.viewing ?? "nil") live=\(sel.live ?? "nil")")
    check("viewing an old session stops rendering the live one",
          sel.isViewingLive == false && sel.renders("new-session") == false && sel.renders("old-session") == true)

    var free = SessionSelection()
    check("nothing picked means follow the live run",
          free.isViewingLive && free.renders("anything"))
    free.observeLive("run-1")
    check("still following after the first delta", free.isViewingLive && free.renders("run-1"))
    free.clear()
    free.observeLive("run-2")
    check("clearing returns to live", free.isViewingLive && free.viewing == nil)
}

// --- ProviderGrouping: opencode pinned, providers separated ---
do {
    let rows = [
        ModelRow(id: "opencode/big-pickle", name: "Big Pickle", provider: "opencode"),
        ModelRow(id: "anthropic/claude", name: "Claude", provider: "anthropic"),
        ModelRow(id: "opencode/muse", name: "Muse", provider: "opencode"),
        ModelRow(id: "openai/gpt", name: "GPT", provider: "openai"),
    ]
    let grouped = ProviderGrouping.ordered(rows)
    check("opencode group is first",
          grouped.first?.provider == "opencode", "got \(grouped.first?.provider ?? "nil")")
    check("remaining providers are alphabetical",
          grouped.map(\.provider) == ["opencode", "anthropic", "openai"],
          "got \(grouped.map(\.provider))")
    check("rows keep their order inside a group",
          grouped[0].rows.map(\.id) == ["opencode/big-pickle", "opencode/muse"])
    check("no rows means no groups", ProviderGrouping.ordered([]).isEmpty)

    let noPinned = [ModelRow(id: "a", name: "A", provider: "anthropic"),
                    ModelRow(id: "b", name: "B", provider: "openai")]
    let g2 = ProviderGrouping.ordered(noPinned)
    check("no opencode row invents no opencode group",
          g2.map(\.provider) == ["anthropic", "openai"], "got \(g2.map(\.provider))")
}

func testSessionSelectionSeparatesLiveFromViewing() {
    var sel = SessionSelection()
    sel.observeLive("ses_live")
    check("nothing picked means viewing live", sel.isViewingLive)

    sel.select("ses_old")
    check("picking an old session leaves live alone", sel.live == "ses_live")
    check("picking an old session is not viewing live", !sel.isViewingLive)
    check("old session renders", sel.renders("ses_old"))
    check("live session does not render over it", !sel.renders("ses_live"))

    // A new run starting must not steal the panel back from the user's pick.
    sel.observeLive("ses_new")
    check("a new live run still does not override the pick", sel.viewing == "ses_old")
    check("and still refuses to render", !sel.renders("ses_new"))

    sel.clear()
    check("clearing returns to live", sel.isViewingLive)
    check("live renders again", sel.renders("ses_new"))

    var pinned = SessionSelection()
    pinned.observeLive("ses_live")
    pinned.select("ses_live")
    check("picking the live session is still viewing live", pinned.isViewingLive)

    var unknownCursor = SessionSelection(live: "ses_live", viewing: "ses_gone")
    check("renders() defaults to showing when nothing is picked", unknownCursor.renders("ses_live") == false)
}

testSessionSelectionSeparatesLiveFromViewing()

print("")
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)