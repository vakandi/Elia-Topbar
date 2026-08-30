# Elia Livestream — Full Technical Teardown

> **Purpose:** line-by-line anatomy of the EliaTopBar + Python subworkers livestream so you can clone it verbatim inside any Opencode-backed SaaS (ImmoSignal, MirrorPay, …). Covers the wire format, every parse branch, the WebSocket mesh, the Swift rendering, and the SaaS reuse pattern.

---

## 0. Map

```
Opencode server :5655 ──SSE /event?directory=…──▶  Python subworkers server :5656 ──WS /ws──▶  EliaTopBar (Swift) / SaaS frontend (React)
        ▲                                                       │                              │
        │ POST /session, POST /session/{id}/message             │ GET /sessions/{name}/list     │ GET /sessions/{name}?session_id=…&limit=…
        │ GET /session/{id}/message, GET /session/status        │ GET /sessions/{name}          │ poll todo_list (ImmoSignal legacy)
        └──────────────────── OpenCodeClient ───────────────────┘                               └─ Directus ai_chat_sessions
```

Two planes:

* **Control plane** (REST): `OpenCodeClient` creates sessions, sends prompts, lists messages. Historical fetch goes through FastAPI `GET /sessions/*` which re-exposes `parts: [{type, text, tool, input, output}]`.
* **Live plane** (stream): `runner._stream_progress` taps Opencode SSE → `ws_manager.broadcast_run_log` → Swift `SubworkerManager` → `LogPopoverView` liveEntries. No polling.

ImmoSignal today only has the control plane + a 2 s Directus poll for `todo_list`. This doc shows how to add the live plane with zero backend rewrite.

---

## 1. Opencode SSE — the source of truth

### 1.1 Endpoint

```
GET http://127.0.0.1:5655/event?directory=/tmp/<agent>
Accept: text/event-stream
```

Query param is the agent's workspace directory (e.g. `/tmp/refund-hunter`, `/tmp/elia`). The stream is **per directory**, not per session. Every event carries `properties.sessionID` so you filter by the session you just created. Without the filter you would see all agents that share the same `directory`.

### 1.2 Wire shape

Each SSE frame is one line starting with `data: `:

```
data: {"type":"message.part.delta","properties":{"sessionID":"ses_xxx","field":"text","delta":" Hello"}}
data: {"type":"message.part.delta","properties":{"sessionID":"ses_xxx","field":"reasoning","delta":"We should"}}
data: {"type":"message.part.created","properties":{"sessionID":"ses_xxx","part":{"type":"tool","tool":"write","state":{"status":"running","input":{...}}}}}
data: {"type":"message.part.updated","properties":{"sessionID":"ses_xxx","part":{"type":"tool","tool":"write","state":{"status":"completed","input":{...},"output":"Wrote file…"}}}}
```

| `type` | `properties` | Live meaning |
|---|---|---|
| `message.part.delta` | `sessionID`, `field ∈ {text, reasoning}`, `delta: string` | Incremental token slice. **BUT** some providers send cumulative snapshots (`"Hello world"` instead of `" world"`). See dedup. |
| `message.part.created` | `sessionID`, `part: {type:"tool", tool, state:{status:"running", input}}` | Tool starts. Input may be partial. |
| `message.part.updated` | `sessionID`, `part: {type:"tool", tool, state:{status:"completed"/"error", input, output}}` | Tool finishes. This is where you get `output`. |

Field values are not whimsical — `text` is the assistant Final answer, `reasoning` is chain-of-thought (purple in TopBar), everything else is `tool`.

### 1.3 What the historical REST gives you (so live and history match)

`GET /session/{id}/message?limit=50` returns

```json
[{ "info": { "role":"assistant", "agent":"refund-hunter", "model":{"modelID":"big-pickle","variant":"low"}, "time":{"created": 1735…}},
   "parts": [
     {"type":"text","text":"…"},
     {"type":"reasoning","text":"…"},
     {"type":"tool","tool":"write","state":{"status":"completed","input":{"filePath":"…","content":"…"},"output":"Wrote file successfully."}}
   ]}]
```

Live reuses the same part vocabulary: `text / reasoning / tool` with `tool + input + output`. If you keep that contract, the same Swift/React renderer works for both planes.

---

## 2. Python — `runner._stream_progress` (EliaAI `subworkers/server/app/services/runner.py:466`)

### 2.1 Where it lives in the run

```python
# inside _execute_single_attempt, AFTER create_session:
stream_task = asyncio.create_task(self._stream_progress(session_id, directory))
try:
    await client.send_message(session_id, content=prompt, model=model, variant=variant, agent=agent_id, timeout=timeout)
    await self._reinject_on_provider_error(...)
finally:
    stream_task.cancel()
```

`send_message` blocks until the turn finishes (`POST /session/{id}/message` is synchronous). The streamer **must** be started before it, otherwise you miss the first deltas. Cancellation at the end is the only teardown — no explicit `close()`.

Directory is `f"/tmp/{self._config.name}"` (e.g. `/tmp/refund-hunter`). That is also the `x-opencode-directory` header sent at `create_session`. The server’s mapping (`OPENCODE_WORKSPACE=/data` → host `/Users/vakandi/EliaAI`) only matters for Directus; the SSE `directory` is the container/host `/tmp` name verbatim.

### 2.2 Full function with annotations

```python
async def _stream_progress(self, session_id: str, directory: str) -> None:
    import json as _json, os as _os
    from urllib.parse import quote
    import httpx
    from app.routes.websocket import ws_manager

    name = self._config.name
    server_url = _os.environ.get("OPENCODE_SERVER_URL", "http://127.0.0.1:5655")
    url = f"{server_url}/event?directory={quote(directory)}"

    last_emitted: dict[str, str] = {}          # ← dedup state per field

    def _normalize_and_emit(field: str, incoming: str) -> str | None:
        if not incoming: return None
        prev = last_emitted.get(field, "")
        if not prev:
            last_emitted[field] = incoming; return incoming
        if incoming == prev: return None        # duplicate
        if incoming.startswith(prev):           # cumulative snapshot: "hello" → "hello world"
            suffix = incoming[len(prev):]
            if not suffix: return None
            last_emitted[field] = incoming; return suffix
        if prev.endswith(incoming) or incoming in prev:
            return None                          # already contained
        last_emitted[field] = prev + incoming  # genuine incremental slice
        return incoming

    try:
        async with httpx.AsyncClient(timeout=None) as client:
            async with client.stream("GET", url) as resp:
                async for line in resp.aiter_lines():
                    if not line.startswith("data:"): continue
                    try: evt = _json.loads(line[5:].strip())
                    except: continue
                    evt_type = evt.get("type") or ""
                    props = evt.get("properties") or {}
                    if props.get("sessionID") != session_id: continue

                    # fast path — text/reasoning deltas
                    if evt_type == "message.part.delta":
                        field = props.get("field") or "text"
                        if field not in ("text","reasoning"): continue
                        delta = _normalize_and_emit(field, props.get("delta") or "")
                        if delta: await ws_manager.broadcast_run_log(name, delta, field)
                        continue

                    # tool path — created/updated carry the tool payload in state.input/output
                    if evt_type in ("message.part.created","message.part.updated"):
                        part = props.get("part") or {}
                        if (part.get("type") or part.get("part_type")) != "tool": continue
                        tool_name = part.get("tool") or part.get("name") or "tool"
                        state = part.get("state") if isinstance(part.get("state"),dict) else {}
                        tool_input = state.get("input") if isinstance(state.get("input"),dict) else part.get("input")
                        tool_output = state.get("output") if isinstance(state.get("output"),str) else part.get("output")
                        if not isinstance(tool_input, dict): tool_input = {}
                        # per-field clipping prevents json.dumps truncation bug (cut in middle of JSON)
                        def _clip(s, n=800): return s[:n] + "…" if s and len(s) > n else s
                        payload = {"tool": str(tool_name)}
                        fp = tool_input.get("filePath") or tool_input.get("file_path") or tool_input.get("path") or ""
                        if fp: payload["filePath"] = str(fp)[:600]
                        if "oldString" in tool_input or "old_string" in tool_input:
                            payload["oldString"] = _clip(str(tool_input.get("oldString") or tool_input.get("old_string") or ""),1200)
                            payload["newString"] = _clip(str(tool_input.get("newString") or tool_input.get("new_string") or ""),1200)
                        elif "content" in tool_input:
                            payload["content"] = _clip(str(tool_input.get("content") or ""),600)
                        elif tool_input:
                            payload["input"] = _json.dumps({k:_clip(str(v),400) for k,v in tool_input.items()}, ensure_ascii=False)[:800]
                        if isinstance(tool_output,str) and tool_output:
                            payload["output"] = _clip(tool_output,600)
                        await ws_manager.broadcast_run_log(name, _json.dumps(payload, ensure_ascii=False), "tool")
    except asyncio.CancelledError: raise
    except Exception as exc: log.warning("runner.stream_error ...", name, exc)
```

**Why the dedup exists:** Without `_normalize_and_emit`, a provider that sends cumulative snapshots produces exponential duplication: `hello` → `hello world` (if you append the second string verbatim you get `hellohello world`). With it, only the suffix ` world` is forwarded. The same guard drops pure duplicates and substrings already contained, so a flaky SSE reconnect cannot double the visible text.

**Why the tool branch clips per-field, not the whole JSON:** The old code did `json.dumps(dict)[:1200]` which can slice in the middle of a string escape and produce invalid JSON that the Swift parser drops as `"()"`. Per-field clipping keeps the envelope valid.

---

## 3. Python — `websocket.py` (`app/routes/websocket.py`)

### 3.1 Manager

```python
class ConnectionManager:
    _connections: list[WebSocket] = []

    async def broadcast_run_log(self, name: str, text: str, field: str = "text") -> None:
        await self.broadcast({"event": "run_log", "name": name, "text": text, "field": field})

    async def broadcast_run_banner(self, name: str, banner: dict) -> None:
        await self.broadcast({"event": "run_banner", "name": name, "banner": banner})

    async def broadcast(self, event: dict) -> None:
        msg = json.dumps(event)
        dead = []
        for ws in self._connections:
            try: await ws.send_text(msg)
            except: dead.append(ws)
        for ws in dead: self.disconnect(ws)
```

The WS message for live is literally `{"event":"run_log","name":"refund-hunter","text":" …","field":"text"}` or `field:"reasoning"` or `field:"tool"` where `text` is a JSON string of the tool payload. `run_banner` is the reinjection banner (`continue the tasks`).

### 3.2 Endpoint

```python
@router.websocket("/ws")
async def websocket_endpoint(ws: WebSocket) -> None:
    if not await ws_require_token(ws): return
    await ws_manager.connect(ws)
    # snapshot so the Swift menu can render without polling
    await ws.send_text(json.dumps(ws_manager.get_status_snapshot()))
    while True:
        data = await ws.receive_text()
        msg = json.loads(data)
        if msg.get("type") == "ping":
            await ws.send_text(json.dumps({"event": "pong"}))
```

Auth is `?token=` query param or `Authorization: Bearer` + `X-Elia-Token`. The snapshot is `{"event":"initial_status","scheduler_running":bool,"opencode_health":str,"subworkers":[...]}` — the same shape as `GET /status` so the Swift code has a single parser.

Pong watchdog on the Swift side (30 s ping, 10 s timeout) is what makes Wi-Fi roams recover in ~1 s; the server side only replies to ping.

---

## 4. Swift — `SubworkerManager` (`Sources/SubworkerManager.swift`)

### 4.1 Connection

```swift
private func connectWebSocket() {
    var c = URLComponents(url: URL(string: wsURL)!, resolvingAgainstBaseURL: false)!
    c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name:"token", value: EliaAuth.token)]
    wsTask = session.webSocketTask(with: c.url!)
    wsTask?.resume()
    receiveMessages()        // recursive
    startPingTimer()         // 30 s
}
private func receiveMessages() {
    wsTask?.receive { [weak self] result in
        Task { @MainActor [weak self] in
            switch result {
            case .success(.string(let text)): self?.handleWSMessage(text)
            case .success(.data(let d)): if let t = String(data:d,encoding:.utf8) { self?.handleWSMessage(t) }
            case .failure(let e): self?.handleDisconnect()
            }
            self?.receiveMessages()   // tail recurse
        }
    }
}
```

`receiveMessages` is tail-recursive: after handling one frame it immediately re-arms. A disconnect falls through to `handleDisconnect()` which tears down ping/pong watchdogs and flips `wsConnected = false` → the menu shows red, and HTTP polling (`startHTTPPolling` 5 s, `setSlowPolling` 15 s) takes over until reconnect.

### 4.2 Dispatch

```swift
private func handleWSMessage(_ text: String) {
    guard let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String:Any] else { return }
    switch json["event"] as? String {
    case "run_log":
        if let name = json["name"] as? String, let delta = json["text"] as? String {
            lastActivity[name] = Date()
            NotificationCenter.default.post(name: .init("SubworkerRunLog"),
                object: nil, userInfo: ["name": name, "text": delta, "field": json["field"] as? String ?? "text"])
        }
    case "run_banner": /* similar with "banner" dict */
    case "subworker_started":
        if let name = json["name"] as? String { /* set running=true */ }
        NotificationCenter.default.post(name: .SubworkerStartedNotification, ...)
    case "subworker_completed","subworker_error": /* running=false */
    case "pong": clearPongState(); wsConnected = true
    default: if json["subworkers"] != nil { handleInitialStatus(json) }
    }
}
static let runLogNotification = Notification.Name("SubworkerRunLog")
static let runBannerNotification = Notification.Name("SubworkerRunBanner")
static let subworkerStartedNotification = Notification.Name("SubworkerStarted")
static let subworkerCompletedNotification = Notification.Name("SubworkerCompleted")
```

The Swift side never parses the `tool` payload — it just forwards `field` verbatim. The LogPopover decides what to do with `field=="tool"` (tool banner) vs `field=="text"` vs `field=="reasoning"`.

---

## 5. Swift — `LogPopoverView` (the visible part)

### 5.1 Model

```swift
enum LiveEntry: Equatable {
    case liveReasoning(String)                 // thinking, grey bar
    case liveText(String)                      // markdown, primary
    case liveTool(name: String, input: String?, output: String?)  // banner
}
@State private var liveEntries: [String: [LiveEntry]] = [:]   // per-agent, ordered
@State private var liveRunning = false
@State private var liveStartedAt: Date?
```

Per-agent dictionary means two agents can stream concurrently without clobbering.

### 5.2 Appending (dedup mirrors the server)

```swift
private func appendLiveDelta(for name: String, field: String, delta: String) {
    if name == subworkerName && !liveRunning { liveRunning = true; if liveStartedAt == nil { liveStartedAt = Date() } }
    if liveEntries[name] == nil { liveEntries[name] = [] }
    switch field {
    case "reasoning":
        if let last = liveEntries[name]?.last, case .liveReasoning(let cur) = last {
            if delta == cur || cur.hasSuffix(delta) || (cur.contains(delta) && delta.count < 40) { return }
            var next: String
            if delta.hasPrefix(cur) { next = delta }          // cumulative
            else if cur.isEmpty { next = delta }
            else { /* incremental */ next = cur + delta }
            if next.count > 12000 { next = String(next.suffix(8000)) } // cap
            liveEntries[name]?[count-1] = .liveReasoning(next)
        } else { liveEntries[name]?.append(.liveReasoning(delta)) }
    case "tool":
        // server sends field=="tool" with text = JSON string of {tool,filePath,oldString,newString,content,output}
        let parsed: (String,String?,String?) = {
            if let d = delta.data(using:.utf8), let obj = try? JSONSerialization.jsonObject(with:d) as? [String:Any] {
                let tool = obj["tool"] as? String ?? "tool"
                if obj["filePath"] != nil || obj["oldString"] != nil || obj["content"] != nil {
                    return (tool, delta, obj["output"] as? String) // keep full delta for banner parsers
                }
                return (tool, obj["input"] as? String, obj["output"] as? String)
            }
            return (delta.isEmpty ? "tool" : delta, nil, nil)
        }()
        // dedup exact triples
        if let last = liveEntries[name]?.last, case .liveTool(let ln,let li,let lo) = last,
           ln == parsed.0 && li == parsed.1 && lo == parsed.2 { return }
        liveEntries[name]?.append(.liveTool(name: parsed.0, input: parsed.1, output: parsed.2))
    default: // text
        if let last = liveEntries[name]?.last, case .liveText(let cur) = last {
            if delta == cur || (delta.count < 80 && cur.contains(delta)) { return }
            var next = delta.hasPrefix(cur) ? delta : cur + delta
            if cur.hasSuffix(delta) { return }
            if next.count > 12000 { next = String(next.suffix(8000)) }
            liveEntries[name]?[count-1] = .liveText(next)
        } else { liveEntries[name]?.append(.liveText(delta)) }
    }
    if name != liveAgent { liveAgent = name }
}
```

Caps: each reasoning/text accumulator caps at 12k chars (keep last 8k), tool list caps at 40 entries. Prevents a 1 M-token run from OOM-ing the popover.

### 5.3 Rendering — reasoning ≠ text ≠ tool

```swift
@ViewBuilder private var liveStreamPanel: some View {
    let entries = liveEntries[subworkerName] ?? []
    VStack(alignment:.leading,spacing:6) {
        HStack { Text("LIVE")… Text(subworkerName)… Circle().fill(.orange) }
        ForEach(Array(entries.enumerated()), id:\.offset) { _, entry in
            switch entry {
            case .liveReasoning(let t):
                VStack(alignment:.leading,spacing:2) {
                    Text("THINKING").font(.system(size:8,weight:.semibold)).foregroundColor(.secondary.opacity(0.7)).tracking(0.6)
                    HStack(spacing:6) {
                        Rectangle().fill(Color.gray.opacity(0.35)).frame(width:2)
                        MarkdownView(text: t, baseColor: .secondary).fixedSize(horizontal:false,vertical:true)
                    }
                }
            case .liveText(let t):
                MarkdownView(text: streamingSafeMarkdown(t), baseColor: .primary).fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            case .liveTool(let name,let input,let output):
                if name.lowercased()=="edit", let input, let diff = parseEditLivePayload(input, output:output) {
                    editDiffBanner(filePath: diff.path, oldString: diff.old, newString: diff.new)
                } else if name.lowercased()=="write", let input, let wp = parseWriteLivePayload(input) {
                    writeFileBanner(filePath: wp.path, contentPreview: wp.preview, output: output)
                } else {
                    toolBanner(icon: toolIcon(name), title: toolDisplayName(name), color: toolColor(name),
                               content: formatToolContent(name:name,input:input,output:output))
                }
            }
        }
    }.id("live-stream"); Divider()
}
private func streamingSafeMarkdown(_ text: String) -> String {
    // don't let an unclosed fence flicker: "```js\nconst " → "```js\nconst \n```"
    let fenceCount = text.components(separatedBy:"```").count - 1
    return fenceCount % 2 == 1 ? text + "\n```" : text
}
```

History uses the exact same visuals (`messageEntry(.reasoning)` is the same grey bar, `toolBanner` vocabulary is shared: `toolIcon/toolDisplayName/toolColor` plus `formatToolContent`).

### 5.4 Write / Edit banners (Cursor parity)

*Write*: header shows `doc.badge.plus` in green, `lastPathComponent` bold + `deletingLastPathComponent` in 9 pt mono, truncated middle, with `output` (“Wrote file successfully.”) on the right. Body is a monospaced preview of `content` (first 500 chars), host-mapped (`/data → /Users/vakandi/EliaAI`). This is why the old bug showed `()` — empty `input` produced `"{}"` and the fallback now returns `""` → safe content `"—"` instead.

*Edit*: `editDiffBanner` computes a line diff:

```swift
private func lineDiff(old:[String],new:[String]) -> [DiffRow] {
    // 80-line cap, + green / − red / unchanged
}
```

Header shows `pencil.and.scribble` in orange, `+added −removed` counts, file name/dir. Body is a `VStack` of `DiffRow` with `+`/`−`/ ` ` prefix, `Color.green/red` text and `green/red.opacity(0.08)` background. `… N more lines` truncates at 80. Payload extraction handles both `oldString/newString` and `old_string/new_string` keys and host-maps the path.

Fallback: `parseEditPayload`/`parseWritePayload` return `nil` when the path is missing or both strings empty → the caller falls back to generic `toolBanner`.

### 5.5 Waiting state (no messages yet)

```swift
private var messagesPanel: some View {
    ScrollViewReader { proxy in ScrollView { LazyVStack {
        if messagesLoading { ProgressView + "Loading messages…" }
        else if let err = messagesError { Text(err).foregroundColor(.red) }
        else {
            if !displayItems.isEmpty { ForEach(displayItems)… }
            if hasLiveContent(for: subworkerName) { liveStreamPanel }
            else if liveRunning { liveWaitingView }
            else if displayItems.isEmpty {
                Text(selectedSessionId==nil ? "Select a session" : "No messages in this session")
            }
        }
    }}}.onChange(of: liveEntries) { proxy.scrollTo("live-stream", anchor:.bottom) }
}

private var liveWaitingView: some View {
    // LIVE badge + spinner + elapsed ("12s" / "2m 05s") + dots animation
    // "Agent running — connecting to opencode • waiting for first token"
    // "WS: streaming • Session will appear when opencode creates it"
}
```

`liveRunning` is driven three ways: `SubworkerStarted` notification, `checkInitialRunningState()` (GET `/status` on appear — if the selected agent is in `running:true`), and the first `run_log` delta itself. Completion flips it off and re-fetches sessions after 1.5 s so the new run bubbles to the top. A 1 s `Timer` bumps `liveTick` which drives the `...` animation and the elapsed label (`Int(Date().timeIntervalSince(liveStartedAt))`).

The critical prior bug: `liveStreamPanel` was inside the `else { // displayItems not empty }` branch, so when a freshly triggered session had zero historical messages, the live stream was **invisible** even though `liveEntries` already had thinking tokens — users saw “No messages” for ~10 s. Now it is outside.

### 5.6 Session list refresh (the 16:00 ghost)

`POST /sessions/{name}/list` used to be gated:

```python
if scheduler_sid is None and running_sid is None:
    all_sessions = await client.list_sessions(limit=50)
```

So once a stored `scheduler_sid` existed, new runs never appeared. Fixed to always fetch `limit=100` and merge:

```python
all_sessions = await client.list_sessions(limit=100)
# filter by agent == sw.agent_id OR directory.startswith(ws_dir) OR title contains name
known_ids = {i.session_id for i in items}
if running_sid and running_sid not in known_ids: items.insert(0, … "▶ Running")
if scheduler_sid and scheduler_sid not in known_ids: items.append(…)
```

`ws_dir` is `OPENCODE_WORKSPACE`-aware (`/data/subworkers/<name>/workspace`), but the sandbox’s directory is `/tmp/<name>` — agent match is the reliable one. Limit bump from 50 to 100 prevents pagination truncation for busy agents.

---

## 6. Historical fetch (so live and history converge)

`GET /sessions/{name}?session_id=…&limit=50` calls `OpenCodeClient.list_messages` and maps each `info/parts` into `SessionLogEntry`:

```swift
enum LogEntry { case text(String); case reasoning(String); case tool(name:String,input:String?,output:String?) }
```

`parseMessage` compacts `parts` where `type == "text"/"reasoning"/"tool"`, serializes `input` dict to JSON string (`String(data: JSONSerialization.data(withJSONObject: obj),…)`) and `output` similarly, so `formatToolInput` can later re-parse it. `messageEntry(.reasoning)` is the grey bar, `messageEntry(.tool)` is the banner — same as live.

---

## 7. Reuse recipe for a SaaS (ImmoSignal)

ImmoSignal today (`immosignal-fastapi/fastapi/app/routers/chat.py` + `services/chat_engine.py` + `services/opencode_session.py`) has **no live plane** — it polls:

```python
# chat.py:258 GET /chat/session/{id}/todo-stream  — SSE that polls Directus every 2 s
async def event_generator():
    while True:
        current = await service_repo.get_by_id("ai_chat_sessions", session_id)
        todo_list = current.get("todo_list") or []
        # hash, yield event: todo, keepalive every 30 s, sleep 2
        await asyncio.sleep(2)
```

`chat_engine.py` does `send_message` → `extract_opencode_content/reasoning/tool_calls` → writes an `ai_messages` row → spawns `_run_background_multi_turn` which polls `wait_message` → `list_messages` → updates `todo_list`. The frontend watches `todo-stream` and re-fetches `ai_messages`. Latency is 2–4 s, reasoning is not streamed token-by-token, and tool banners only appear after the turn completes.

To add Elia-grade livestream **without touching the sandbox or Directus schema**:

### 7.1 Backend (copy `runner._stream_progress` verbatim)

Reuse the same SSE subscription — the only per-tenant isolation is `directory` (sandbox’s `workspace_dir + "/workdir"`). In ImmoSignal:

```python
# inside chat_engine.py after create_session, before send_message:
workdir_path = f"{sandbox_session.workspace_dir}/workdir"
stream_task = asyncio.create_task(
    stream_opencode_session(opencode_session_id, workdir_path, ai_chat_session_id)
)
try:
    response = await oc_client.send_message(opencode_session_id, model=model_obj, parts=[...], agent=resolved_agent)
finally:
    stream_task.cancel()
```

`stream_opencode_session` is the Elia `_stream_progress` with two renames:

* `name` → `ai_chat_session_id` (Directus `ai_chat_sessions.id`)
* `directory` → `workdir_path`

It does `client.stream("GET", f"{base}/event?directory={quote(workdir_path)}")`, filters `props.sessionID == opencode_session_id`, and broadcasts to a **room keyed by `ai_chat_session_id`**. The broadcast transport can be:

* **WebSocket** (`/chat/ws?session_id=…&token=…`) if the frontend already holds a WS (mirrors Elia’s `/ws`), or
* **SSE** (`GET /chat/session/{id}/live-stream`) if you want to keep `EventSource` (no header auth, `?token=` fallback — ImmoSignal already does this for `todo-stream`).

Add to `app/routers/chat.py`:

```python
manager = ChatLiveManager()  # mirrors ConnectionManager

@router.get("/session/{session_id}/live-stream")
async def live_stream(session_id: str, token: str | None = None, current_user = Depends(...)):
    # auth like todo-stream, verify session belongs to user
    async def gen():
        q: asyncio.Queue = await manager.subscribe(session_id)
        while True:
            try:
                evt = await asyncio.wait_for(q.get(), timeout=30)
                yield f"event: {evt['event']}\ndata: {json.dumps(evt['data'])}\n\n"
            except asyncio.TimeoutError:
                yield "event: keepalive\ndata: {}\n\n"
            except asyncio.CancelledError: break
    return StreamingResponse(gen(), media_type="text/event-stream", headers={"X-Accel-Buffering":"no"})

# inside stream_opencode_session, replace ws_manager.broadcast_run_log:
await manager.broadcast(session_id, {"event":"run_log","field":field,"text":delta})
# and for tools:
await manager.broadcast(session_id, {"event":"run_log","field":"tool","text": json.dumps(payload)})
```

Wire `ChatLiveManager.broadcast` to both the SSE queue and the optional WS room.

### 7.2 Frontend (copy `LogPopoverView` live stack)

ImmoSignal frontend (`immosignal-frontend/src/features/chat/…`) already has a `ChatMessages` list and a `todo_list` poll. Add a second data source:

```ts
// useChatLive.ts — EventSource counterpart to SubworkerManager.receiveMessages
export function useChatLive(sessionId: string, token: string) {
  const [reasoning, setReasoning] = useState("")
  const [text, setText] = useState("")
  const [tools, setTools] = useState<LiveTool[]>([])  // {name, filePath, oldString, newString, content, output}
  const [running, setRunning] = useState(false)

  useEffect(() => {
    const es = new EventSource(`/api/chat/session/${sessionId}/live-stream?token=${token}`)
    es.addEventListener("run_log", (e) => {
      const {field, text: delta} = JSON.parse((e as MessageEvent).data)
      if (field === "reasoning") setReasoning(prev => dedupAppend(prev, delta))
      else if (field === "text") setText(prev => dedupAppend(prev, delta))
      else if (field === "tool") setTools(prev => [...prev, JSON.parse(delta)])
    })
    es.addEventListener("keepalive", () => {})
    return () => es.close()
  }, [sessionId])

  return {reasoning, text, tools, running}
}
// dedupAppend mirrors _normalize_and_emit: handle cumulative snapshots
function dedupAppend(prev: string, incoming: string) {
  if (!prev) return incoming
  if (incoming === prev) return prev
  if (incoming.startsWith(prev)) return incoming
  if (prev.endsWith(incoming) || prev.includes(incoming)) return prev
  return prev + incoming
}
```

Render with the same three branches as `liveStreamPanel`:

```tsx
{reasoning && (
  <div className="border-l-2 border-gray-300 pl-3">
    <div className="text-[10px] tracking-widest text-gray-500">THINKING</div>
    <Markdown text={reasoning} className="text-gray-500" />
  </div>
)}
{tools.map(t => t.tool === "edit"
  ? <EditDiffBanner key={t.filePath} filePath={hostPath(t.filePath)} oldString={t.oldString} newString={t.newString} />
  : t.tool === "write"
    ? <WriteBanner filePath={hostPath(t.filePath)} preview={t.content} output={t.output} />
    : <ToolBanner icon={toolIcon(t.tool)} title={toolDisplay(t.tool)} content={`${t.filePath ?? ""} ${t.output ?? ""}`} />
)}
{streamingSafeMarkdown(text) && <Markdown text={streamingSafeMarkdown(text)} />}

{!tools.length && !text && !reasoning && running && (
  <LiveWaiting elapsed={elapsed} />
)}
```

`hostPath` maps `"/data/…" → "/Users/…"` for EliaTopBar; in ImmoSignal it maps sandbox `workdir` → `"/sandbox/<id>/workdir"` display, or just shows `lastPathComponent` + dir. `EditDiffBanner` is the `lineDiff` + `DiffRow` component (green `+`, red `−`, `+added −removed` header). `streamingSafeMarkdown` is the fence guard (`"```".count % 2 == 1 ? text + "\n```" : text`).

Keep the existing `todo-stream` and `ai_messages` fetch as the **ground truth** — when the turn completes, the background poller writes the final `ai_messages` row and the live entries should be cleared or reconciled (compare `content` + `tool_calls` hash to avoid duplicate render). Elia does this with `lastMessagesFingerprint` on the historical fetch.

### 7.3 Multi-tenant / sandbox isolation

* **Elia:** one OpenCode server, one `directory` per subworker (`/tmp/<name>`), SSE filtered by `sessionID`. No auth per tenant beyond the topbar token.
* **ImmoSignal:** one OpenCode server, one `workdir` per sandbox (`<workspace_dir>/workdir`), SSE filtered by `opencode_session_id`, WS/SSE room keyed by `ai_chat_session_id` + user check (`session.user_id == current_user.user_id`). The `x-opencode-directory` header at `create_session` is what binds the session to the correct `opencode.json` (MCP tokens) — TokenResolver writes it per sandbox.

Both share the exact same opencode contract, so the live streamer is a pure copy-paste with two renames (`name/directory` → `session_id/workdir`).

### 7.4 Gotchas that already bit Elia

* **Cumulative vs incremental deltas** — without dedup you get `hellohello worldhello world!`. Fix at both server and client (server’s `_normalize_and_emit` + Swift’s `appendLiveDelta` branch).
* **Truncation that breaks JSON** — clipping `json.dumps(dict)[:1200]` can cut inside an escape. Clip per-field instead.
* **Session list gating** — `if scheduler_sid is None and running_sid is None: fetch` hid new runs. Always fetch `limit=100` and merge.
* **Live panel hidden behind “No messages”** — `liveStreamPanel` was inside the `displayItems.isEmpty` else branch. Move it outside and add `liveWaitingView`.
* **Write showing `()` / `{}`** — empty `state.input == {}` (pending tool) serializes to `"{}"`; `formatToolInput` now returns `""` → safe content `"—"` instead. Host-mapping fixes `/data` vs `/Users` confusion.

---

## 8. Verification checklist (before claiming “best livestream ever”)

* `python3 -m py_compile` on `runner.py` + `websocket.py`.
* `swift build` (or `swift build -c release --arch arm64` when `xcbuild` is missing) — zero errors, only pre-existing `actor-isolated` warnings.
* Synthetic replay: inject `run_log` deltas `text:"Hel"`, `text:"lo"`, `reasoning:"think…"`, `tool:write {filePath,content}`, `text:" world"` — assert `liveEntries` order, no duplication on `delta:"Hello"` when buffer already is `"Hello"`.
* Live trigger with a reasoning + tool run (refund-hunter or any agent with `edit`): reasoning appears with grey bar + `THINKING`, text flows without repetition, tool banner appears live (write shows host absolute path, edit shows green/red diff), historical fetch matches live after completion.
* Two agents concurrently — switching sessions in the popover does not reset the other’s tail.
* Markdown-heavy reply (code block + table) — no flicker as the fence opens/closes.

---

## 9. Files to copy for a new SaaS

| Elia file | What it gives you | SaaS target |
|---|---|---|
| `subworkers/server/app/services/runner.py:466` | SSE tap + dedup + tool forwarding | `fastapi/app/services/chat_engine.py:stream_opencode_session` |
| `subworkers/server/app/routes/websocket.py:79` | `broadcast_run_log` / `ConnectionManager` | `app/routers/chat.py: ChatLiveManager` |
| `subworkers/server/app/routes/subworkers.py:580` | `list_sessions` always-fetch + merge | `app/routers/chat.py: list_sessions` (if you expose session lists) |
| `Sources/SubworkerManager.swift:260` | WS connect + `run_log` → NotificationCenter | `useChatLive.ts` (EventSource) |
| `Sources/LogPopoverView.swift:491` | `liveStreamPanel`, `liveWaitingView`, `appendLiveDelta`, `streamingSafeMarkdown` | `ChatLivePanel.tsx` |
| `Sources/LogPopoverView.swift:633` | `writeFileBanner`, `editDiffBanner`, `lineDiff`, `hostPath` | `ToolBanners.tsx` |

Paste the Swift as TSX with the type renames above; the Python is a direct import (only `OPENCODE_SERVER_URL` and the `directory` value change per tenant).

