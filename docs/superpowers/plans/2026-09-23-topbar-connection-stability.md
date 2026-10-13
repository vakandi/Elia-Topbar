# TopBar ↔ OMP Connection Stability Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the 30–40% RED disconnected time on EliaTopBar pointed at the OMP server (`http://localhost:5677`).

**Architecture:** Fix the ping/pong contract mismatch at both ends, then make the Swift client tolerant (2-strike watchdog, longer timeouts, HTTP-aware icon, dual-server failover to healthy `:5656`).

**Tech Stack:** Swift 5.9 SPM (EliaTopBar), Bun TypeScript (`/Users/vakandi/Documents/omp-server/omp-server/server.ts`), Python FastAPI reference (`/Users/vakandi/EliaAI/subworkers/server/app/routes/websocket.py`), Docker (`omp-server-omp-server-1`, `elia-subworker-srv`).

---

## Root cause (proven live 2026-09-23)

- TopBar sends JSON ping: `Sources/SubworkerManager.swift:606` → `{"type":"ping"}`, expects `{"event":"pong"}` (`:377-386`).
- OMP server only answers raw string: `omp-server/server.ts:159-162` → `if (text === "ping")`. `'{"type":"ping"}' !== 'ping'`, so it **never** pongs.
- Python server parses JSON (`websocket.py:183-184` → `msg.get("type") == "ping"`), so `:5656` pongs fine.
- Live probe: `:5677` INIT ok + PONG TIMEOUT 8s; `:5656` INIT ok + PONG ok.
- Log proof (`~/Library/Logs/EliaTopBar/debug.log`): `Received pong` = **0**, `No pong within 10s` = **57**, `Connecting WS to …:5677` = **68**, to `:5656` = **0**. Saved URL = `http://localhost:5677` (`defaults read com.elia.elia-topbar subworkerServerURL`).
- Cycle: ping @30s → no pong → watchdog @10s → `handleDisconnect()` (`:570-582`) sets `wsConnected=false` (RED icon via `NotchIslandView.swift:47` + `EliaTopBarApp` icon key) → reconnect 1–2s → repeat. `initial_status` (59×) proves transport works; only the heartbeat is broken.
- Aggravators: 1.0s connect timeout (`:292-300`) too aggressive for Docker/SSH-mux path (`ssh …/colima/ssh.sock` PID 49901 forwards `:5677`); single `baseURL` with zero failover to healthy `:5656`; icon bound to `wsConnected` alone while HTTP `/status` on `:5677` stays healthy.

---

## Files touched

- Fix: `/Users/vakandi/Documents/omp-server/omp-server/server.ts:157-165` (accept JSON ping)
- Fix: `/Users/vakandi/Documents/EliaTopBar/Sources/SubworkerManager.swift:596-638` (2-strike watchdog, timeouts, dual-server failover, HTTP-aware status)
- Verify: `~/Library/Logs/EliaTopBar/debug.log`, `docker ps`, `curl` + WS probe, `defaults read com.elia.elia-topbar subworkerServerURL`
- Rebuild: omp-server Docker image + compose restart

---

### Task 1: OMP server accepts JSON ping (root fix)

**Files:**
- Modify: `/Users/vakandi/Documents/omp-server/omp-server/server.ts:157-165`

- [ ] **Step 1: Apply the fix**

```ts
message(ws, msg) {
  const text = typeof msg === "string" ? msg : "";
  if (text === "ping") { ws.send(JSON.stringify({ event: "pong" })); return; }
  try {
    const obj = JSON.parse(text);
    if (obj && (obj.type === "ping" || obj.event === "ping")) ws.send(JSON.stringify({ event: "pong" }));
  } catch { /* ignore non-JSON frames */ }
},
```

- [ ] **Step 2: Rebuild + restart OMP server**

Run: `cd /Users/vakandi/Documents/omp-server && docker compose build omp-server && docker compose up -d omp-server && sleep 5 && docker ps --format "{{.Names}} {{.Status}}" | grep omp-server`
Expected: `omp-server-omp-server-1 Up … (healthy)`

- [ ] **Step 3: Prove pong works**

Run: `python3 -c "import asyncio,json; from websockets.asyncio.client import connect; ..." # or reuse eval probe: connect ws://localhost:5677/ws?token=$TOKEN, send '{"type":"ping"}', expect '{"event":"pong"}' within 5s`
Expected: `PONG={"event": "pong"}` on `:5677` (today: TIMEOUT)

---

### Task 2: Client 2-strike watchdog + sane timeouts

**Files:**
- Modify: `Sources/SubworkerManager.swift:157-163` (add `missedPongs` counter), `:292-300` (timeout 1s→5s), `:596-638` (watchdog)

- [ ] **Step 1: Add missed-pong counter**

```swift
private var missedPongs = 0  // alongside awaitingPong (SubworkerManager.swift:163)
```

- [ ] **Step 2: Watchdog requires 2 consecutive misses**

```swift
private func startPongWatchdog() {
    pongWatchdog?.invalidate()
    pongWatchdog = scheduleTimer(interval: 10.0, repeats: false) { [weak self] _ in
        Task { @MainActor [weak self] in
            guard let self, self.awaitingPong else { return }
            self.missedPongs += 1
            AppLog.d("No pong (\(self.missedPongs)/2) — keeping WS alive on first miss")
            self.awaitingPong = false
            if self.missedPongs >= 2 {
                self.missedPongs = 0
                self.handleDisconnect()
            }
        }
    }
}
// reset missedPongs = 0 in clearPongState() and wherever pong/initial_status arrives (:379, :502-508)
```

- [ ] **Step 3: Relax connect timeout 1s → 5s**

```swift
// SubworkerManager.swift:292 — change deadline .now() + 1.0 → .now() + 5.0
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

---

### Task 3: Icon reflects HTTP health (no false RED)

**Files:**
- Modify: `Sources/SubworkerManager.swift:570-582` (`handleDisconnect` keeps last-known data, marks `statusError` but does NOT wipe `subworkers`), `Sources/NotchIslandView.swift:47` + `EliaTopBarApp.swift` icon logic (degraded vs dead)

- [ ] **Step 1: handleDisconnect preserves data**

```swift
// REMOVE: subworkers = [] (if present); KEEP: subworkers as last-known
// SET: statusError = "WebSocket disconnected — HTTP polling active"
// HTTP polling (startHTTPPolling) already keeps /status fresh every 5s
```

- [ ] **Step 2: Amber degraded state**

```swift
// NotchIslandServerState: add var wsDegraded: Bool { !wsConnected && statusError == nil }
// View: red slash only when wsConnected==false AND last HTTP fetch failed (>15s stale);
// else amber dot = "live data via HTTP, WS reconnecting"
```

- [ ] **Step 3: Build + visual check**

Run: `swift build 2>&1 | tail -3 && ./build-app.sh v1.4.1 2>&1 | tail -3`
Expected: build OK; kill WS server 10s → icon goes amber (not red), agents data still browsable

---

### Task 4: Dual-server failover (`:5677` primary, `:5656` fallback)

**Files:**
- Modify: `Sources/SubworkerManager.swift:175-177, 259-269` (primary + fallback URLs, auto-switch)

- [ ] **Step 1: Store both URLs**

```swift
private var primaryBaseURL = UserDefaults.standard.string(forKey: "subworkerServerURL") ?? "http://localhost:5677"
private var fallbackBaseURL = "http://localhost:5656"
private var consecutiveFailures = 0
// on 3rd consecutive handleDisconnect with no pong ever → updateBaseURL(fallbackBaseURL) + log
// on fallback WS stable 5 min → optionally flip back (log only, no auto-flap)
```

- [ ] **Step 2: Manual switch command**

Run (user escape hatch, no rebuild): `defaults write com.elia.elia-topbar subworkerServerURL "http://localhost:5656" && pkill -x EliaTopBar; open /Applications/EliaTopBar.app`
Expected: immediate green on healthy `:5656` while OMP image is being fixed

---

### Task 5: Connection telemetry (prove the fix)

**Files:**
- Modify: `Sources/SubworkerManager.swift` logging lines only (`:284, :585, :602, :628`)

- [ ] **Step 1: Log port + latency on every transition**

```swift
AppLog.d("Connecting WS to \(wsURL)")            // already — keep
AppLog.d("Pong rtt=\(ms)ms missed=\(missedPongs)") // add on pong receipt
AppLog.d("WS failover primary=\(primary) fallback=\(fallback) failures=\(n)") // add on switch
```

- [ ] **Step 2: 24h soak check**

Run: `grep -c "Received pong" ~/Library/Logs/EliaTopBar/debug.log; grep -c "No pong within" ~/Library/Logs/EliaTopBar/debug.log`
Expected: pongs >> misses; `No pong` stops growing after Task 1 deploy

---

## Verification matrix

| Check | Command | Before (today) | After |
|---|---|---|---|
| OMP pong | WS probe `:5677` send `{"type":"ping"}` | TIMEOUT | `{"event":"pong"}` |
| Elia pong | WS probe `:5656` | pong OK | pong OK (unchanged) |
| Log flap | `grep -c "No pong within" debug.log` | 57, growing | frozen |
| RED rate | observe island 10 min | ~30–40% red | green, brief amber max |
| Failover | stop `:5677` container 60s | full RED, no data | amber, HTTP data + flip to `:5656` |

## Rollback

- Server: `cd /Users/vakandi/Documents/omp-server && git stash && docker compose build omp-server && docker compose up -d omp-server`
- Client: single-file revert `Sources/SubworkerManager.swift` (no migration, no config change); `defaults write com.elia.elia-topbar subworkerServerURL "http://localhost:5656"` returns to known-good server.
