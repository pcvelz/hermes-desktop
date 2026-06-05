//! Localhost HTTP control plane for Hermes Desktop.
//!
//! A thin synchronous HTTP front door (tiny_http on a dedicated thread) over the existing
//! `*_inner` engine functions, so external tools can drive a Hermes chat session
//! programmatically through the *exact* Desktop path (`send_session_message_inner` →
//! `hermes --resume <id> chat --quiet --query`). See `docs/CONTROL_API.md` for the contract.
//!
//! Security posture (non-negotiable):
//! - Binds `127.0.0.1` ONLY (never `0.0.0.0`).
//! - Bearer-token auth on every route except `GET /health`.
//! - Token + port written to `~/.hermes-desktop/control.json` (mode 0600).
//! - Honours `HERMES_DESKTOP_CONTROL_DISABLE=1` to skip starting entirely.
//! - Bind/start failure logs to stderr and returns — it must NEVER crash the app.

use std::path::PathBuf;

use serde::Deserialize;
use serde_json::json;
use tauri::{AppHandle, Emitter, Manager};
use tiny_http::{Header, Method, Request, Response, Server};

use crate::connection::list_connections_inner;
use crate::models::ConnectionProfile;
use crate::session::{chat_inner, list_sessions_inner, load_session_transcript_inner};
use crate::storage::{load_preferences, AppStorage};
use crate::terminal::{
    read_terminal_session_output_inner, run_terminal_command_inner, start_terminal_session_inner,
    write_terminal_session_inner, TerminalState,
};

/// Event the control server emits after starting a terminal session out-of-band, so the
/// GUI renders a visible tab for it (the frontend only auto-creates tabs for sessions it
/// started itself; without this it would receive output events for a tab it never made).
const TERMINAL_ATTACH_EVENT: &str = "terminal-session-attach";

const DEFAULT_PORT: u16 = 8765;
const PORT_SCAN_LIMIT: u16 = 10; // 8765..=8774

/// Spawn the control server on a dedicated thread. Never panics; logs and returns on failure.
pub fn spawn(app: AppHandle) {
    if std::env::var("HERMES_DESKTOP_CONTROL_DISABLE").as_deref() == Ok("1") {
        eprintln!("[control] disabled via HERMES_DESKTOP_CONTROL_DISABLE=1");
        return;
    }

    std::thread::Builder::new()
        .name("hermes-control-server".to_string())
        .spawn(move || run_server(app))
        .map(|_| ())
        .unwrap_or_else(|error| {
            eprintln!("[control] failed to spawn control server thread: {error}");
        });
}

fn run_server(app: AppHandle) {
    let (server, port) = match bind_server() {
        Some(bound) => bound,
        None => {
            eprintln!("[control] could not bind a localhost port in 8765..=8774; control API disabled");
            return;
        }
    };

    let token = uuid::Uuid::new_v4().simple().to_string();
    let pid = std::process::id();

    if let Err(error) = write_discovery_file(port, &token, pid) {
        eprintln!("[control] failed to write discovery file: {error}");
        // Without the discovery file clients can't learn the token; keep serving anyway
        // (operator can read it via stderr / env), but flag it loudly.
    }

    eprintln!("[control] listening on http://127.0.0.1:{port} (pid {pid})");

    for request in server.incoming_requests() {
        // Each request is handled inline (sync). Chat turns block; that is by design — the
        // control API is synchronous (see spec §6). One slow turn stalls the queue, which is
        // acceptable for this single-client test-harness use.
        if let Err(error) = handle_request(&app, &token, port, pid, request) {
            eprintln!("[control] request handling error: {error}");
        }
    }
}

fn bind_server() -> Option<(Server, u16)> {
    let base_port = std::env::var("HERMES_DESKTOP_CONTROL_PORT")
        .ok()
        .and_then(|value| value.trim().parse::<u16>().ok())
        .unwrap_or(DEFAULT_PORT);

    for offset in 0..PORT_SCAN_LIMIT {
        let port = match base_port.checked_add(offset) {
            Some(port) => port,
            None => break,
        };
        match Server::http(("127.0.0.1", port)) {
            Ok(server) => return Some((server, port)),
            Err(error) => {
                eprintln!("[control] port {port} unavailable: {error}");
            }
        }
    }
    None
}

fn discovery_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home)
        .join(".hermes-desktop")
        .join("control.json")
}

fn write_discovery_file(port: u16, token: &str, pid: u32) -> std::io::Result<()> {
    let path = discovery_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let body = json!({
        "port": port,
        "token": token,
        "pid": pid,
        "started_at": chrono::Utc::now().to_rfc3339(),
    });
    std::fs::write(&path, serde_json::to_vec_pretty(&body)?)?;
    set_owner_only_permissions(&path)?;
    Ok(())
}

#[cfg(unix)]
fn set_owner_only_permissions(path: &PathBuf) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

#[cfg(not(unix))]
fn set_owner_only_permissions(_path: &PathBuf) -> std::io::Result<()> {
    Ok(())
}

// --- request bodies -------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
struct MessageBody {
    prompt: String,
    #[serde(default)]
    auto_approve: bool,
}

#[derive(Debug, Deserialize)]
struct ChatBody {
    prompt: String,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    auto_approve: bool,
    #[serde(default)]
    hermes_home: Option<String>,
    #[serde(default)]
    profile: Option<String>,
}

/// `POST /terminal/run` — the API equivalent of opening a "New Shell" in the GUI
/// and running one shell command in it. Runs through the SAME local-shell engine
/// the in-app terminal uses (`run_terminal_command_inner` → `ssh::execute`, which
/// for `isLocal` profiles is `/bin/sh -c`), and returns stdout/stderr/exit_code
/// synchronously. One-shot: no persistent PTY/session state across calls.
#[derive(Debug, Deserialize)]
struct RunBody {
    command: String,
    #[serde(default)]
    hermes_home: Option<String>,
    #[serde(default)]
    profile: Option<String>,
}

/// `POST /terminal/session` — the API equivalent of clicking **New Shell** in the GUI.
/// Spawns a real interactive PTY session (`start_terminal_session_inner`) and emits
/// `terminal-session-attach` so the Desktop renders a visible tab for it. `initial_input`
/// is typed into the shell after it starts (e.g. `herm-claude "…"`); `startup_command`
/// is run as the shell's startup command line.
#[derive(Debug, Deserialize)]
struct SessionBody {
    #[serde(default)]
    startup_command: Option<String>,
    #[serde(default)]
    initial_input: Option<String>,
    #[serde(default)]
    hermes_home: Option<String>,
    #[serde(default)]
    profile: Option<String>,
    #[serde(default)]
    cols: Option<u16>,
    #[serde(default)]
    rows: Option<u16>,
}

/// `POST /terminal/session/{id}/write` — type input into a running interactive session
/// (the persistent PTY created by `POST /terminal/session`). Used to drive a *loaded*
/// interactive CLI: e.g. start `herm-claude` (interactive Claude/Opus), then write a
/// follow-up message to test the interaction. `enter` (default true) appends a newline
/// so the line is submitted.
#[derive(Debug, Deserialize)]
struct WriteBody {
    input: String,
    #[serde(default = "default_true")]
    enter: bool,
}

fn default_true() -> bool {
    true
}

// --- routing --------------------------------------------------------------------------------

fn handle_request(
    app: &AppHandle,
    token: &str,
    port: u16,
    pid: u32,
    request: Request,
) -> std::io::Result<()> {
    let method = request.method().clone();
    let url = request.url().to_string();
    let (path, query) = split_path_query(&url);
    let segments: Vec<String> = path
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    let segments: Vec<&str> = segments.iter().map(|s| s.as_str()).collect();

    // GET /health — no auth.
    if method == Method::Get && segments == ["health"] {
        let active = active_connection_id(app);
        let body = json!({
            "ok": true,
            "app": "hermes-desktop",
            "version": env!("CARGO_PKG_VERSION"),
            "active_connection_id": active,
            "control_pid": pid,
        });
        return respond_json(request, 200, &body);
    }

    // Everything else requires the bearer token.
    if !is_authorized(&request, token) {
        return respond_error(request, 401, "missing or invalid bearer token");
    }

    let _ = port; // reserved for future self-referential responses

    match (&method, segments.as_slice()) {
        (Method::Get, ["sessions"]) => handle_list_sessions(app, request, &query),
        (Method::Get, ["sessions", id, "transcript"]) => {
            let id = (*id).to_string();
            handle_transcript(app, request, &id)
        }
        (Method::Post, ["sessions", id, "message"]) => {
            let id = (*id).to_string();
            handle_message(app, request, &id)
        }
        (Method::Post, ["chat"]) => handle_chat(app, request),
        (Method::Post, ["terminal", "run"]) => handle_terminal_run(app, request),
        (Method::Post, ["terminal", "session"]) => handle_terminal_session(app, request),
        (Method::Post, ["terminal", "session", id, "write"]) => {
            let id = (*id).to_string();
            handle_terminal_write(app, request, &id)
        }
        (Method::Get, ["terminal", "session", id, "output"]) => {
            let id = (*id).to_string();
            handle_terminal_output(app, request, &id, &query)
        }
        _ => respond_error(request, 404, "not found"),
    }
}

/// `GET /terminal/session/{id}/output[?raw=1]` — read what a session is showing.
/// Returns the rolling stdout+stderr buffer so a client can OBSERVE the terminal over
/// HTTP (no screenshots). ANSI escape sequences are stripped by default for readability;
/// pass `?raw=1` to get the bytes verbatim.
fn handle_terminal_output(
    app: &AppHandle,
    request: Request,
    id: &str,
    query: &str,
) -> std::io::Result<()> {
    let terminal_state = app.state::<TerminalState>();
    match read_terminal_session_output_inner(&terminal_state, id) {
        Some(raw) => {
            let want_raw = query_param(query, "raw").as_deref() == Some("1");
            let output = if want_raw { raw } else { strip_ansi(&raw) };
            respond_json(
                request,
                200,
                &json!({ "session_id": id, "output": output }),
            )
        }
        None => respond_error(request, 404, "no such session (or no output captured yet)"),
    }
}

/// Strip ANSI/VT escape sequences and carriage returns so buffered TUI output reads as
/// plain text. Handles CSI (`ESC [ … letter`), OSC (`ESC ] … BEL/ST`), and lone two-char
/// escapes; leaves normal text intact.
fn strip_ansi(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == 0x1b {
            // ESC
            match bytes.get(i + 1) {
                Some(b'[') => {
                    i += 2;
                    while i < bytes.len() && !(0x40..=0x7e).contains(&bytes[i]) {
                        i += 1;
                    }
                    i += 1; // final byte
                }
                Some(b']') => {
                    i += 2;
                    while i < bytes.len() && bytes[i] != 0x07 {
                        if bytes[i] == 0x1b && bytes.get(i + 1) == Some(&b'\\') {
                            i += 1;
                            break;
                        }
                        i += 1;
                    }
                    i += 1;
                }
                _ => i += 2,
            }
        } else if b == b'\r' {
            i += 1;
        } else {
            // copy the raw byte (preserves multibyte UTF-8 sequences intact)
            out.push(b);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn handle_terminal_write(app: &AppHandle, mut request: Request, id: &str) -> std::io::Result<()> {
    let body: WriteBody = match read_json_body(&mut request) {
        Ok(body) => body,
        Err(message) => return respond_error(request, 400, &message),
    };
    let mut input = body.input;
    if body.enter {
        input.push('\n');
    }
    let terminal_state = app.state::<TerminalState>();
    match write_terminal_session_inner(&terminal_state, id.to_string(), input) {
        Ok(()) => respond_json(request, 200, &json!({ "ok": true, "session_id": id })),
        Err(error) => respond_error(request, 502, &error.to_string()),
    }
}

fn handle_terminal_session(app: &AppHandle, mut request: Request) -> std::io::Result<()> {
    let body: SessionBody = match read_json_body(&mut request) {
        Ok(body) => body,
        Err(message) => return respond_error(request, 400, &message),
    };

    let profile = match resolve_profile_with_overrides(app, body.hermes_home, body.profile) {
        Ok(profile) => profile,
        Err((status, message)) => return respond_error(request, status, &message),
    };

    let terminal_state = app.state::<TerminalState>();
    let result = start_terminal_session_inner(
        app.clone(),
        &terminal_state,
        profile,
        body.startup_command,
        body.initial_input,
        body.cols,
        body.rows,
    );
    match result {
        Ok(info) => {
            // Make the GUI render a visible tab for this out-of-band session.
            if let Err(error) = app.emit(TERMINAL_ATTACH_EVENT, &info) {
                eprintln!("[control] failed to emit {TERMINAL_ATTACH_EVENT}: {error}");
            }
            respond_json(request, 200, &info)
        }
        Err(error) => respond_error(request, 502, &error.to_string()),
    }
}

fn handle_terminal_run(app: &AppHandle, mut request: Request) -> std::io::Result<()> {
    let body: RunBody = match read_json_body(&mut request) {
        Ok(body) => body,
        Err(message) => return respond_error(request, 400, &message),
    };
    if body.command.trim().is_empty() {
        return respond_error(request, 400, "command is required");
    }

    let profile = match resolve_profile_with_overrides(app, body.hermes_home, body.profile) {
        Ok(profile) => profile,
        Err((status, message)) => return respond_error(request, status, &message),
    };

    let result = tauri::async_runtime::block_on(async {
        run_terminal_command_inner(profile, body.command).await
    });
    match result {
        Ok(outcome) => respond_json(request, 200, &outcome),
        Err(error) => respond_error(request, 502, &error.to_string()),
    }
}

fn handle_list_sessions(
    app: &AppHandle,
    request: Request,
    query: &str,
) -> std::io::Result<()> {
    let profile = match resolve_active_profile(app) {
        Ok(profile) => profile,
        Err((status, message)) => return respond_error(request, status, &message),
    };

    let limit = query_param(query, "limit")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(20);
    let offset = query_param(query, "offset")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    let search = query_param(query, "query").unwrap_or_default();

    let result = tauri::async_runtime::block_on(async {
        list_sessions_inner(profile, offset, limit, search).await
    });
    match result {
        Ok(page) => respond_json(request, 200, &page),
        Err(error) => respond_error(request, 500, &error.to_string()),
    }
}

fn handle_transcript(app: &AppHandle, request: Request, id: &str) -> std::io::Result<()> {
    let profile = match resolve_active_profile(app) {
        Ok(profile) => profile,
        Err((status, message)) => return respond_error(request, status, &message),
    };
    let id = id.to_string();
    let result = tauri::async_runtime::block_on(async {
        load_session_transcript_inner(profile, id).await
    });
    match result {
        Ok(messages) => respond_json(request, 200, &messages),
        Err(error) => respond_error(request, 500, &error.to_string()),
    }
}

fn handle_message(app: &AppHandle, mut request: Request, id: &str) -> std::io::Result<()> {
    let body: MessageBody = match read_json_body(&mut request) {
        Ok(body) => body,
        Err(message) => return respond_error(request, 400, &message),
    };
    if body.prompt.trim().is_empty() {
        return respond_error(request, 400, "prompt is required");
    }

    let profile = match resolve_active_profile(app) {
        Ok(profile) => profile,
        Err((status, message)) => return respond_error(request, status, &message),
    };

    let id = id.to_string();
    let result = tauri::async_runtime::block_on(async {
        chat_inner(profile, Some(id), body.prompt, body.auto_approve).await
    });
    match result {
        Ok(turn) => respond_json(request, 200, &turn),
        // Engine failure / approval-block / timeout — surface the message, do not swallow it.
        Err(error) => respond_error(request, 502, &error.to_string()),
    }
}

fn handle_chat(app: &AppHandle, mut request: Request) -> std::io::Result<()> {
    let body: ChatBody = match read_json_body(&mut request) {
        Ok(body) => body,
        Err(message) => return respond_error(request, 400, &message),
    };
    if body.prompt.trim().is_empty() {
        return respond_error(request, 400, "prompt is required");
    }

    let profile = match resolve_profile_with_overrides(app, body.hermes_home, body.profile) {
        Ok(profile) => profile,
        Err((status, message)) => return respond_error(request, status, &message),
    };

    let session_id = body
        .session_id
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    let result = tauri::async_runtime::block_on(async {
        chat_inner(profile, session_id, body.prompt, body.auto_approve).await
    });
    match result {
        Ok(turn) => respond_json(request, 200, &turn),
        Err(error) => respond_error(request, 502, &error.to_string()),
    }
}

// --- profile resolution (spec §4) -----------------------------------------------------------

fn active_connection_id(app: &AppHandle) -> Option<String> {
    let storage = app.state::<AppStorage>();
    load_preferences(&storage)
        .ok()
        .and_then(|prefs| prefs.active_connection_id)
}

fn resolve_active_profile(
    app: &AppHandle,
) -> std::result::Result<ConnectionProfile, (u16, String)> {
    let storage = app.state::<AppStorage>();
    let connections = list_connections_inner(&storage)
        .map_err(|error| (500u16, error.to_string()))?;
    let active_id = load_preferences(&storage)
        .map_err(|error| (500u16, error.to_string()))?
        .active_connection_id;

    if let Some(active_id) = active_id {
        if let Some(profile) = connections
            .iter()
            .find(|profile| profile.id.to_string() == active_id)
        {
            return Ok(profile.clone());
        }
    }

    // No active id resolvable but exactly one connection exists → use it.
    if connections.len() == 1 {
        return Ok(connections[0].clone());
    }

    Err((409u16, "no active connection".to_string()))
}

fn resolve_profile_with_overrides(
    app: &AppHandle,
    hermes_home: Option<String>,
    profile_name: Option<String>,
) -> std::result::Result<ConnectionProfile, (u16, String)> {
    let hermes_home = hermes_home
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let profile_name = profile_name
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());

    if hermes_home.is_none() && profile_name.is_none() {
        return resolve_active_profile(app);
    }

    let mut profile = ConnectionProfile::default();
    profile.is_local = true;
    profile.label = "control-override".to_string();
    if hermes_home.is_some() {
        profile.custom_hermes_home_path = hermes_home;
    } else {
        profile.hermes_profile = profile_name;
    }
    Ok(profile)
}

// --- HTTP helpers ---------------------------------------------------------------------------

fn is_authorized(request: &Request, token: &str) -> bool {
    let expected = format!("Bearer {token}");
    request.headers().iter().any(|header| {
        header.field.equiv("Authorization") && header.value.as_str() == expected
    })
}

fn read_json_body<T: for<'de> Deserialize<'de>>(request: &mut Request) -> Result<T, String> {
    let mut buffer = String::new();
    request
        .as_reader()
        .read_to_string(&mut buffer)
        .map_err(|error| format!("failed to read request body: {error}"))?;
    if buffer.trim().is_empty() {
        return Err("request body is required".to_string());
    }
    serde_json::from_str(&buffer).map_err(|error| format!("invalid JSON body: {error}"))
}

fn json_header() -> Header {
    Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..])
        .expect("static content-type header is valid")
}

fn respond_json<T: serde::Serialize>(
    request: Request,
    status: u16,
    body: &T,
) -> std::io::Result<()> {
    let payload = serde_json::to_string(body)
        .unwrap_or_else(|error| format!("{{\"error\":\"serialization failed: {error}\"}}"));
    let response = Response::from_string(payload)
        .with_status_code(status)
        .with_header(json_header());
    request.respond(response)
}

fn respond_error(request: Request, status: u16, message: &str) -> std::io::Result<()> {
    let body = json!({ "error": message });
    respond_json(request, status, &body)
}

fn split_path_query(url: &str) -> (String, String) {
    match url.split_once('?') {
        Some((path, query)) => (path.to_string(), query.to_string()),
        None => (url.to_string(), String::new()),
    }
}

fn query_param(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (name, value) = pair.split_once('=')?;
        if name == key {
            Some(percent_decode(value))
        } else {
            None
        }
    })
}

fn percent_decode(value: &str) -> String {
    let value = value.replace('+', " ");
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let decode = |b: u8| -> Option<u8> {
                match b {
                    b'0'..=b'9' => Some(b - b'0'),
                    b'a'..=b'f' => Some(b - b'a' + 10),
                    b'A'..=b'F' => Some(b - b'A' + 10),
                    _ => None,
                }
            };
            if let (Some(high), Some(low)) = (decode(bytes[index + 1]), decode(bytes[index + 2])) {
                out.push(high << 4 | low);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
