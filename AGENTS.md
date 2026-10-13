# AGENTS.md — EliaTopBar

## What This Is
Native macOS menu bar app (Swift 5.9, macOS 13+). Command center for the Elia agent ecosystem. No dock icon (`LSUIElement=true`). No Xcode project — pure SPM build via shell scripts.

## The Two Servers — do not confuse them

They are different processes, different ports, different repos, and the menu
shows controls for both in the *same* submenu.

| | Subworker server | OpenCode Rust server |
|---|---|---|
| Repo | `~/Documents/subworker-opencode-rust` | `~/Documents/opencode-rust` |
| What it is | The FastAPI subworker API | The agent engine (`opencode serve`) |
| Port | 5656 | 3000 (configurable) |
| Binary | run via its own launcher | `target/release/opencode` |
| Managed by | `SubworkerManager` (WebSocket + REST) | `OpenCodeServerManager` (CLI subprocess) |

**`~/Documents/subworker-opencode-rust` is the server EliaTopBar controls.**
It is what `subworkerServerURL` points at and what every agent status,
trigger, enable/disable and log line comes from. Do not point the app at
`opencode-rust` expecting subworker data, and do not edit either repo —
they are separate repositories that EliaTopBar only talks to.

The "🦀 OpenCode Rust Server" block in the menu manages `opencode-rust` only.
Its repo path is overridable via the `opencodeServerRepoPath` default.

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
  ├── SubworkerManager ──WebSocket/REST──▶ subworker-opencode-rust :5656
  │     ├── subworkers: [SubworkerInfo]
  │     ├── serverHealth: ServerHealth
  │     └── modelSelections (reads/writes /Users/vakandi/EliaAI/ui_electron/model-selections.json)
  ├── OpenCodeServerManager ──CLI──▶ opencode-rust :3000 (start/stop/health)
  ├── ColimaManager ──CLI──▶ colima status/start/stop/delete/ssh
  ├── ProfilePhotos ──FileSystem──▶ ~/Library/Application Support/EliaTopBar/agent_photos/
  └── Menu (NSMenu) ──▶ all UI
```

## Build & Release
```bash
./build-app.sh v1.4.0    # universal binary (arm64+x86_64) + .app bundle + ad-hoc sign
./build-dmg.sh v1.4.0    # wraps build-app.sh + hdiutil DMG
```
- No CI/CD. Manual builds only.
- Ad-hoc codesigned (`codesign --sign -`). No notarization. Users: `xattr -dr com.apple.quarantine EliaTopBar.app`.
- Version patched at build time via PlistBuddy (Info.plist hardcodes `1.0.1` but is overridden).

## Server API (FastAPI at localhost:5656)
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
- **EliaTopBarApp.swift is a 1980-line God Object.** Contains AppDelegate, menu construction, icon rendering, hover handling, tunnel progress panel, and all UI callbacks. Decomposition is overdue.
- **Hardcoded auth token** in `SubworkerManager.swift:63` (`EliaAuth.defaultToken`). Bearer token in source, extractable via `strings`. Should use Keychain.
- **Hardcoded filesystem path** in `SubworkerManager.swift:47` (`/Users/vakandi/EliaAI/ui_electron/model-selections.json`). Breaks on any other user.
- **Zero tests.** No test target in `Package.swift`, no `*Test*.swift` files, no XCTest imports. 5111 lines of untested code.
- **Mixed async patterns.** `DispatchQueue.main.async` (16 sites) coexists with `@MainActor` + `Task { @MainActor }` (36 sites). SubworkerManager is `@MainActor` but some callbacks still dispatch via GCD.
- **`AppLog.debug = true` hardcoded** (SubworkerManager.swift:7). Debug logging always on in production builds.
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
