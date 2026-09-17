<!-- Banner -->
<p align="center">
  <img src="assets/banners/banner.png" alt="EliaTopBar — Menu bar command center for Elia subworkers" width="100%">
</p>

<!-- Tagline -->
<p align="center">
  <strong>Native macOS menu bar command center for the Elia agent ecosystem.</strong><br>
  Live subworker status, Drop livestreams, subagent matrix, todo tracking — plus full Colima instance control.
</p>

<!-- Badges -->
<p align="center">
  <a href="https://github.com/vakandi/Elia-Topbar/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT"></a>
  <a href="https://img.shields.io/badge/Swift-5.9-orange"><img src="https://img.shields.io/badge/Swift-5.9-orange.svg" alt="Swift 5.9"></a>
  <a href="https://img.shields.io/badge/macOS-13%2B-blue"><img src="https://img.shields.io/badge/macOS-13%2B-blue.svg" alt="macOS 13+"></a>
  <a href="https://github.com/vakandi/EliaAgent"><img src="https://img.shields.io/badge/Connects%20to-EliaAgent-8B5CF6.svg" alt="Connects to EliaAgent"></a>
  <a href="https://img.shields.io/badge/PRs-Welcome-EC4899"><img src="https://img.shields.io/badge/PRs-Welcome-EC4899.svg" alt="PRs Welcome"></a>
</p>

<!-- UI Screenshots -->
<p align="center">
  <img src="docs/screenshot-menu.png" alt="EliaTopBar menu — Subworker Server, Active Agents, Manual Run, Colima instances" width="420">
  <img src="docs/screenshot-agents.png" alt="EliaTopBar active agents — live subworker states and controls" width="300">
</p>

---

## What Is This?

**EliaTopBar** sits in your macOS menu bar and gives you real-time command over the
[Elia agent ecosystem](https://github.com/vakandi/EliaAgent) — without opening a browser
or terminal. It connects over **WebSocket** to the Elia FastAPI server (`localhost:5656`)
and turns every subworker into a live, actionable dashboard row.

- 🟢 **Live agent states** pushed over WebSocket — running, idle, disabled, error, done
- 📍 **Per-agent menu bar icons** — each running subworker gets its own top-bar dot with a
  monogram, colored by state (green = healthy, red = error)
- 💬 **Drop livestreams** — when an agent starts, its photo drops from the menu bar
  with a live chat bubble streaming the run output (terminal/tool/skill/todo banners) —
  visible even over fullscreen video, draggable anywhere, auto-retracts, click to dismiss
- 🧬 **Subagent matrix** — background agents, team members and delegated tasks surface as
  live Grok pills in a side strip (left/right) with per-team grouping, kind badges and
  click-to-expand full livestream bubbles
- ✅ **Todo tracking** — fused todo card + hover side panel with live progress, one line per task
- 🖱️ **Click-to-view LogViewer** — click an agent photo to open the full session browser
  (sessions, messages, reasoning, tool calls, live stream), always clamped inside the screen
- 🎭 **Profiles** — Developer (full livestream), Calm (essentials), Minimal (dots + LogViewer)
  one-tap setups for dev and non-dev use
- ⚡ **Manual Run Subworker** — trigger any subworker on demand from a dropdown
- 🔁 **Enable / Disable, next run, schedule** — per-agent submenu with everything you need
- ⚙️ **Topbar Settings** — profiles, Drop panels, menu bar layout with live preview,
  run animation, viewer choice — zero permissions required
- ❤️ **Server health** — connection state, PID, restart count, reconnect button, one-click RAM cleanup
- ⏱️ **Loading + error states everywhere** — every server-loaded menu shows a spinner
  while fetching, then data — or the full error message if it fails

It also retains full **Colima** container management: start / stop / restart instances,
open a shell, inspect resources, delete, auto-refresh and launch-at-login.

---

## ✨ Features

### 🤖 Subworker Dashboard (EliaAgent)

| Feature | Description |
|---------|-------------|
| **WebSocket live updates** | Real-time status pushed from the Elia FastAPI server (`ws://localhost:5656/ws`) |
| **Active Agents list** | Every subworker with live state: `⚡ Running`, `⏸️ Idle`, `⛔ Disabled`, `💥 Error`, `✅ Done` |
| **Per-agent top bar icons** | Running agents each get a colored status dot with their monogram in the menu bar |
| **Run popup animation** | Agent photo drops from the icon + live output bubble when a run starts — visible over fullscreen video, draggable (stays where dropped), auto-retracts (configurable), click to dismiss |
| **Drop livestream** | Full renderer mirroring LogViewer: terminal / skill / todo / edit / write banners, coalesced reasoning, traffic `↓/↑`, tool+message counters, session switcher |
| **Subagent matrix** | `call_omo` (bg) / `team` / `task` pills with static-square Grok animation while working, `✅` when done (result-collected detection), per-team columns, expandable bubbles |
| **Todo strip** | Fused todo card in-bubble + hover side panel with `done/total`, one row per task, colored status dots |
| **LogViewer** | Full session browser per agent: sessions list, messages, reasoning, tool-call banners, live stream — always clamped inside the screen |
| **Profiles** | Developer / Calm / Minimal one-tap setups — full livestream for builders, essentials for followers, dots-only for non-devs |
| **Drop panels settings** | Show/hide stats header, todo strip, subagent strip; subagents left/right; team tasks above/side — all live, no restart |
| **Topbar Settings panel** | Version badge, logo, GitHub link, agent photos side (left/right of banner), live padding slider, run animation duration + test trigger — no permissions needed |
| **Manual Run Subworker** | Trigger any subworker from a dropdown — no terminal needed |
| **Per-agent submenu** | Status, next run, schedule, last run, view logs, trigger now, enable / disable |
| **Server health section** | Connection state, running/total counts, server state + PID + restarts, reconnect |
| **Change Server URL** | Point the app at any Elia server instance |
| **Loading animations** | `NSProgressIndicator` spinner on every server-loaded menu while fetching |
| **Full error display** | Failures show the complete error message (with tooltip on hover) |

### 🐳 Colima Instance Management

| Feature | Description |
|---------|-------------|
| **Instance list** | All Colima instances in the menu, `●` running / `○` stopped |
| **Instance submenu** | Status, arch, CPUs, memory, disk |
| **Start / Stop / Restart** | Control each instance individually |
| **Open Shell** | Launch Terminal and SSH into the running instance |
| **Delete…** | Remove an instance (with confirmation) |
| **Auto-refresh** | Configurable polling interval (5 / 10 / 30 / 60 seconds) |
| **Launch at Login** | Start automatically when you log in |

---

## 🔗 Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  EliaTopBar  (this repo — macOS menu bar app, Swift 5.9)       │
│                                                                │
│   menu bar icon  ◄─── dynamic state (running / error / idle)   │
│   per-agent dots ◄─── monogram + state color per subworker     │
│   log popover    ◄─── hover any agent dot                      │
└──────────────────────────────┬─────────────────────────────────┘
                               │ WebSocket (ws://localhost:5656/ws)
                               │ HTTP  (/status, /trigger, /enable,
                               │        /disable, /logs, /server/health)
                               ▼
┌────────────────────────────────────────────────────────────────┐
│  EliaAgent  (github.com/vakandi/EliaAgent — FastAPI in Docker) │
│                                                                │
│   subworker scheduler  ◄─── agents run on schedule or trigger  │
│   /ws real-time events  ─── initial_status, subworker_completed│
│                            subworker_error, pong               │
└────────────────────────────────────────────────────────────────┘
```

EliaTopBar is the **control surface**; [EliaAgent](https://github.com/vakandi/EliaAgent)
is the **engine**. The app is deliberately thin — all state, scheduling and log storage
lives on the server, and the menu bar just renders it.

---

## 🚀 Quick Start

### Download

Grab the latest DMG or ZIP from the
[releases page](https://github.com/vakandi/Elia-Topbar/releases/latest):
download `EliaTopBar-vX.Y.Z-arm64.dmg`, open it, drag **EliaTopBar** to Applications.

### Build from Source

```bash
git clone https://github.com/vakandi/Elia-Topbar.git
cd Elia-Topbar
./build-app.sh          # universal arm64 + x86_64, ad-hoc signed
open EliaTopBar.app
```

To create a distributable DMG:

```bash
./build-dmg.sh
```

### Run against your Elia server

1. Make sure the [EliaAgent](https://github.com/vakandi/EliaAgent) FastAPI server is
   running on `localhost:5656` (Docker).
2. Launch EliaTopBar.
3. In the menu, use **Change Server URL…** if your server runs elsewhere.

The app auto-connects on launch — no config file, no env vars.

---

## 📖 Usage

### Menu overview

Click the menu bar icon to open the dashboard:

- **🤖 Subworker Server** — connection status, `Connected │ X running / Y enabled`,
  server health (state, PID, restarts), reconnect when disconnected.
- **🤖 Active Agents** — one row per subworker; hover shows its state dot; click to
  expand: status, next run, schedule, error, last run, **View Logs…**, **⚡ Trigger
  Now**, **⏸️ Disable** / **▶️ Enable**.
- **Manual Run Subworker** — dropdown listing every subworker; pick one to trigger it.
- **Change Server URL…** — point at a different Elia server.
- Colima section — instances, refresh interval, launch at login, quit.

### Per-agent menu bar dots

Running subworkers appear as individual dots in the menu bar:

| Dot | Meaning |
|-----|---------|
| 🟢 Green | Subworker running, no errors |
| 🔴 Red | Last run ended in error |
| Monogram | First letters of the agent name |

**Hover** any dot to open a live log overlay (auto-refreshing every 2s).

### Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| `R` | Refresh status |
| `Q` | Quit |

---

## ⚙️ Configuration

| Setting | How | Default |
|---------|-----|---------|
| Server URL | Menu → **Change Server URL…** | `http://localhost:5656` |
| Profile | Topbar Settings → **Profile** | Developer |
| Stats header / Todo / Subagents | Topbar Settings → **Drop panels** | all on |
| Subagents side | Topbar Settings → **Drop panels → Subagents** | Right of bubble |
| Team tasks | Topbar Settings → **Drop panels → Team tasks** | Right side bar |
| Agent photos side | Topbar Settings → **Agent photos** | Left of banner |
| Icon padding | Topbar Settings → **Left / Right padding** (live preview) | 3 pt |
| Primary style when running | Topbar Settings → **Primary when running** | Default (banner + count) |
| Viewer on click | Topbar Settings → **Viewer & icons** | Log Viewer (full) |
| Draggable Drops | Topbar Settings → **Run animation** | off |
| Run popup duration | Topbar Settings → **Run animation** (0 = off) | 10 s |
| Refresh interval | Menu → **Refresh Interval** (Colima section) | 5 s |
| Launch at Login | Menu → **Launch at Login** | off |

### EliaTopBar vs [Open Island](https://github.com/Octane0411/open-vibe-island)

[Open Island](https://github.com/Octane0411/open-vibe-island) (and Vibe Island) monitor
**local** coding sessions — Claude Code, Codex, Cursor, … running in your own terminals.
EliaTopBar is the same idea pointed at a different target: a **dedicated OpenCode server**
([EliaAgent](https://github.com/vakandi/EliaAgent)) running **autonomous scheduled subworkers**.

| | Open Island | EliaTopBar 2.0 |
|---|---|---|
| Watches | Local CLI sessions on your Mac | Server subworkers (scheduled + triggered) |
| Connection | Local hooks / JSONL polling | WebSocket + REST to EliaAgent (`:5656`) |
| Subagents / teams | — | Live matrix: bg agents, team members, delegated tasks |
| Todos | — | Fused card + side panel, live progress |
| Trigger / schedule agents | — | Manual run, enable/disable, schedules, server cleanup |
| Profiles | — | Developer / Calm / Minimal |
| Containers | — | Full Colima management |

---

## 📊 Load Test (v2.0.4)

Stress run on a real machine — 4 agents triggered at once while a 5th was
already running, all with live Drop livestream panels open:

| Metric | Value |
|--------|-------|
| Machine | MacBook Pro, Apple M5, 16 GB RAM, macOS 26.5.2 |
| App | EliaTopBar v2.0.4, 11 MB bundle, 9 threads |
| Load | 5 concurrent live panels (`refund-hunter`, `deploymates-watch`, `cve-hunter`, `app-qa-store-gate` + `app-clone-factory`) |
| CPU idle (panels open, no animation storm) | ~3 % |
| CPU during 5-panel drop storm | 10–17 % |
| RAM (RSS) | 50–64 MB |
| Result | No crash, all panels shown + auto-retracted, dots clickable throughout |

---

## ✅ Requirements

| Requirement | Detail |
|-------------|--------|
| macOS | 13.0+ (Ventura or newer) |
| Swift toolchain | 5.9+ (for building from source) |
| [EliaAgent](https://github.com/vakandi/EliaAgent) | FastAPI server, default `localhost:5656` (optional for subworker features) |
| [Colima](https://github.com/abiosoft/colima) | `brew install colima` (optional — only for container management) |

### First launch note

EliaTopBar is ad-hoc signed, not notarized by Apple, so on first launch macOS shows an
"unidentified developer" warning. Right-click the app in Applications and choose **Open**,
then confirm. If macOS still refuses:

```
xattr -dr com.apple.quarantine /Applications/EliaTopBar.app
```

---

## 🤝 Contributing

PRs welcome! Keep it lightweight — this app is intentionally a thin client. Bug reports
and feature ideas are best filed with the exact menu path and, for server-side issues,
in the [EliaAgent](https://github.com/vakandi/EliaAgent) repo.

---

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.
