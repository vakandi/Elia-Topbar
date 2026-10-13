# AGENTS.md — EliaTopBar

## What This Is
Native macOS menu bar app (Swift 5.9, macOS 13+). Command center for the Elia agent ecosystem. No dock icon (`LSUIElement=true`). No Xcode project — pure SPM build via shell scripts.

## The Two Servers — do not confuse them

They are different processes, different ports, different repos, and the menu
shows controls for both in the *same* submenu.

| | Subworker bridge | OpenCode Rust engine |
|---|---|---|
| Repo | `~/Documents/subworker-opencode-rust` | `~/Documents/subworker-opencode-rust/server` |
| What it is | The `control/` bridge app (Bun/TypeScript) | The vendored engine (Rust) |
| Port | 5656 | 5655 (configurable) |
| Binary | `bun`, cwd `<repo>/control` | `<repo>/server/target/release/opencode` |
| Managed by | `SubworkerManager` (WebSocket + REST) | `OpenCodeServerManager` (CLI subprocess) |

**Both live in the same repo.** The engine is vendored at `server/` inside
`subworker-opencode-rust`; there is no separate `~/Documents/opencode-rust`
that anything loads. That folder was a redundant clone of `vakandi/opencode-rust`
and pointing the app at it meant the menu resolved a binary the subworker system
never used. `OpenCodeServerManager.repoPath` now defaults to
`<subworker repo>/server` via `SubworkerServerManager.configuredRepoPath`.

The "🦀 OpenCode Rust Server" block in the menu manages the engine only.

### The three runtimes inside `subworker-opencode-rust`

The repo name says Rust, but three different runtimes live in it. Confusing
them caused a wrong claim that `/tunnel/*` did not exist:

- **`control/` — Bun/TypeScript, port 5656. This is the API EliaTopBar talks to.**
  A thin bridge: it owns the agent registry, scheduler, `/ws` stream, and the
  `/tunnel/*` endpoints. It does not run agents itself — it reads OpenCode's
  state and relays it. The `FastAPI` name in older docs is wrong; commit
  `0cab9c2` ("replace Python/Docker stack with Rust server") removed Python.
- **`server/` — a Rust crate beside it.** The vendored OpenCode engine, port 5655.
  Not what serves 5656. Don't grep it looking for routes.
- **`~/Documents/opencode-rust` — a redundant clone.** Same upstream as `server/`,
  but nothing loads it. Do not point the app there.

Confirm before trusting any runtime assumption:

```bash
lsof -nP -iTCP:5656 -sTCP:LISTEN   # shows the real process (bun)
```

### Both servers' folders are configurable, and are not compile-time constants

Neither path is hardcoded. They live in `🔌 Server Connection Settings`:

- 🦀 **Rust repo** — `opencodeServerRepoPath`, defaults to
  `~/Documents/subworker-opencode-rust/server`
- 🦀 **Rust binary** — `opencodeServerBinaryPath`, an explicit override. Empty means
  auto-detect: repo build, then `opencoderust`/`opencode-rust` on PATH, then
  `~/.local/bin/opencoderust`
- 📁 **Subworker repo** — `subworkerServerRepoPath`, defaults to
  `~/Documents/subworker-opencode-rust`. The port and auth token are read from
  this repo (`control/config/server.json`, `.env`), not assumed.

Looking only inside `<repo>/target/release/opencode` reported "Not built" on a
machine where the engine was installed and working on PATH. Always resolve via
`OpenCodeServerManager.binaryPath`, which searches all of the above.

## Architecture
```
Sources/
├── EliaTopBarApp.swift      3269L  @main, AppDelegate, menu bar, all callbacks, TunnelProgressPanelController, NSMenuDelegate
├── LogPopoverView.swift     2032L  Per-agent session browser (messages, tools, live stream)
├── RunPopupController.swift 1495L  Animated agent-run notification overlay (NSPanel, pooled)
├── SubworkerManager.swift   1228L  WebSocket + REST client for the subworker server :5656
├── TopbarSettingsView.swift  606L  Menu bar placement, photo side, padding settings
├── OpenCodeServerManager.swift 525L  Start/stop/health for the opencode Rust server
├── ColimaManager.swift       307L  Colima Docker VM management via CLI subprocess
├── MarkdownView.swift        347L  Custom SwiftUI markdown renderer (block-cached)
├── JSONTreeDisplay.swift     360L  Tool-input/output tree renderer
├── NotchIslandView.swift     328L  Notch island rendering
├── SchedulePopoverView.swift 339L  Interval schedule editor (hours, minute, days)
├── ProfilePhotos.swift       138L  Circular crop + downsampled Application Support storage
├── SelfTest.swift            170L  Env-gated stress harness (see below)
└── Info.plist                     Bundle config (com.elia.elia-topbar)

Lib/
└── BoundedLogWriter.swift          Capped, coalescing, off-main log writer

Tests/PerfTests/main.swift           Runnable assertions (XCTest unavailable on CLT-only machines)
```

## Stress harness (how the perf numbers are measured)

GUI automation cannot reach a `LSUIElement` status item, so popups and log
viewers are driven through the real menu entry points, gated on env vars and
inert otherwise:

```bash
ELIATOPBAR_SELFTEST_CYCLES=100 EliaTopBar.app/Contents/MacOS/EliaTopBar  # popup + log viewer cycles
ELIATOPBAR_SELFTEST_BURST=30 ELIATOPBAR_SELFTEST_BURSTS=10 …           # 30-popup bursts
ELIATOPBAR_SELFTEST_HOLD=60 …                                          # leave popups up, for a screenshot
ELIATOPBAR_SELFTEST_NOEXIT=1 …                                         # stay alive for leaks/heap
```

Gotcha that cost a measurement: `RunPopupController.show()` returns early when
`duration <= 0`, so a harness passing `duration: 0` silently opens nothing.

## Key Data Flow
```
EliaTopBarApp.swift (AppDelegate)
  ├── SubworkerManager ──WebSocket/REST──▶ control/ (Bun bridge) :5656
  │     ├── subworkers: [SubworkerInfo]
  │     ├── serverHealth: ServerHealth
  │     └── modelSelections (reads/writes ~/EliaAI/ui_electron/model-selections.json)
  ├── OpenCodeServerManager ──CLI──▶ subworker-opencode-rust/server :5655 (start/stop/health)
  ├── ColimaManager ──CLI──▶ colima status/start/stop/delete/ssh
  ├── ProfilePhotos ──FileSystem──▶ ~/Library/Application Support/EliaTopBar/agent_photos/
  └── Menu (NSMenu) ──▶ all UI
```

## Build & Release
```bash
./build-app.sh v2.3      # arm64+x86_64 .app bundle + ad-hoc sign
./build-dmg.sh v2.3      # wraps build-app.sh + hdiutil DMG
```
- No CI/CD. Manual builds only.
- Ad-hoc codesigned (`codesign --sign -`). No notarization. Users: `xattr -dr com.apple.quarantine EliaTopBar.app`.
- Version patched at build time via PlistBuddy (Info.plist hardcodes `1.0.1` but is overridden).

### Install the build you just made — not the last release

**`brew reinstall --cask eliatopbar` does NOT install your working tree.** The
cask downloads the published DMG for its pinned version from GitHub, so a
reinstall silently replaces your local build with an older release. This cost
real time: three separate fixes appeared "not working" because every test ran
the release binary while the fix sat in the local build.

To run what you just built:

```bash
pkill -f "/Applications/EliaTopBar.app"
rm -rf /Applications/EliaTopBar.app
cp -R ~/Documents/EliaTopBar/EliaTopBar.app /Applications/EliaTopBar.app
open /Applications/EliaTopBar.app
```

Confirm which binary is actually running before trusting any menu behaviour:

```bash
strings /Applications/EliaTopBar.app/Contents/MacOS/EliaTopBar | grep -c "<a-string-from-your-fix>"
stat -f "%Sm" /Applications/EliaTopBar.app/Contents/MacOS/EliaTopBar
```

Only use `brew reinstall --cask` after cutting a release, so the cask and the
DMG on GitHub carry the same build. Bumping the version in `Casks/eliatopbar.rb`
and running `./scripts/sync-brew-tap.sh` does not help on its own — the script
verifies the sha256 against the local DMG, but the tap is only useful once that
DMG is published.

## Server API (Bun bridge at localhost:5656)
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Basic health |
| `/status` | GET | All subworker statuses |
| `/status/{name}` | GET | Detailed subworker status |
| `/trigger/{name}` | POST | Manually trigger a subworker |
| `/enable/{name}` | POST | Enable a subworker |
| `/disable/{name}` | POST | Disable a subworker |
| `/logs/{name}` | GET | Recent log lines (query: `lines=N`) |
| `/server/health` | GET | OpenCode server health (state, pid, restart_count) |
| `/server/restart` | POST | Restart OpenCode server |
| `/tunnel/status` | GET | Cloudflare tunnel status |
| `/tunnel/setup` | POST | Start tunnel setup (domain, api_token) |
| `/tunnel/remove` | POST | Delete tunnel + DNS record |
| `/ws` | WebSocket | Real-time status stream |

## Known Technical Debt
- **EliaTopBarApp.swift is a 3300-line God Object.** Contains AppDelegate, menu construction, icon rendering, hover handling, tunnel progress panel, and all UI callbacks. Decomposition is overdue.
- **Hardcoded auth token** in `SubworkerManager.swift` (`EliaAuth.defaultToken`). Bearer token in source, extractable via `strings`. `SubworkerServerManager.applyRepoSettings()` now re-reads it from the subworker repo's `.env`, so a rotated token is picked up, but the literal is still in the binary. Should use Keychain.
- **Model selections path** defaults to `~/EliaAI/ui_electron/model-selections.json` with a `modelSelectionsPath` override. The `/data/` → host rewrite resolves through `LocalPaths` against the configured repo. No `/Users/<name>` literals remain.
- **Tests are a standalone executable, not XCTest.** `swift run -c release PerfTests` asserts and exits non-zero. XCTest and Swift Testing are both unavailable on a CLT-only machine (`_Testing_Foundation` ships without a swiftmodule).
- **Mixed async patterns.** `DispatchQueue.main.async` coexists with `@MainActor` + `Task { @MainActor }`. SubworkerManager is `@MainActor` but some callbacks still dispatch via GCD.
- **`docs/SUBWORKER_MANAGEMENT_PLAN.md` references port 8080** but server runs on 5656. Stale spec.
- **Cloudflare API token stored in UserDefaults** (`cfApiToken` key). Plaintext, no encryption. Should use Keychain.

## Conventions
- **UI split:** AppKit for `NSStatusItem`/`NSMenu` (menu bar), SwiftUI for popover views (`LogPopoverView`, `SchedulePopoverView`, `TopbarSettingsView`, `MarkdownView`).
- **Model enums:** `SubworkerInfo`, `ServerHealth`, `ColimaStatus`, `ColimaInstance` — all `Codable` + `Equatable`.
- **Networking:** `URLSession.shared.dataTask` with completion handlers + `URLSessionWebSocketTask` for real-time. Auth via `EliaAuth.authorize(_:)` which adds `Authorization: Bearer <token>` header.
- **Photo storage:** `~/Library/Application Support/EliaTopBar/ProfilePhotos/<agent>.png` — circular-cropped `NSImage`.
- **Defaults:** `UserDefaults` keys: `subworkerServerURL`, `tunnelDomain`, `cfApiToken`, `menuBarPlacement`, `menuBarPhotoSide`, `menuBarPadding`, `menuBarOrderMode`, `animationEnabled`, `showRunPopup`, `modelSelectionsPath`.
- **Emoji-aware titles:** `emojiAwareTitle(_:color:)` wraps `NSAttributedString` for `NSMenuItem` titles that contain emoji.
- **No force-unwraps in new code** — existing ones are technical debt (see Known Technical Debt).

## Files Agents Should NOT Edit
- `build-app.sh`, `build-dmg.sh` — release infrastructure, edit only for build pipeline changes
- `Info.plist` — version patched at build time, manual edits will be overwritten
- `docs/index.html` — GitHub Pages marketing site, separate concern
- `.omo/` — OpenCode agent state, gitignored, never commit

## Files Agents Should Edit
- `Sources/*.swift` — all application logic
- `Package.swift` — only if adding targets or dependencies
- `docs/superpowers/` — feature specs and implementation plans
