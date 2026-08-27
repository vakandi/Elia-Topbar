# AGENTS.md — EliaTopBar

## What This Is
Native macOS menu bar app (Swift 5.9, macOS 13+). Command center for the Elia agent ecosystem. No dock icon (`LSUIElement=true`). No Xcode project — pure SPM build via shell scripts.

## Architecture
```
Sources/
├── EliaTopBarApp.swift      1980L  @main, AppDelegate, menu bar, all callbacks, TunnelProgressPanelController, NSMenuDelegate
├── SubworkerManager.swift    895L  WebSocket + REST client for EliaFastAPI (localhost:5656)
├── LogPopoverView.swift      833L  Per-agent session browser (messages, tools, live stream)
├── MarkdownView.swift        347L  Custom SwiftUI markdown renderer (block-cached)
├── ColimaManager.swift       305L  Colima Docker VM management via CLI subprocess
├── RunPopupController.swift  216L  Animated agent-run notification overlay (NSPanel)
├── SchedulePopoverView.swift 204L  Interval schedule editor (hours, minute, days)
├── TopbarSettingsView.swift  193L  Menu bar placement, photo side, padding settings
├── ProfilePhotos.swift       138L  Circular crop + Application Support storage
└── Info.plist                     Bundle config (com.elia.elia-topbar)
```

## Key Data Flow
```
EliaTopBarApp.swift (AppDelegate)
  ├── SubworkerManager ──WebSocket──▶ FastAPI server :5656
  │     ├── subworkers: [SubworkerInfo]
  │     ├── serverHealth: ServerHealth
  │     └── modelSelections (reads/writes /Users/vakandi/EliaAI/ui_electron/model-selections.json)
  ├── ColimaManager ──CLI──▶ colima status/start/stop/delete/ssh
  ├── ProfilePhotos ──FileSystem──▶ ~/Library/Application Support/EliaTopBar/ProfilePhotos/
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
