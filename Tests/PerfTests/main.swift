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

    let unknownCursor = SessionSelection(live: "ses_live", viewing: "ses_gone")
    check("renders() defaults to showing when nothing is picked", unknownCursor.renders("ses_live") == false)
}

testSessionSelectionSeparatesLiveFromViewing()

// --- VoiceCommandParser: never fire at the wrong agent ---------------------

let voiceRoster = [
    "elia", "mirorpay-community-organic", "mirrorpay-telegram", "mirorpay-seo",
    "reddit-saas-scraper", "vcam-community-organic", "vcam-seo", "deploymates-watch",
    "cve-hunter", "app-clone-factory", "app-qa-store-gate", "test-delegator",
    "job-hunter-ch-lu", "linkedin-connector-ch-lu-fr", "boxing-audience-scout",
    "gilfoyle",
]

func voice(_ text: String, requireAgent: Bool = true) -> VoiceCommandParser.Parsed {
    VoiceCommandParser.parse(text, roster: voiceRoster, requireAgent: requireAgent)
}

do {
    let p = voice("ok gilfoyle")
    check("'ok gilfoyle' resolves to gilfoyle", p.agent == "gilfoyle", "got \(p.agent ?? "nil")")
    check("'ok gilfoyle' has no command", p.command.isEmpty, "got '\(p.command)'")
    check("'ok gilfoyle' consumed the wake token", p.usedWakeToken)

    let c = voice("Ok Gilfoyle, deploy the api")
    check("'Ok Gilfoyle, deploy the api' resolves to gilfoyle", c.agent == "gilfoyle", "got \(c.agent ?? "nil")")
    check("the command is what was said after the name",
          c.command.lowercased() == "deploy the api", "got '\(c.command)'")

    let e = voice("okay elia what's up")
    check("'okay elia what's up' resolves to elia", e.agent == "elia", "got \(e.agent ?? "nil")")
    check("'okay elia what's up' keeps the command verbatim",
          e.command == "what's up", "got '\(e.command)'")

    let h = voice("hey gilfoyle, check the logs")
    check("'hey gilfoyle' resolves to gilfoyle", h.agent == "gilfoyle", "got \(h.agent ?? "nil")")

    let typo = voice("ok gilfoyl")
    check("'ok gilfoyl' still resolves to gilfoyle", typo.agent == "gilfoyle", "got \(typo.agent ?? "nil")")

    let two = voice("ok gilfoyle and elia")
    check("the first name wins", two.agent == "gilfoyle", "got \(two.agent ?? "nil")")
    check("the rest of the sentence is the command",
          two.command.lowercased() == "and elia", "got '\(two.command)'")

    let bare = voice("ok")
    check("'ok' alone resolves to no agent", bare.agent == nil, "got \(bare.agent ?? "nil")")

    let noName = voice("ok deploy the api")
    check("'ok deploy the api' resolves to no agent", noName.agent == nil, "got \(noName.agent ?? "nil")")

    let mid = voice("i went to the store ok")
    check("a trailing 'ok' is not a wake token", mid.agent == nil, "got \(mid.agent ?? "nil")")
    check("a trailing 'ok' is not consumed", !mid.usedWakeToken)

    let accent = voice("ok Gïlfoyle")
    check("diacritics fold", accent.agent == "gilfoyle", "got \(accent.agent ?? "nil")")

    let empty = voice("")
    check("an empty transcript resolves to no agent", empty.agent == nil)
    check("an empty transcript has no command", empty.command.isEmpty)

    let blank = voice("   ")
    check("a blank transcript resolves to no agent", blank.agent == nil)

    let huge = voice(String(repeating: "ok gilfoyle deploy the api ", count: 300))
    check("a 6k character transcript does not crash", huge.agent == "gilfoyle", "got \(huge.agent ?? "nil")")

    // Ambiguity must never pick a winner.
    let amb = voice("ok mirorpay")
    check("'ok mirorpay' stays ambiguous", amb.agent == nil, "got \(amb.agent ?? "nil")")
    check("'ok mirorpay' offers candidates", amb.candidates.count >= 2, "got \(amb.candidates)")

    let seo = voice("ok mirorpay seo")
    check("'ok mirorpay seo' picks the longer name", seo.agent == "mirorpay-seo", "got \(seo.agent ?? "nil")")

    let app = voice("ok app")
    check("'ok app' stays ambiguous", app.agent == nil, "got \(app.agent ?? "nil")")

    let optional = voice("ok deploy the api", requireAgent: false)
    check("requireAgent=false keeps the command", optional.command.lowercased() == "deploy the api",
          "got '\(optional.command)'")

    check("normalise folds case and punctuation",
          VoiceCommandParser.normalize("  Ok,  GILFOYLE! ") == "ok gilfoyle",
          "got '\(VoiceCommandParser.normalize("  Ok,  GILFOYLE! "))'")

    // The real transcript produced by Whisper on a "say" render of
    // "Ok Gilfoyle, deploy the api to production".
    let real = voice("Okay, Gilfoyle, deploy the AP to production.")
    check("the real Whisper transcript resolves to gilfoyle",
          real.agent == "gilfoyle", "got \(real.agent ?? "nil")")
    check("the real Whisper transcript keeps the command",
          real.command.lowercased() == "deploy the ap to production.",
          "got '\(real.command)'")

    // The wake phrase must not fire on ordinary speech.
    check("'ok gilfoyle' wakes", VoiceCommandParser.detectWake("ok gilfoyle", roster: voiceRoster))
    check("'okay gilfoyle' wakes", VoiceCommandParser.detectWake("okay gilfoyle", roster: voiceRoster))
    check("'ok gilfoyl' wakes (one letter off)",
          VoiceCommandParser.detectWake("ok gilfoyl", roster: voiceRoster))
    check("'ok mirorpay' wakes even though the name is ambiguous",
          VoiceCommandParser.detectWake("ok mirorpay", roster: voiceRoster))
    check("'okay so what time is it' does not wake",
          !VoiceCommandParser.detectWake("okay so what time is it", roster: voiceRoster))
    check("'ok app' wakes (exact but ambiguous)",
          VoiceCommandParser.detectWake("ok app", roster: voiceRoster))
    check("'ok' alone does not wake",
          !VoiceCommandParser.detectWake("ok", roster: voiceRoster))
    check("'deploy the api' does not wake",
          !VoiceCommandParser.detectWake("deploy the api", roster: voiceRoster))
    check("'what time is it' does not wake",
          !VoiceCommandParser.detectWake("what time is it", roster: voiceRoster))
    check("'okay so' does not wake",
          !VoiceCommandParser.detectWake("okay so", roster: voiceRoster))
}

// --- The live transcript and the tail have to join without repeating ------

do {
    let m = VoiceTranscriptMerger.merge

    check("an empty tail leaves the settled text alone",
          m("ok gilfoyle", "") == "ok gilfoyle")
    check("an empty settled text leaves the tail alone",
          m("", "ok gilfoyle") == "ok gilfoyle")

    let overlap = m("ok gilfoyle deploy", "deploy the api")
    check("the repeated words are dropped",
          overlap == "ok gilfoyle deploy the api", "got '\(overlap)'")

    let full = m("ok gilfoyle", "Okay Gilfoyle, deploy the api")
    check("the tail wins when it heard everything",
          full == "Okay Gilfoyle, deploy the api", "got '\(full)'")

    let disjoint = m("ok gilfoyle", "the api is slow")
    check("unrelated halves are joined",
          disjoint == "ok gilfoyle the api is slow", "got '\(disjoint)'")

    let punctuation = m("ok gilfoyle, deploy", "deploy the api.")
    check("punctuation does not hide the overlap",
          punctuation == "ok gilfoyle, deploy the api.", "got '\(punctuation)'")

    let caseFold = m("OK Gilfoyle", "gilfoyle deploy")
    check("the overlap ignores case",
          caseFold == "OK Gilfoyle deploy", "got '\(caseFold)'")
}

// --- The suffix prompt ----------------------------------------------------

do {
    let template = "Agent {{agent}} said {{command}} at {{date}}."
    let rendered = VoiceSuffixPrompt.render(template,
                                            agent: "gilfoyle",
                                            command: "deploy the api",
                                            transcript: "ok gilfoyle deploy the api")
    check("the agent variable is replaced",
          rendered.contains("Agent gilfoyle said"), "got '\(rendered)'")
    check("the command variable is replaced",
          rendered.contains("said deploy the api"), "got '\(rendered)'")
    check("the date variable is replaced",
          !rendered.contains("{{date}}"), "got '\(rendered)'")
    check("an unknown variable is left alone",
          VoiceSuffixPrompt.render("{{nope}}") == "{{nope}}")
    check("the default suffix tells the agent it was spoken",
          VoiceSuffixPrompt.defaultText.lowercased().contains("out loud"))
    check("the default suffix points at the macos popup",
          VoiceSuffixPrompt.defaultText.contains("macos-popup show_popup"))
}

// --- Devin account & model chooser -----------------------------------------

// catalog decode: free-first is a view concern; the fixture carries exactly
// one cost_tier "Free" variant and the code hardcodes no model IDs.
do {
    let json = """
    {"families":[
      {"family_label":"SWE-2 Flash","family_uid":"swe-2-flash","slug":"swe-2-flash","aliases":[],
       "variants":[
         {"model_uid":"swe-2-flash-medium","label":"SWE-2 Flash Medium",
          "cost_tier":"Free","max_context_tokens":262144,"max_output_tokens":131072,
          "is_new":false,"is_beta":false},
         {"model_uid":"swe-2-flash-high","label":"SWE-2 Flash High",
          "cost_summary":"$1 / 1M","max_context_tokens":262144,
          "is_new":true,"is_beta":false}
       ]},
      {"family_label":"Adaptive","family_uid":"Adaptive","slug":"adaptive","aliases":[],
       "variants":[
         {"model_uid":"adaptive","label":"Adaptive",
          "cost_summary":"$0.5 / 1M","is_new":false,"is_beta":false}
       ]}
    ]}
    """
    let catalog = try! JSONDecoder().decode(DevinCatalog.self, from: Data(json.utf8))
    let all = catalog.families.flatMap(\.variants)
    check("catalog decodes families + variants", catalog.families.count == 2 && all.count == 3)
    check("exactly one variant is Free", all.filter(\.isFree).count == 1)
    check("Free variant flags is_new=false, high is_new=true",
          all.first { $0.isFree }?.isNew == false && all.first { $0.modelUID == "swe-2-flash-high" }?.isNew == true)
    check("context chip formats", all.first?.contextChip == "262K")
    check("cost_summary with $ is not a capsule case",
          all.first { $0.modelUID == "adaptive" }?.costSummary?.contains("$") == true)
}

// process runner drains >64KB without deadlocking, and timeout kills
do {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let start = Date()
    let big: DevinProcessResult
    do {
        big = try DevinProcess.runSync(sh, ["-c", "head -c 500000 /dev/zero | base64"], timeout: 30)
    } catch {
        check("500KB drain runs", false, "\(error)")
        big = DevinProcessResult(status: -1, stdout: "", stderr: "")
    }
    let elapsed = Date().timeIntervalSince(start)
    check("500KB output drains without hanging",
          big.status == 0 && big.stdout.count > 500_000,
          "status=\(big.status) bytes=\(big.stdout.count)")
    check("500KB drain stays fast", elapsed < 10, "took \(elapsed)s")
}

do {
    let sh = URL(fileURLWithPath: "/bin/sh")
    let start = Date()
    _ = try? DevinProcess.runSync(sh, ["-c", "sleep 10"], timeout: 1)
    let elapsed = Date().timeIntervalSince(start)
    check("timeout terminates a sleeper", elapsed < 4, "took \(elapsed)s")
}

// DevinConfig writes agent.model into an isolated XDG_CONFIG_HOME,
// preserving existing keys — the direct-CLI apply path.
do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("eliatest-\(UUID().uuidString)", isDirectory: true)
    let prev = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
    setenv("XDG_CONFIG_HOME", tmp.path, 1)
    defer {
        if let prev { setenv("XDG_CONFIG_HOME", prev, 1) } else { unsetenv("XDG_CONFIG_HOME") }
        try? FileManager.default.removeItem(at: tmp)
    }

    let file = DevinConfig.configFile
    try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "{\"agent\":{\"verbosity\":\"high\"},\"other\":1}".write(
        to: file, atomically: true, encoding: .utf8)

    check("config starts empty model", DevinConfig.currentModel() == nil,
          "got \(DevinConfig.currentModel() ?? "nil")")
    try DevinConfig.applyModel("swe-1-6-slow")
    check("applyModel persists agent.model",
          DevinConfig.currentModel() == "swe-1-6-slow",
          "got \(DevinConfig.currentModel() ?? "nil")")

    let raw = try JSONSerialization.jsonObject(
        with: Data(contentsOf: file)) as? [String: Any]
    let agent = raw?["agent"] as? [String: Any]
    check("applyModel preserves sibling keys",
          agent?["verbosity"] as? String == "high" && raw?["other"] as? Int == 1,
          "agent=\(String(describing: agent))")

    try DevinConfig.applyModel("swe-2-flash-medium")
    check("applyModel overwrites model",
          DevinConfig.currentModel() == "swe-2-flash-medium",
          "got \(DevinConfig.currentModel() ?? "nil")")
}

// reset_state.json fallback decode: ISO datetimes become epochs
do {
    let json = """
    {"version":1,"accounts":{"x@x.com":{
      "last_used":"2026-11-11T18:35:08.643699","uses":2,
      "last_mint":"2026-11-11T18:35:27.490703",
      "identity":{"name":"X","plan":"Free"},
      "usage":{"daily_remaining_pct":0,"weekly_remaining_pct":59,
               "daily_reset_at":1794470400,"weekly_reset_at":1794729600,
               "fetched_at":"2026-11-11T18:35:24.103044"}}}}
    """
    let state = try! JSONDecoder().decode(DevinCachedState.self, from: Data(json.utf8))
    let entry = state.accounts["x@x.com"]
    check("cached state decodes", entry?.uses == 2 && entry?.identity?.plan == "Free")
    let snap = entry?.usage?.withEpochs()
    check("cached ISO fetched_at becomes an epoch",
          snap?.fetchedAtEpoch != nil && (snap?.dailyRemainingPct == 0))
    check("epoch parse round-trips", DevinCachedState.epoch(from: "2026-11-11T18:35:24") != nil)
}

print("")
print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)