# Hermes Desktop Control API

A localhost-only HTTP control plane that lets external tools drive the Desktop
application programmatically — start chat sessions, read transcripts, run
terminal commands, and spawn/interact with PTY sessions.

---

## 1 Binding and discovery

The server binds `127.0.0.1` **only** (never `0.0.0.0`).
At startup it scans ports `8765..8774` for the first available one and writes:

```
~/.hermes-desktop/control.json  (mode 0600)
```

```json
{
  "port": 8765,
  "token": "<random 32-hex bearer token>",
  "pid": 12345,
  "started_at": "2025-01-01T12:00:00.000Z"
}
```

Set `HERMES_DESKTOP_CONTROL_DISABLE=1` to prevent the server from starting at all.
Set `HERMES_DESKTOP_CONTROL_PORT=<n>` to fix the starting port.

---

## 2 Authentication

Every request except `GET /health` requires:

```
Authorization: Bearer <token>
```

Missing or wrong token → **401**.

---

## 3 Routes

### GET /health
No auth required.

```json
{
  "ok": true,
  "app": "hermes-desktop",
  "version": "1.0.0",
  "active_connection_id": "uuid-or-null",
  "control_pid": 12345
}
```

---

### GET /sessions

Query params: `limit` (default 20), `offset` (default 0), `query` (search string).

Returns a `SessionListPage` (same schema as the GUI session browser).

---

### GET /sessions/{id}/transcript

Returns the message array for session `{id}`.

---

### POST /sessions/{id}/message

**Blocks** until the hermes chat turn completes.

```json
{ "prompt": "...", "auto_approve": false }
```

Response:

```json
{ "ok": true, "session_id": "...", "stdout": "...", "stderr": "..." }
```

Errors → **502** with `{ "error": "..." }`.

---

### POST /chat

Start or continue a chat session.

```json
{
  "prompt": "...",
  "session_id": null,
  "auto_approve": false,
  "hermes_home": null,
  "profile": null
}
```

- Omit `session_id` (or set to `null`) to start a new session.
- `hermes_home` / `profile` override the active connection (see §4).
- Builds `hermes [--profile P] [--resume <id>] [--yolo] chat --quiet --query <prompt>`.
- **Blocks** until the turn completes; returns the same shape as `/sessions/{id}/message`.

---

### POST /terminal/run

One-shot command execution through the local-shell engine.

```json
{ "command": "ls -la", "hermes_home": null, "profile": null }
```

Response:

```json
{ "ok": true, "exit_code": 0, "stdout": "...", "stderr": "..." }
```

---

### POST /terminal/session

Spawn a persistent interactive PTY session and emit an event so the Desktop
renders a visible terminal tab for it.

```json
{
  "startup_command": null,
  "initial_input": "herm-claude",
  "hermes_home": null,
  "profile": "coding",
  "cols": 220,
  "rows": 50
}
```

Response:

```json
{ "ok": true, "id": "<session-uuid>", "tab_id": "<tab-uuid>", "label": "My Host · coding" }
```

> Use `id` with the write/output endpoints.

---

### POST /terminal/session/{id}/write

Type input into a running PTY session.

```json
{ "input": "echo hello", "enter": true }
```

`enter` (default `true`) appends a newline so the line is submitted.

---

### GET /terminal/session/{id}/output

Read the rolling stdout+stderr buffer (≈ 256 KB, char-boundary-safe).

Query param: `raw=1` — return ANSI/VT bytes verbatim (default strips them).

```json
{ "session_id": "...", "output": "..." }
```

---

## 4 Profile resolution

When `hermes_home` and `profile` are both absent the server uses the active
connection (or the sole connection if none is marked active).  If neither
applies → **409**.

When either override is provided a synthetic `isLocal = true` profile is built
(same as the in-app "local" connection type) so hermes runs against an arbitrary
local Hermes home or profile name.

---

## 5 Error shape

All errors share a single JSON envelope:

```json
{ "error": "human-readable message" }
```

HTTP status codes mirror the Tauri original: 400, 401, 404, 409, 500, 502.

---

## 6 Synchronous contract

The chat routes (`POST /chat`, `POST /sessions/{id}/message`) are **synchronous
blocking** calls.  The server blocks the request until the hermes subprocess
exits.  This is intentional — the API is designed for single-client test harness
use (session-drive.py, /hermes-ask, /hermes-benchmark).

---

## 7 Implementation notes (Swift port)

- Transport: `Network.framework NWListener` on a background DispatchQueue.
- No third-party HTTP library.
- Profile/connection data accessed via `@MainActor` dispatch to the shared `ConnectionStore`.
- Chat turns run as `async` Swift Tasks via `SSHTransport.execute` (local mode = `/bin/sh -c`).
- Terminal sessions are created on the MainActor via `TerminalWorkspaceStore.addTab`.
- Output buffering for terminal sessions is in-memory (rolling 256 KB per session); the
  buffer is seeded at session creation and is not currently auto-populated from PTY output
  (TODO: wire a SwiftTerm data callback to `appendBuffer`).
