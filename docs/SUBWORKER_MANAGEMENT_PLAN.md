# Subworker Management — EliaTopBar Enhancement Plan

## Overview

Extend ColimaBar (macOS menu bar app) to manage EliaAI subworkers via the FastAPI server running in Docker at `localhost:8080`. The topbar icon becomes a real-time dashboard showing WebSocket connection health, agent running states, and error alerts.

---

## Architecture

### Current State

- `Sources/ColimaBarApp.swift` — App entry, NSStatusItem, menu construction (394 lines)
- `Sources/ColimaManager.swift` — Colima instance management via CLI (305 lines)
- Uses Combine publishers for reactive updates, `NSMenu` for dropdown

### Target State

Add `Sources/SubworkerManager.swift` (~250 lines) as a second `ObservableObject`. Modify `ColimaBarApp.swift` to merge both data streams. No changes to `ColimaManager.swift`.

### Data Sources (FastAPI Server)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/health` | GET | Basic health check |
| `/status` | GET | All subworker statuses (name, enabled, running, next_run, schedule_type) |
| `/status/{name}` | GET | Detailed subworker status |
| `/trigger/{name}` | POST | Manually trigger a subworker |
| `/enable/{name}` | POST | Enable a subworker |
| `/disable/{name}` | POST | Disable a subworker |
| `/logs/{name}` | GET | Recent log lines (query: `lines=N`) |
| `/server/health` | GET | OpenCode server health (state, pid, restart_count, last_health_check) |
| `/server/restart` | POST | Restart OpenCode server |
| `/ws` | WebSocket | Real-time status stream |

### WebSocket Events

```
Client → Server:  {"type": "ping"}
Server → Client:  {"event": "pong"}

Server → Client:  {"event": "initial_status", "subworkers": [...], "scheduler_running": bool}
Server → Client:  {"event": "subworker_completed", "name": "..."}
Server → Client:  {"event": "subworker_error", "name": "..."}
```

---

## Tasks

### Task 1: SubworkerManager.swift — Data Layer

**File:** `Sources/SubworkerManager.swift` (NEW)

Create an `ObservableObject` managing all communication with the subworker server.

```swift
@MainActor
final class SubworkerManager: ObservableObject {
    // ── Published State ──
    @Published var wsConnected: Bool = false
    @Published var wsError: String?
    @Published var subworkers: [SubworkerInfo] = []
    @Published var serverHealth: ServerHealth?
    @Published var lastError: String?        // agent-level error
    @Published var runningCount: Int = 0
    @Published var totalEnabled: Int = 0

    // ── Computed ──
    var hasError: Bool { wsError != nil || lastError != nil }
    var allIdle: Bool { runningCount == 0 && !hasError }

    // ── WebSocket ──
    private var wsTask: URLSessionWebSocketTask?
    private var wsReconnectDelay: TimeInterval = 1.0
    private var pingTimer: Timer?

    // ── HTTP Polling (fallback) ──
    private var pollTimer: Timer?
    private var serverHealthTimer: Timer?

    func start()   // Connect WS + start fallback polling
    func stop()    // Tear down everything
}
```

**Structs:**

```swift
struct SubworkerInfo: Identifiable, Equatable {
    let id: String          // = name
    let name: String
    var enabled: Bool
    var running: Bool
    var nextRun: String?    // ISO timestamp
    var scheduleType: String?
    var lastError: String?  // from subworker_error events
    var lastCompleted: Date?
}

struct ServerHealth: Equatable {
    let state: String       // "running", "stopped", "error"
    let healthStatus: String
    let pid: Int?
    let restartCount: Int
}
```

**WebSocket Logic:**

- Connect to `ws://localhost:8080/ws` via `URLSessionWebSocketTask`
- On connect: set `wsConnected = true`, `wsError = nil`, reset backoff
- Send `{"type":"ping"}` every 30s for keepalive
- Parse incoming JSON:
  - `initial_status` → populate `subworkers` array, set `runningCount`
  - `subworker_completed` → update matching subworker, clear error, set `lastCompleted`
  - `subworker_error` → set `lastError`, mark subworker
  - `pong` → ignore
- On disconnect: set `wsConnected = false`, schedule reconnect with exponential backoff (1s → 2s → 4s → max 30s)
- Auto-reconnect on any connection loss

**HTTP Fallback:**

- When WS disconnected: poll `GET /status` every 5s
- Always poll `GET /server/health` every 30s (independent of WS)
- When WS reconnects: stop HTTP status polling (keep server health polling)

**Acceptance Criteria:**
- [ ] Compiles without errors
- [ ] Connects to WS on `start()`
- [ ] Reconnects after disconnect with backoff
- [ ] Parses all 3 event types
- [ ] Fallback HTTP polling works when WS is down
- [ ] `runningCount` stays accurate across events

---

### Task 2: Dynamic Menu Bar Icon

**File:** `Sources/ColimaBarApp.swift` → `updateStatusIcon()`

Enhance the status item icon to reflect subworker state.

**Icon Logic (priority order):**

| Priority | Condition | Icon | Color |
|----------|-----------|------|-------|
| 1 | WS disconnected | `circle.slash` | Red |
| 2 | Agent error | `exclamationmark.circle` | Red |
| 3 | Running agents > 0 | `circle.fill` + count badge | Green |
| 4 | All idle, WS connected | `circle` | Gray |

**Implementation:**

- Add `SubworkerManager` as a property on `AppDelegate`
- Merge `subworkerManager.$wsConnected`, `.$runningCount`, `.$hasError`, `.$lastError` into the existing `Publishers.MergeMany`
- Composite icon: render `NSImage` with base symbol + text overlay for count
- Use `NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)` for the base
- Overlay count as `NSAttributedString` positioned at top-right of the icon

**Acceptance Criteria:**
- [ ] Icon changes when WS connects/disconnects
- [ ] Icon shows green dot with count when agents running
- [ ] Icon turns red on error
- [ ] Icon updates within 1s of state change

---

### Task 3: Menu Section — Server Status

**File:** `Sources/ColimaBarApp.swift` → `setupMenu()`

Add a "Subworker Server" section after Colima instances.

**Menu Layout:**

```
── Subworker Server ──
● Connected │ 3 running / 14 enabled      ← status line
Server: Running (PID 12345, 0 restarts)   ← from /server/health
Last error: tiktok-content failed         ← if any
Reconnect                                   ← shown only when disconnected
```

**Implementation:**

- Section header: `NSMenuItem` with `NSAttributedString` for colored dot + text
- Status dot: `NSImage` with circle symbol tinted green/yellow/red/gray
- Server health line: show state + PID when available
- "Reconnect" item: visible only when `wsConnected == false`, calls `subworkerManager.start()`
- All info items disabled (no action on click)

**Acceptance Criteria:**
- [ ] Section appears after Colima instances
- [ ] Status dot color matches connection state
- [ ] Server health shows PID and restart count
- [ ] "Reconnect" appears only when disconnected
- [ ] "Reconnect" triggers WS reconnection

---

### Task 4: Menu Section — Subworker List

**File:** `Sources/ColimaBarApp.swift` → new `addSubworkerItems(to:)` method

Show each subworker with status indicator and actions.

**Menu Layout:**

```
── Active Agents ──
● refund-hunter           Running      ← green, bold
● mirorpay-community      Idle         ← green, dim
○ bene2luxe-promoter      Disabled     ← gray
⚠ tiktok-content          Error        ← red
```

**Per-Subworker Submenu:**

```
┌────────────────────────────┐
│ Status: Running             │
│ Next Run: 2026-08-16 21:00 │
│ Schedule: interval          │
│ ────────────────────────── │
│ View Logs…                  │
│ Trigger Now                 │
│ ────────────────────────── │
│ Disable                     │  ← or "Enable" if disabled
└────────────────────────────┘
```

**Implementation:**

- Color dot: `NSImage` with `circle.fill` symbol, tinted per state
  - Running → `.systemGreen`
  - Idle (enabled, not running) → `.systemGreen` with 0.5 opacity
  - Disabled → `.systemGray`
  - Error → `.systemRed`
- Name: truncated to 20 chars with ellipsis
- Status text: right-aligned via `NSMenuItem` with `NSMutableParagraphStyle`
- Submenu actions use `representedObject` to pass subworker name
- "Trigger Now" → `POST /trigger/{name}` via `URLSession`
- "Enable"/"Disable" → `POST /enable/{name}` or `POST /disable/{name}`

**Acceptance Criteria:**
- [ ] All subworkers from server appear in list
- [ ] Dots are color-coded correctly
- [ ] Submenu shows status, next run, schedule
- [ ] "Trigger Now" fires and shows confirmation
- [ ] "Enable"/"Disable" toggles and updates list
- [ ] List auto-refreshes on WS events

---

### Task 5: Real-Time Log Tail Popover

**File:** `Sources/ColimaBarApp.swift` → new `showLogs(for:)` method

Display recent log lines in a popover when "View Logs…" is clicked.

**Implementation:**

- "View Logs…" menu item triggers `showLogs(for: name)`
- Create `NSPopover` anchored to the status item
- Content: `NSScrollView` with `NSTextView`
  - Monospaced font (`SF Mono` or `Menlo`, 11pt)
  - Dark background (`NSColor.textBackgroundColor` inverted)
  - Scrollable, read-only
- Fetch `GET /logs/{name}?lines=50` via `URLSession`
- Display lines, auto-scroll to bottom
- "Refresh" button at bottom → re-fetches last 50 lines
- "Close" button → dismisses popover
- Optional: subscribe to `subworker_completed` WS event to auto-refresh

**Acceptance Criteria:**
- [ ] Popover appears on "View Logs…" click
- [ ] Shows last 50 lines of most recent log file
- [ ] Monospaced, dark background, scrollable
- [ ] "Refresh" fetches new lines
- [ ] "Close" dismisses popover
- [ ] Auto-scrolls to bottom on load

---

### Task 6: Server URL Preference

**File:** `Sources/ColimaBarApp.swift` → `setupMenu()` + new preference item

Allow configuring the server URL.

**Implementation:**

- Add "Server URL" submenu with a text field
- Persisted in `UserDefaults` under key `subworkerServerURL`
- Default: `http://localhost:8080`
- Changes trigger `SubworkerManager.stop()` → update base URL → `start()`
- Show current URL as disabled menu item above the text field

**Acceptance Criteria:**
- [ ] "Server URL" appears in menu
- [ ] Shows current URL
- [ ] Can be changed via alert with text field
- [ ] Change triggers reconnect to new URL
- [ ] Persists across app launches

---

## Visual Design

### Menu Bar Icon States

```
  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐
  │    ●    │    │   ●3    │    │    ⊘    │    │    ●    │
  │  (gray) │    │ (green) │    │  (red)  │    │  (red)  │
  └─────────┘    └─────────┘    └─────────┘    └─────────┘
   All idle      3 running      WS down        Agent error
```

### Status Dot Colors

| State | Color | Opacity |
|-------|-------|---------|
| Running | System Green | 1.0 |
| Idle (enabled) | System Green | 0.5 |
| Disabled | System Gray | 0.6 |
| Error | System Red | 1.0 |
| WS Connected | System Green | 1.0 |
| WS Reconnecting | System Yellow | 1.0 |
| WS Disconnected | System Red | 1.0 |

### Full Menu Layout

```
┌─────────────────────────────────────┐
│ ⚠ action error message              │  ← existing
│ ─────────────────────────────────── │
│ ● default (Running)                 │  ← existing Colima
│   Arch: aarch64                     │
│   CPUs: 4                           │
│   Memory: 8 GB                      │
│   Disk: 60 GB                       │
│ ─────────────────────────────────── │
│ ● Subworker Server                  │  ← NEW
│   Connected │ 3 running / 14        │
│   Server: Running (PID 12345)       │
│ ─────────────────────────────────── │
│ ● refund-hunter        Running      │  ← NEW agents
│ ● mirorpay-community   Idle         │
│ ○ bene2luxe-promoter   Disabled     │
│ ⚠ tiktok-content       Error        │
│ ─────────────────────────────────── │
│ Start All                           │
│ Stop All                            │
│ New Instance…                       │
│ ─────────────────────────────────── │
│ Refresh                             │
│ Refresh Interval                    │
│ Server URL                          │
│ Launch at Login                     │
│ ─────────────────────────────────── │
│ Quit ColimaBar                      │
└─────────────────────────────────────┘
```

---

## Implementation Order

| # | Task | Depends On | Est. Lines |
|---|------|------------|-----------|
| 1 | SubworkerManager.swift | — | ~250 |
| 2 | Dynamic icon | Task 1 | ~40 |
| 3 | Server status menu | Task 1 | ~60 |
| 4 | Subworker list | Task 1 | ~80 |
| 5 | Log tail popover | Task 4 | ~70 |
| 6 | Server URL pref | Task 1 | ~30 |

**Total new code:** ~530 lines across 2 files.

---

## File Changes

| File | Action | Lines Added |
|------|--------|-------------|
| `Sources/SubworkerManager.swift` | NEW | ~250 |
| `Sources/ColimaBarApp.swift` | MODIFY | ~280 |
| `Sources/ColimaManager.swift` | NO CHANGE | 0 |
| `Package.swift` | NO CHANGE | 0 |

---

## API Reference

### GET /status

```json
{
  "scheduler_running": true,
  "total": 14,
  "subworkers": [
    {
      "name": "refund-hunter",
      "enabled": true,
      "running": false,
      "next_run": "2026-08-16T21:00:00",
      "schedule_type": "interval"
    }
  ]
}
```

### GET /server/health

```json
{
  "state": "running",
  "health_status": "healthy",
  "pid": 12345,
  "base_url": "http://127.0.0.1:4096",
  "restart_count": 0,
  "last_health_check": {
    "status": "ok",
    "timestamp": "2026-08-16T20:30:00Z"
  }
}
```

### WebSocket /ws

```json
// On connect (initial snapshot)
{"event":"initial_status","scheduler_running":true,"total":14,"subworkers":[...]}

// Agent completed
{"event":"subworker_completed","name":"refund-hunter"}

// Agent errored
{"event":"subworker_error","name":"tiktok-content"}

// Client ping
{"type":"ping"} → {"event":"pong"}
```

### GET /logs/{name}?lines=50

```json
{
  "name": "refund-hunter",
  "log_file": "/data/subworkers/refund-hunter/workspace/logs/run.log",
  "lines": ["line 1", "line 2", "..."],
  "total_lines": 342
}
```
