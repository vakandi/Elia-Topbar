# EliaTopBar — Devin account & model chooser

Status: implementation plan. Nothing here is built yet.
Repo: `/Users/vakandi/Documents/EliaTopBar` — Swift 5.9, macOS 13+, SPM, no Xcode project.
Companion spec for the CLI side: `/Users/vakandi/Documents/EliaSaas/docs/DEVIN-ACCOUNT-ROTATION.md`.

This plan puts a Devin control surface inside the existing model chooser: the same menu entry
pattern as `🖥️ Local model (custom base URL)…`, but a richer window that answers three
questions and performs three actions.

It answers:

- which Devin accounts exist on this Mac, and which one is logged in right now;
- how much of each account's daily and weekly quota is left, and when it resets;
- which models this account can actually use, with the free ones first.

It acts:

- switch the active Devin account (runs the proven `devin-reset`, not a Swift reimplementation);
- choose the Devin model for an agent, persisted and applied through the normal model pipeline;
- refresh usage and the model catalog.

It never reads cookies, passwords, session tokens, or `devin_sessions.json`. The only account
data that crosses into Swift is an email, a display name, a plan, and four quota numbers — all
emitted by the helper described in Phase 0.

---

## 0. Ground truth measured on 2026-11-11

Every fact below was read from the machine, not remembered.

**EliaTopBar model chooser today**

- `Sources/LocalModelView.swift` (422 lines) is the reference implementation: a SwiftUI view,
  presented in a floating `NSWindow`, opened from a menu item that carries `agentName` in
  `representedObject`.
- `Sources/EliaTopBarApp.swift:2548` is `openLocalModelEditor(_:)`: it builds the view, calls
  `NSHostingView`, sizes the window to `host.fittingSize`, sets `.floating`, and keeps it in
  `localModelWindow`.
- `LocalModelView` applies through `subworkerManager.setModel(modelID, variant:for:providerBaseURL:)`
  (`SubworkerManager.swift:1148`). That method persists the selection to
  `SubworkerModels.selectionsPath` and pushes it to BunControl with `PUT /status/<agent>`.
- The menu item is inserted at `EliaTopBarApp.swift:3434`, above the hosted roster, with the
  comment that it must stay listed even while the roster is loading.
- `anyLiveUIVisible()` (`EliaTopBarApp.swift:200`) must learn about the new window, otherwise
  App Nap can suspend the app while a 30–60 s account switch is running.

**Devin CLI on this machine**

- `devin models list --format json` exists and works. Output is `{"families":[…]}`.
- Variant fields: `model_uid`, `label`, `description`, `cost_summary`, `cost_tier`,
  `max_context_tokens`, `max_output_tokens`, `is_new`, `is_beta`.
- On the currently logged-in Free account the catalog contains 51 families. Exactly one variant
  carries `cost_tier: "Free"` (`swe-2-flash-medium`), one carries `"Low cost"`
  (`swe-1-6-slow`), most carry `null` or a dollar `cost_summary`.
- Therefore the popup reads `cost_tier` and never hardcodes "two free models". If the account
  later has two, the UI shows two; if it has one, it shows one. Wael remembers two — the
  catalog is the source of truth, and the plan keeps the display driven by it.
- The JSON payload is **472 KB**. A naive `Process` + `waitUntilExit()` then read-the-pipe
  deadlocks at the 64 KB pipe buffer. The runner below drains output concurrently; this is a
  measured constraint, not a style preference.
- `devin auth status` prints a human block containing `Email:` and `Tier:`. It has no `--json`.
- `devin --model <MODEL>` exists, so the chosen model can also be shown as a copyable launch
  command for manual use.

**Devin rotation state**

- `~/.local/share/devin/reset_state.json` exists, 1,547 bytes, keyed by email under `accounts`.
- Each account entry: `last_used`, `uses`, `last_mint`, `identity{name,email,user_id,plan,
  team_id,team_status}`, `usage{daily_remaining_pct, weekly_remaining_pct, daily_reset_at,
  weekly_reset_at, fetched_at}`.
- Only two accounts are present there today: `xilay20818@fixwap.com` and
  `1754004887@qq.com`. `~/devin_sessions.json` holds 212 entries today. So the state file
  is a **usage cache**, not the account list. The popup must not present it as the pool.
- `devin-reset --help` exposes: `pick`, `--list`, `--all`, `--usage`, `--check N`, `--detail N`,
  `--relogin`, `--no-app`, `--keep-identity`, `--keep-cache`, `--headed`, `--dry-run`.
- No JSON mode exists in `devin_reset.py` today. Phase 0 adds it. Without it the popup would
  show two accounts instead of the real pool, or would have to parse a truncated text table.

**Engine routing**

- `grep -rln "devin" ~/Documents/subworker-opencode-rust/server/crates` returns nothing.
  The Rust engine has no `devin-cli` provider today.
- Consequence: `setModel("devin-cli/<uid>", …)` cannot route a run yet. The popup must save the
  choice and say so, not pretend it took effect. Phase 3 keeps the seam; Phase 4 is engine work
  in another repo.

---

## 1. What this window is, and what it is not

**It is** a control surface for the Devin CLI account pool plus a model picker for that CLI.

**It is not**:

- a replacement for `devin-reset`. Switching shells out to it. Reimplementing logout, identity
  rotation, minting and credential writing in Swift would duplicate 776 lines of proven,
  security-sensitive code.
- a corpus browser. It shows accounts that can be logged into, not cookies, not passwords, not
  recovery data.
- a proxy-key manager. opencode's private rotation stays opaque, as decided in the backend plan.
- an auto-rotator. Nothing switches in the background. The user picks an account; the pool
  selection happens later inside whichever runtime supports it.

---

## 2. UX specification

### 2.1 Entry point

In the model submenu, immediately after the local-model item, before the separator:

```
🖥️ Local model (custom base URL)…
🧠 Devin CLI — account & model…          ← new
────────────────────────────────
(hosted roster)
```

When a model is already chosen the title carries it:

```
🧠 Devin CLI — xilay20818@fixwap.com · SWE-2 Flash Medium…
```

The item is always present, even while the roster is loading, for the same reason the local item
is: it does not depend on BunControl.

### 2.2 Window

- Title: `Devin CLI`.
- Width 640, height 660. Resizable off; content scrolls.
- `.floating`, `isReleasedWhenClosed = false`, centered on first open, remembered frame after.
- Registered in `anyLiveUIVisible()` so App Nap does not freeze the switch.

### 2.3 Layout, top to bottom

**Banner (84 pt).** Dark gradient card, corner radius 14. Left: a 42×42 rounded square with the
`brain.head.profile` SF Symbol on `.ultraThinMaterial`. Middle: `Devin CLI` 15 pt semibold, then
the active email in 11 pt secondary (truncated middle). Right: a plan pill (`FREE`), then a
44×44 daily-quota ring with the percentage inside.

The banner is the only decorative element. Everything below it is information-dense.

**Account section.**

- Header row: `Accounts` 11 pt uppercase secondary, on the right the count returned by the
  helper (`N accounts`, not a corpus total), a search field (visible only above 8 accounts),
  and a `Refresh` button.
- A two-column `LazyVGrid` of account cards, 104 pt tall.
- Card contents: initials circle (first letter of the local part), email in 12 pt medium
  (truncated middle), status dot; two 4 pt quota bars labelled `D` and `W`; a footer line with
  `resets in 6h 12m · 2 uses`.
- Active account: green `ACTIVE` capsule at top-right, 1.5 pt accent stroke.
- Selected-but-not-active: accent ring only.
- Quota-reached account: dot amber, footer `daily quota reached · resets in 6h`.
- Stale snapshot: dot grey, footer `usage unknown · checked 2 d ago`.
- Clicking a card selects it. Double-click is not a switch; switching is an explicit button.

**Usage strip under the grid.** For the selected account only, two horizontal bars with exact
percentages, reset countdowns, and `fetched 4 min ago`. No ring duplication: the banner ring is
the active account, the strip is the selected one. Both are labelled so they cannot be confused.

**Model section.**

- Header: `Models` + `for <selected account>`.
- If the selected account is not the active one: a one-line note, `Catalog is read from the
  active account. Switch to see another plan's models.` The catalog call always uses current
  credentials, so we never claim to know an inactive account's catalog.
- Two groups:
  - `Free on this account` — variants with `cost_tier == "Free"`, always expanded.
  - `All models (N)` — collapsed by default, opened by a disclosure row.
- A model row: radio circle, label 12.5 pt, `FREE` green capsule or `LOW COST` amber capsule or
  the `cost_summary` string in 10 pt secondary, context chip `262K`, and a `NEW` capsule when
  `is_new` is true.
- Selecting a row only marks it. Apply is the button.

**Footer.** Left: the exact target `agent → devin-cli/swe-2-flash-medium` in 10.5 pt monospaced,
or `Devin CLI default` when no agent routing is available. Right: `Cancel`,
`Switch account` (bordered, disabled when the selection is already active), `Apply` (prominent,
disabled while switching or when nothing is selected).

**Progress overlay.** During a switch, the cards dim and a centered card lists the phases:
`resolving → minting → logging out → rotating identity → writing credentials → verifying`.
Check marks appear from the NDJSON events. No cancel button: killing the helper after logout can
leave the CLI with no credential. Copy says `Do not close this window`.

---

## 3. Data contracts

Three sources, in order of authority.

### 3.1 `devin-reset --json list` — the account pool (Phase 0)

This is the authoritative list. It is produced by the helper, which already knows how to load
the corpus; the app never touches the corpus file.

```json
{
  "current": "xilay20818@fixwap.com",
  "accounts": [
    {
      "email": "xilay20818@fixwap.com",
      "name": "xilay reta",
      "plan": "Free",
      "checked": "logged_in",
      "last_used_epoch": 1762886108,
      "uses": 2,
      "last_mint_epoch": 1762886127,
      "usage": {
        "daily_remaining_pct": 0,
        "weekly_remaining_pct": 59,
        "daily_reset_at": 1794470400,
        "weekly_reset_at": 1794729600,
        "fetched_at_epoch": 1762886124
      }
    }
  ]
}
```

Rules, enforced by a test in the helper:

- never emit `cookies`, `password`, `token`, `api_key`, `authorization`, or any nested field
  whose name matches those patterns;
- `checked` is one of `logged_in`, `dead`, `unknown`, from the checker corpus;
- `usage` is `null` when the account was never minted;
- timestamps are epoch seconds, so Swift never parses a Python datetime;
- `--json` implies the full usable list. `--all` is accepted and means the same thing in JSON
  mode; `--limit <n>` truncates if asked.

The `current` field is what the helper already knows after a mint or can read from
`devin auth status`. It is not inferred in Swift.

### 3.2 `devin-reset --json-events <account>` — the switch (Phase 0)

NDJSON on stdout, one object per line:

```json
{"event":"phase","phase":"resolve","ok":true,"detail":"xilay20818@fixwap.com"}
{"event":"phase","phase":"mint","ok":true,"detail":"session token minted"}
{"event":"phase","phase":"logout","ok":true,"detail":"CLI logged out"}
{"event":"phase","phase":"identity","ok":true,"detail":"machine identity rotated"}
{"event":"phase","phase":"write","ok":true,"detail":"credentials.toml written"}
{"event":"phase","phase":"verify","ok":true,"detail":"/v3/self answered"}
{"event":"done","email":"xilay20818@fixwap.com"}
```

On failure: `{"event":"error","detail":"…"}` then exit non-zero. `detail` must never contain a
token or a cookie value; the helper masks like it does today.

The human output stays exactly as it is; NDJSON is additive and only active with the flag.

### 3.3 `devin models list --format json` — the catalog

Already shipped. Shape:

```json
{"families":[
  {"family_label":"SWE-2 Flash","family_uid":"swe-2-flash","slug":"swe-2-flash","aliases":[],
   "variants":[
     {"model_uid":"swe-2-flash-medium","label":"SWE-2 Flash Medium",
      "cost_tier":"Free","max_context_tokens":262144,"max_output_tokens":131072,
      "is_new":false,"is_beta":false}
   ]}
]}
```

Classification used by the UI:

- `cost_tier` case-insensitively `Free` → green `FREE`.
- `cost_tier` case-insensitively `Low cost` → amber `LOW COST`.
- `cost_summary` present and containing `$` → render the summary, no capsule.
- both null → no badge. Do not guess "free", do not guess "paid".
- `max_context_tokens` → chip like `262K`, `1M` above 999,999.

### 3.4 Fallback when the helper is absent

Read `reset_state.json` directly, show the two cached accounts, and render a banner:
`devin-reset not found — showing cached usage only.` Switching is disabled. This keeps the
window useful on a machine where only the CLI is installed, without inventing a pool.

Path resolution mirrors the Rust engine: `XDG_DATA_HOME` if set, else `~/.local/share`, then
`devin/reset_state.json`. Never hardcode `/Users/<name>`.

---

## 4. New files

- `Sources/DevinCLI.swift` — binary resolution, process runner, JSON calls, switch stream.
- `Sources/DevinState.swift` — Codable models, status derivation, sorting, formatting.
- `Sources/DevinAccountModelView.swift` — the window content.
- `Sources/DevinCards.swift` — banner, account card, quota bar, model row. Split only if the
  view exceeds ~500 lines; otherwise keep one file, matching `LocalModelView`'s single-file style.

No changes to `Package.swift`. The executable target compiles everything under `Sources/`.

---

## 5. Implementation, step by step

### Step 1 — paths and binary resolution

```swift
import Foundation

enum DevinPaths {
    static var dataHome: URL {
        if let raw = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share", isDirectory: true)
    }

    static var stateFile: URL {
        dataHome.appendingPathComponent("devin/reset_state.json")
    }

    /// `devin` is installed in ~/.local/bin on this machine; the other two are
    /// the usual Homebrew prefixes. PATH alone is not trusted because a
    /// launchd-started app inherits a minimal environment.
    static func locate(_ name: String) -> URL? {
        let dirs = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
        ]
        for dir in dirs {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        // Last resort: ask the login shell, which is where a manual install lands.
        let result = try? DevinProcess.runSync(
            URL(fileURLWithPath: "/bin/zsh"),
            ["-lc", "command -v \(name)"],
            timeout: 5
        )
        let path = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}
```

### Step 2 — process runner that cannot deadlock

The reason this is not three lines: `devin models list --format json` returns 472 KB, and the
pipe buffer is 64 KB. Reading after `waitUntilExit()` hangs forever. Drain both pipes
concurrently, then wait.

```swift
struct DevinProcessResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum DevinProcess {
    static func run(_ executable: URL, _ args: [String],
                    timeout: TimeInterval) async throws -> DevinProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = [
                    "/opt/homebrew/bin", "/usr/local/bin",
                    NSHomeDirectory() + "/.local/bin",
                    env["PATH"] ?? "/usr/bin:/bin",
                ].joined(separator: ":")
                process.environment = env

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err

                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let group = DispatchGroup()
                var outData = Data(), errData = Data()
                group.enter()
                DispatchQueue.global().async {
                    outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                process.waitUntilExit()
                killer.cancel()
                group.wait()

                continuation.resume(returning: DevinProcessResult(
                    status: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    /// Synchronous variant for path probing at launch. Never call on the main thread.
    static func runSync(_ executable: URL, _ args: [String],
                        timeout: TimeInterval) throws -> DevinProcessResult {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<DevinProcessResult, Error>!
        Task.detached {
            do { result = .success(try await run(executable, args, timeout: timeout)) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }
}
```

Add a test later with `/bin/sh -c 'head -c 500000 /dev/zero | base64'` to prove the drain.

### Step 3 — decode the pool

```swift
struct DevinUsageSnapshot: Decodable, Hashable {
    let dailyRemainingPct: Int
    let weeklyRemainingPct: Int
    let dailyResetAt: Double
    let weeklyResetAt: Double
    let fetchedAtEpoch: Double?

    enum CodingKeys: String, CodingKey {
        case dailyRemainingPct = "daily_remaining_pct"
        case weeklyRemainingPct = "weekly_remaining_pct"
        case dailyResetAt = "daily_reset_at"
        case weeklyResetAt = "weekly_reset_at"
        case fetchedAtEpoch = "fetched_at_epoch"
    }
}

struct DevinAccount: Decodable, Identifiable, Hashable {
    let email: String
    let name: String?
    let plan: String?
    let checked: String?
    let lastUsedEpoch: Double?
    let uses: Int?
    let usage: DevinUsageSnapshot?

    var id: String { email }

    enum CodingKeys: String, CodingKey {
        case email, name, plan, checked, uses, usage
        case lastUsedEpoch = "last_used_epoch"
    }
}

struct DevinPool: Decodable {
    let current: String?
    let accounts: [DevinAccount]
}
```

### Step 4 — status derivation, in one place

The UI must not invent states. One function decides, and every badge reads it.

```swift
enum DevinAccountStatus {
    case active
    case available
    case dailyReached(reset: Date)
    case weeklyReached(reset: Date)
    case stale(checked: Date?)
    case unknown
}

extension DevinAccount {
    func status(activeEmail: String?, now: Date = Date()) -> DevinAccountStatus {
        if email.caseInsensitiveCompare(activeEmail ?? "") == .orderedSame { return .active }
        guard let usage else { return .unknown }
        if let fetched = usage.fetchedAtEpoch {
            let age = now.timeIntervalSince1970 - fetched
            if age > 24 * 3600 { return .stale(checked: Date(timeIntervalSince1970: fetched)) }
        }
        if usage.weeklyRemainingPct <= 0 {
            return .weeklyReached(reset: Date(timeIntervalSince1970: usage.weeklyResetAt))
        }
        if usage.dailyRemainingPct <= 0 {
            return .dailyReached(reset: Date(timeIntervalSince1970: usage.dailyResetAt))
        }
        return .available
    }
}
```

`checked` from the helper is a corpus fact (`logged_in` / `dead`), not a quota fact. If it is
`dead`, the card shows a red dot and the switch stays enabled only behind a confirmation.

Sorting: active first, then available by daily percentage descending, then quota-reached by
reset ascending, then stale/unknown, then email. Deterministic, no jitter between refreshes.

### Step 5 — read the pool

```swift
extension DevinCLI {
    static func loadPool() async throws -> DevinPool {
        if let helper = DevinPaths.locate("devin-reset") {
            // `list` is a positional `pick` argument, not a subcommand: the flag
            // must come first, or argparse reads "list" as an email.
            let result = try await DevinProcess.run(
                helper, ["--list", "--json"], timeout: 20
            )
            guard result.status == 0 else {
                throw DevinError.message(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            return try JSONDecoder().decode(DevinPool.self, from: Data(result.stdout.utf8))
        }
        return try loadCachedPool()
    }

    private static func loadCachedPool() throws -> DevinPool {
        let data = try Data(contentsOf: DevinPaths.stateFile)
        let state = try JSONDecoder().decode(CachedState.self, from: data)
        let current = try? activeEmailFromAuthStatus()
        let accounts = state.accounts.map { email, entry in
            DevinAccount(
                email: email,
                name: entry.identity?.name,
                plan: entry.identity?.plan,
                checked: nil,
                lastUsedEpoch: entry.lastUsedEpoch,
                uses: entry.uses,
                usage: entry.usage?.withEpochs()
            )
        }
        return DevinPool(current: current, accounts: accounts)
    }
}
```

`CachedState` mirrors `reset_state.json`; its decoder converts the Python datetime strings to
epochs once, locally, with a `yyyy-MM-dd'T'HH:mm:ss[.SSSSSS]` formatter in the current timezone.
That parsing exists only on the fallback path.

Two small pieces the snippets above assume:

```swift
enum DevinError: LocalizedError {
    case binaryMissing
    case helperMissing
    case message(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing: return "devin not found. Install it, or use Locate…"
        case .helperMissing: return "devin-reset not found. Account switching is disabled."
        case .message(let text): return text
        }
    }
}

extension DevinCLI {
    /// The only text parse in the feature, and only on the fallback path (no
    /// helper). The helper returns `current` as JSON, so the normal path never
    /// scrapes this output.
    static func activeEmailFromAuthStatus() throws -> String? {
        guard let binary = DevinPaths.locate("devin") else { throw DevinError.binaryMissing }
        let result = try DevinProcess.runSync(binary, ["auth", "status"], timeout: 8)
        guard result.status == 0 else { return nil }
        for line in result.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Email:") else { continue }
            return String(trimmed.dropFirst("Email:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
```

### Step 6 — read the catalog

```swift
struct DevinModelVariant: Decodable, Identifiable, Hashable {
    let modelUID: String
    let label: String
    let description: String?
    let costSummary: String?
    let costTier: String?
    let maxContextTokens: Int?
    let isNew: Bool?

    var id: String { modelUID }
    var isFree: Bool { costTier?.caseInsensitiveCompare("Free") == .orderedSame }
    var isLowCost: Bool { costTier?.caseInsensitiveCompare("Low cost") == .orderedSame }

    enum CodingKeys: String, CodingKey {
        case label, description
        case modelUID = "model_uid"
        case costSummary = "cost_summary"
        case costTier = "cost_tier"
        case maxContextTokens = "max_context_tokens"
        case isNew = "is_new"
    }
}

struct DevinModelFamily: Decodable, Identifiable {
    let familyLabel: String
    let slug: String
    let variants: [DevinModelVariant]

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug, variants
        case familyLabel = "family_label"
    }
}

struct DevinCatalog: Decodable { let families: [DevinModelFamily] }
```

```swift
extension DevinCLI {
    static func loadCatalog() async throws -> [DevinModelFamily] {
        guard let binary = DevinPaths.locate("devin") else { throw DevinError.binaryMissing }
        let result = try await DevinProcess.run(
            binary, ["models", "list", "--format", "json"], timeout: 20
        )
        guard result.status == 0 else { throw DevinError.message(result.stderr) }
        let catalog = try JSONDecoder().decode(DevinCatalog.self, from: Data(result.stdout.utf8))
        return catalog.families
    }
}
```

Free-first ordering is a view concern, not a mutation of the array: build
`freeFamilies = families.compactMap { family in family.variants.filter(\.isFree) ... }` and keep
the original for `All models`.

### Step 7 — switch, with a streamed phase list

`Process` + `readabilityHandler`, accumulating lines until `done` or `error`. The continuation
is resumed exactly once, guarded by a flag.

```swift
enum DevinSwitchEvent: Decodable {
    let event: String
    let phase: String?
    let ok: Bool?
    let detail: String?
    let email: String?
}

extension DevinCLI {
static func switchAccount(to email: String,
                          onEvent: @escaping @Sendable (DevinSwitchEvent) -> Void) async throws {
    guard let helper = DevinPaths.locate("devin-reset") else { throw DevinError.helperMissing }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--json-events", email]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:"
            + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        var buffer = Data()
        var errData = Data()
        var finished = false
        let lock = NSLock()
        let errLock = NSLock()

        // stderr is drained too: the helper is quiet, but a Python traceback
        // longer than the 64 KB pipe buffer would block the child and hang the
        // continuation with no timeout. Draining is the timeout.
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errLock.lock(); errData.append(chunk); errLock.unlock()
        }

        func finish(_ result: Result<Void, Error>) {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            continuation.resume(with: result)
        }

        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let event = try? JSONDecoder().decode(DevinSwitchEvent.self, from: line)
                else { continue }
                onEvent(event)
                if event.event == "done" { finish(.success(())) }
                if event.event == "error" {
                    finish(.failure(DevinError.message(event.detail ?? "switch failed")))
                }
            }
        }

        process.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let remaining = err.fileHandleForReading.readDataToEndOfFile()
            errLock.lock()
            if !remaining.isEmpty { errData.append(remaining) }
            let tail = String(data: errData, encoding: .utf8) ?? ""
            errLock.unlock()
            if proc.terminationStatus == 0 {
                finish(.success(()))
            } else {
                finish(.failure(DevinError.message(tail.isEmpty ? "switch failed" : tail)))
            }
        }

        do { try process.run() } catch { finish(.failure(error)) }
    }
}
}
```

`onEvent` fires on a pipe queue. The view wraps it in
`Task { @MainActor in phase = event.phase }`; never mutate `@State` from the handler directly.

There is no cancel. Killing the helper between `logout` and `write` leaves the CLI with no
credential; the UI says so and disables window close during the operation.

After a successful switch: re-read the pool (the helper's `current` changed), re-read
`devin auth status` only as a cross-check, and re-read the catalog because the plan may differ.

### Step 8 — the banner

```swift
private var banner: some View {
    HStack(spacing: 12) {
        Image(systemName: "brain.head.profile")
            .font(.system(size: 19, weight: .medium))
            .frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))

        VStack(alignment: .leading, spacing: 3) {
            Text("Devin CLI").font(.system(size: 15, weight: .semibold))
            Text(activeAccount?.email ?? "No account logged in")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
                .truncationMode(.middle)
        }

        Spacer()

        if let plan = activeAccount?.plan {
            Text(plan.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.white.opacity(0.12), in: Capsule())
        }

        if let usage = activeAccount?.usage {
            QuotaRing(percent: usage.dailyRemainingPct, size: 44)
        }
    }
    .padding(.horizontal, 14)
    .frame(height: 84)
    .foregroundColor(.white)
    .background(
        LinearGradient(
            colors: [Color(red: 0.10, green: 0.12, blue: 0.20),
                     Color(red: 0.20, green: 0.17, blue: 0.33)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        ),
        in: RoundedRectangle(cornerRadius: 14)
    )
}
```

`QuotaRing` is a `ZStack` of `Circle().stroke` and `Circle().trim(from: 0, to: CGFloat(percent)/100)
.rotationEffect(.degrees(-90))`, with the number in 11 pt semibold. Green above 40, amber 1–39,
red at 0.

### Step 9 — account card

```swift
struct DevinAccountCard: View {
    let account: DevinAccount
    let status: DevinAccountStatus
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text(String(account.email.prefix(1)).uppercased())
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.accentColor.opacity(0.16), in: Circle())
                    Text(account.email)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 2)
                    StatusDot(status: status)
                }

                if let usage = account.usage {
                    QuotaBar(label: "D", percent: usage.dailyRemainingPct)
                    QuotaBar(label: "W", percent: usage.weeklyRemainingPct)
                }

                Text(footline)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.primary.opacity(selected ? 0.075 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? Color.accentColor.opacity(0.8) : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
```

`footline` is built by one function from the status: `Available · 2 uses`,
`Daily quota reached · resets in 6h 12m`, `Usage unknown · checked 2 d ago`.

### Step 10 — model row and free-first grouping

```swift
private var freeVariants: [(DevinModelFamily, DevinModelVariant)] {
    families.flatMap { family in
        family.variants.filter(\.isFree).map { (family, $0) }
    }
}

private var paidVariants: [(DevinModelFamily, DevinModelVariant)] {
    families.flatMap { family in
        family.variants.filter { !$0.isFree }.map { (family, $0) }
    }
}
```

`freeVariants` renders expanded. `paidVariants` renders under a `DisclosureGroup` labelled
`All models (N)`, collapsed by default. This is how "only two free models" becomes true without
being hardcoded: whatever carries `cost_tier: Free` lands in the first group.

### Step 11 — the window and the menu item

Add a property next to `localModelWindow`:

```swift
private var devinWindow: NSWindow?
```

Add the live-UI line so App Nap does not freeze a switch:

```swift
|| (devinWindow?.isVisible ?? false)
```

Controller, mirroring `openLocalModelEditor`:

```swift
@objc private func openDevinChooser(_ sender: NSMenuItem) {
    guard let agentName = sender.representedObject as? String else { return }

    let rootView = DevinAccountModelView(
        agentName: agentName,
        currentModel: subworkerManager.currentModel(for: agentName),
        onClose: { [weak self] in self?.devinWindow?.close() },
        onApply: { [weak self] account, variant in
            guard let self else { return }
            UserDefaults.standard.set(variant.modelUID, forKey: "devin.model")
            UserDefaults.standard.set(account.email, forKey: "devin.account")

            let routed = self.subworkerManager.availableModels
                .contains { $0.provider == "devin-cli" }
            if routed {
                self.subworkerManager.setModel(
                    "devin-cli/\(variant.modelUID)", variant: "", for: agentName
                )
                self.showTopbarToast(emoji: "🧠",
                    message: "\(agentName) → \(variant.label)", spinning: false, autoHideAfter: 5)
            } else {
                self.showTopbarToast(emoji: "🧠",
                    message: "Devin model saved — engine routing not wired yet",
                    spinning: false, autoHideAfter: 6)
            }
            self.devinWindow?.close()
            self.setupMenu()
        }
    )

    if let window = devinWindow {
        let host = NSHostingView(rootView: rootView)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return
    }

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 660),
        styleMask: [.titled, .closable],
        backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.title = "Devin CLI"
    let host = NSHostingView(rootView: rootView)
    window.contentView = host
    window.setContentSize(host.fittingSize)
    window.center()
    window.level = .floating
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    devinWindow = window
}
```

Menu insertion, directly after the local item:

```swift
let devinItem = NSMenuItem(
    title: "", action: #selector(openDevinChooser(_:)), keyEquivalent: ""
)
devinItem.attributedTitle = emojiAwareTitle(
    "🧠 Devin CLI — account & model…", color: .labelColor
)
devinItem.target = self
devinItem.representedObject = agentName
menu.addItem(devinItem)
```

### Step 12 — persistence

- `devin.model` → `model_uid`, read on popup open to preselect.
- `devin.account` → last chosen email, used only to preselect a card. The authority is
  `pool.current`.
- Catalog cache: in-memory, 10 minutes. Do not persist 472 KB in `UserDefaults`.
- Pool cache: the helper call is cheap; no cache. The fallback state file is read fresh.

---

## 6. Threading, timeout, failure rules

- No `Process` on the main thread. Every call goes through `DevinProcess.run`.
- Timeouts: `auth status` 8 s, `models list` 20 s, `--json list` 20 s, switch 240 s.
- `models list` failure keeps the previous catalog on screen and shows a small `could not
  refresh` line. It never blanks the window the user is about to use.
- Switch failure keeps the previous active account highlighted. It never claims success because
  the process exited 0; the `done` event is the success signal.
- Killing the window during a switch is refused by disabling the close button and showing
  `Do not close this window`.
- If `devin` is missing: the banner says `Devin CLI not found`, the models section shows the
  install command `curl -fsSL https://cli.devin.ai/install.sh | sh` in monospace, and a
  `Locate…` button opens an `NSOpenPanel`. No silent empty list.
- If the state file is missing and the helper is missing: an empty state, not an error dialog.

---

## 7. Security and privacy rules

- `devin_sessions.json`, `credentials.toml`, and every cookie jar are out of bounds for this
  feature. The only corpus-derived data is the safe JSON emitted by `devin-reset --json list`,
  and Phase 0 includes a test that asserts no secret-shaped key can appear in it.
- The switch helper runs as the user, with the user's environment. That is the same trust level
  as running `devin-reset` in a terminal; the app adds no privilege.
- Never pass `--headed`. Never pass `--dry-run` in production. `--no-app` is exposed as a
  checkbox `Also update Devin.app`, default on, so the CLI and the app stay on the same account.
  No relaunch, in either case.
- `AppLog` lines may contain the email and the phase name. Never a token, a cookie, a password,
  or the full helper stderr if it might contain one — the helper already masks, but the app
  truncates to the last three lines and strips lines containing `token`, `cookie`, `password`,
  `authorization`, case-insensitively.
- The model catalog is public data. The account list is local. No network call leaves this
  feature except the ones `devin` itself makes.

---

## 8. Tests and acceptance

Compile gate: `swift build` in the repo, then `./build-app.sh v2.6` for the actual app bundle.
No CI; a manual launch is part of the gate.

Unit tests go in the existing `Tests/PerfTests` executable target — the package has no XCTest
(CLT-only machine, `_Testing_Foundation` ships without a `swiftmodule`). Assertions exit
non-zero, exactly like the current suite.

- decode a `DevinPool` fixture with two accounts and one `usage: null`;
- decode the real catalog shape and assert one `isFree` variant for the recorded 2026-11-11
  fixture, while the code contains no hardcoded model IDs;
- status derivation: 0 daily → `.dailyReached`, 0 weekly → `.weeklyReached`, 25 h old snapshot →
  `.stale`, active email → `.active`;
- sorting is stable across two runs;
- process runner drains 500 KB without hanging (the deadlock regression test);
- `DevinProcess.run` timeout terminates a `sleep 10` in under 2 s.

Manual acceptance, in order:

1. Open the model submenu: `🧠 Devin CLI — account & model…` sits under the local item, above
   the separator.
2. Open it: the banner shows the active email from `devin auth status`, the plan pill, and the
   daily ring. No credential file is opened.
3. The account grid lists the full pool from `devin-reset --json list`, not just the two cached
   accounts. Active card has the green `ACTIVE` capsule.
4. The free group contains exactly the variants carrying `cost_tier: Free`; `All models` is
   collapsed and its count matches the catalog.
5. Apply a free model: the choice survives a relaunch; the footer/menu title shows it. With the
   engine lacking `devin-cli`, the toast says routing is not wired, and no roster entry changes.
6. Quit and reopen the app: the popup preselects the saved model.
7. Failure drill: rename `devin` temporarily → the banner shows `Devin CLI not found`, the
   install command, and a working `Locate…`; no crash.
8. Failure drill: corrupt a copy of `reset_state.json` on a machine without the helper → empty
   state, no crash. Restore the file.
9. Switch drill (manual, only with Wael's explicit go): pick a different account, watch the
   phase list, confirm `devin auth status` afterwards, then switch back. This mutates the
   user's logged-in account; it is never part of an automated test.

---

## 9. Step order and gates

**Phase 0 — the helper contract (outside this repo, in `leaks_accounts/tools/devin_reset.py`)**

- add `--json` to the list path and `--json-events` to the switch path;
- emit only safe fields and epoch timestamps;
- keep the human output byte-for-byte unchanged when the flags are absent;
- test: `devin-reset --json list | jq -e '.accounts | length > 0'`, plus a secret-key scan.

Gate: JSON parses, no secret-shaped keys, current account correct.

**Phase 1 — read-only window (this repo)**

- `DevinCLI`, `DevinState`, the view, the menu item, the window;
- accounts, usage, models; no switching, no writes beyond the saved model on Apply.

Gate: `swift build` green, items 1–6 and 7–8 of the acceptance list pass.

**Phase 2 — switching**

- the NDJSON stream, progress overlay, post-switch refresh, close protection.

Gate: item 9 passes once, with Wael's go, and the account is restored afterwards.

**Phase 3 — routing seam**

- if `availableModels` gains a `devin-cli` provider, Apply calls `setModel`; otherwise it keeps
  the saved preference and the honest toast;
- add the selected model to the menu title.

Gate: when the engine advertises `devin-cli`, the selected model appears as the agent's current
model and survives relaunch. Until then, the toast is the correct outcome.

**Phase 4 — engine support (other repo, out of scope here)**

- add the provider to the Rust engine catalog and pass `--model` to the ACP spawn;
- that is where `devin-cli/<model_uid>` becomes routable. This plan stops at the seam.

---

## 10. Open questions for Wael

- The popup lists the **whole usable corpus** (via `devin-reset --json list`), not only the two
  accounts that already have a usage snapshot. Confirm that is what "what accounts is logged in"
  means, because it changes the card count from 2 to 212 today and makes search mandatory.
- The catalog currently marks **one** variant `Free` and one `Low cost` on the logged-in Free
  account. The UI will show whatever the catalog says; if two free models are expected, the
  second one is not flagged in the JSON today. Confirm the badge rule (`Free` only) rather than
  guessing.
- `Switch account` and `Apply` stay two separate actions. Applying a model never logs out the
  current account. Confirm, because a one-click "apply and switch" is possible but surprising.
- The default for `Also update Devin.app` is on (same account in CLI and app, still no
  relaunch). Confirm if the TopBar should default to `--no-app` instead.
