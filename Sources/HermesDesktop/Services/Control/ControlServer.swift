/// Localhost HTTP control plane for Hermes Desktop (Swift port of the Tauri `control_server.rs`).
///
/// A minimal HTTP server bound to 127.0.0.1 ONLY, implemented directly on top of
/// Apple's Network.framework NWListener — no third-party HTTP dependencies.
///
/// Security posture (must stay non-negotiable):
/// - Binds 127.0.0.1 ONLY (never 0.0.0.0).
/// - Random bearer token; written to ~/.hermes-desktop/control.json at mode 0600.
/// - Every route except GET /health requires the bearer token (else 401).
/// - Honours HERMES_DESKTOP_CONTROL_DISABLE=1 to skip starting entirely.
/// - Bind / start failures log to stderr and return — NEVER crash the app.
///
/// Wire contract: exact parity with the original Tauri implementation so existing
/// clients (herm-desktop.sh, session-drive.py, /hermes-ask, /hermes-benchmark) work unchanged.

import Foundation
import Network
import AppKit

// MARK: - Constants

private let defaultPort: UInt16 = 8765
private let portScanLimit: UInt16 = 10 // 8765..8774

// Rolling output buffer cap per terminal session (≈ 256 KB).
private let terminalBufferLimit = 256 * 1024

// MARK: - Public entry point

/// Spawn the control server on a background serial queue.  Never throws; logs on failure.
func spawnControlServer(connectionStore: ConnectionStore, sshTransport: SSHTransport, terminalWorkspace: TerminalWorkspaceStore) {
    guard ProcessInfo.processInfo.environment["HERMES_DESKTOP_CONTROL_DISABLE"] != "1" else {
        fputs("[control] disabled via HERMES_DESKTOP_CONTROL_DISABLE=1\n", stderr)
        return
    }

    let server = ControlServer(
        connectionStore: connectionStore,
        sshTransport: sshTransport,
        terminalWorkspace: terminalWorkspace
    )

    let queue = DispatchQueue(label: "hermes-control-server", qos: .utility)
    queue.async {
        server.run()
    }
}

// MARK: - Server

private final class ControlServer: @unchecked Sendable {
    // Shared stores (all @MainActor; accessed only via MainActor-dispatched closures)
    private let connectionStore: ConnectionStore
    private let sshTransport: SSHTransport
    private let terminalWorkspace: TerminalWorkspaceStore
    private let sessionBrowserService: SessionBrowserService

    // Auth token and metadata
    private let token: String
    private let pid: Int32

    // Terminal output buffers keyed by session UUID string
    private let bufferLock = NSLock()
    private var terminalBuffers: [String: String] = [:]

    init(connectionStore: ConnectionStore, sshTransport: SSHTransport, terminalWorkspace: TerminalWorkspaceStore) {
        self.connectionStore = connectionStore
        self.sshTransport = sshTransport
        self.terminalWorkspace = terminalWorkspace
        self.sessionBrowserService = SessionBrowserService(sshTransport: sshTransport)
        self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.pid = Int32(ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - Lifecycle

    func run() {
        guard let (listener, port) = openListener() else {
            fputs("[control] could not bind a localhost port in 8765..8774; control API disabled\n", stderr)
            return
        }

        do {
            try writeDiscoveryFile(port: port)
        } catch {
            fputs("[control] failed to write discovery file: \(error)\n", stderr)
        }

        fputs("[control] listening on http://127.0.0.1:\(port) (pid \(pid))\n", stderr)

        let runSemaphore = DispatchSemaphore(value: 0)

        listener.stateUpdateHandler = { (state: NWListener.State) in
            switch state {
            case .failed(let error):
                fputs("[control] listener failed after bind: \(error)\n", stderr)
                runSemaphore.signal()
            case .cancelled:
                runSemaphore.signal()
            default:
                break
            }
        }

        runSemaphore.wait()
    }

    /// Probe each candidate port by creating an NWListener, wiring both handlers, starting it,
    /// and waiting up to 2 s for its state to resolve.  Returns the first listener that reaches
    /// .ready together with its actual bound port — the listener is fully operational at that
    /// point (newConnectionHandler already installed).  A .failed or .cancelled state means the
    /// port is unavailable; cancel that listener and advance to the next candidate.
    private func openListener() -> (NWListener, UInt16)? {
        let envPort = ProcessInfo.processInfo.environment["HERMES_DESKTOP_CONTROL_PORT"]
            .flatMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let base = envPort ?? defaultPort
        let scanCount: UInt16 = envPort != nil ? 1 : portScanLimit

        for offset in UInt16(0)..<scanCount {
            let candidate = base &+ offset
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: candidate)!
            )

            guard let listener = try? NWListener(using: params) else {
                fputs("[control] port \(candidate) could not construct NWListener\n", stderr)
                continue
            }

            let bindSemaphore = DispatchSemaphore(value: 0)
            let bindResult = Locked(false)

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    bindResult.set(true)
                    bindSemaphore.signal()
                case .failed, .cancelled:
                    bindSemaphore.signal()
                default:
                    break
                }
            }

            listener.start(queue: DispatchQueue(label: "hermes-control-listener", qos: .utility))

            let timedOut = bindSemaphore.wait(timeout: .now() + 2.0) == .timedOut
            if timedOut {
                fputs("[control] port \(candidate) probe timed out\n", stderr)
                listener.cancel()
                continue
            }

            if bindResult.get() {
                return (listener, candidate)
            }

            fputs("[control] port \(candidate) unavailable (NWListener not ready)\n", stderr)
            listener.cancel()
        }
        return nil
    }

    private func writeDiscoveryFile(port: UInt16) throws {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".hermes-desktop")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("control.json")
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "port": Int(port),
            "token": token,
            "pid": Int(pid),
            "started_at": iso8601.string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600 as Int16)],
            ofItemAtPath: path.path
        )
    }

    // MARK: - Connection accept / HTTP parse / dispatch

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "hermes-control-conn", qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                fputs("[control] receive error: \(error)\n", stderr)
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let raw = String(decoding: data, as: UTF8.self)
            self.dispatch(rawHTTP: raw, over: connection)
        }
    }

    private func dispatch(rawHTTP: String, over connection: NWConnection) {
        let (method, path, headers, body) = parseHTTP(rawHTTP)
        let (urlPath, query) = splitPathQuery(path)
        let segments = urlPath.split(separator: "/").filter { !$0.isEmpty }.map(String.init)

        // GET /health — no auth.
        if method == "GET" && segments == ["health"] {
            // Need MainActor to read connectionStore.lastConnectionID.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let activeID = self.connectionStore.lastConnectionID?.uuidString
                let body = self.jsonObject([
                    "ok": true,
                    "app": "hermes-desktop",
                    "version": appVersion(),
                    "active_connection_id": activeID as Any,
                    "control_pid": Int(self.pid)
                ])
                self.respond(over: connection, status: 200, json: body)
            }
            return
        }

        guard isAuthorized(headers: headers) else {
            respond(over: connection, status: 401, error: "missing or invalid bearer token")
            return
        }

        switch (method, segments) {
        case ("GET", ["sessions"]):
            Task { @MainActor [weak self] in await self?.handleListSessions(query: query, connection: connection) }

        case ("GET", let s) where s.count == 3 && s[0] == "sessions" && s[2] == "transcript":
            Task { @MainActor [weak self] in await self?.handleTranscript(sessionID: s[1], connection: connection) }

        case ("POST", let s) where s.count == 3 && s[0] == "sessions" && s[2] == "message":
            Task { @MainActor [weak self] in await self?.handleMessage(sessionID: s[1], body: body, connection: connection) }

        case ("POST", ["chat"]):
            Task { @MainActor [weak self] in await self?.handleChat(body: body, connection: connection) }

        case ("POST", ["terminal", "run"]):
            Task { @MainActor [weak self] in await self?.handleTerminalRun(body: body, connection: connection) }

        case ("POST", ["terminal", "session"]):
            Task { @MainActor [weak self] in await self?.handleTerminalSession(body: body, connection: connection) }

        case ("POST", let s) where s.count == 4 && s[0] == "terminal" && s[1] == "session" && s[3] == "write":
            Task { @MainActor [weak self] in await self?.handleTerminalWrite(sessionID: s[2], body: body, connection: connection) }

        case ("GET", let s) where s.count == 4 && s[0] == "terminal" && s[1] == "session" && s[3] == "output":
            handleTerminalOutput(sessionID: s[2], query: query, connection: connection)

        case ("GET", ["workflows"]):
            Task { @MainActor [weak self] in self?.handleListWorkflows(connection: connection) }

        case ("POST", let s) where s.count == 3 && s[0] == "workflows" && s[2] == "launch":
            Task { @MainActor [weak self] in self?.handleLaunchWorkflow(workflowID: s[1], connection: connection) }

        default:
            respond(over: connection, status: 404, error: "not found")
        }
    }

    // MARK: - Route handlers (all @MainActor so they can read connection stores directly)

    @MainActor
    private func handleListSessions(query: String, connection: NWConnection) async {
        let limit  = queryParam(query, key: "limit").flatMap(Int.init) ?? 20
        let offset = queryParam(query, key: "offset").flatMap(Int.init) ?? 0
        let search = queryParam(query, key: "query") ?? ""

        let profile: ConnectionProfile
        do {
            profile = try resolveActiveProfile()
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        let svc = sessionBrowserService
        do {
            let page = try await svc.listSessions(connection: profile, offset: offset, limit: limit, query: search)
            let encoder = controlEncoder()
            if let data = try? encoder.encode(page), let text = String(data: data, encoding: .utf8) {
                self.respondRaw(over: connection, status: 200, body: text)
            } else {
                self.respond(over: connection, status: 500, error: "serialization failed")
            }
        } catch {
            self.respond(over: connection, status: 500, error: error.localizedDescription)
        }
    }

    @MainActor
    private func handleTranscript(sessionID: String, connection: NWConnection) async {
        let profile: ConnectionProfile
        do {
            profile = try resolveActiveProfile()
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        let svc = sessionBrowserService
        do {
            let messages = try await svc.loadTranscript(connection: profile, sessionID: sessionID)
            let encoder = controlEncoder()
            if let data = try? encoder.encode(messages), let text = String(data: data, encoding: .utf8) {
                self.respondRaw(over: connection, status: 200, body: text)
            } else {
                self.respond(over: connection, status: 500, error: "serialization failed")
            }
        } catch {
            self.respond(over: connection, status: 500, error: error.localizedDescription)
        }
    }

    @MainActor
    private func handleMessage(sessionID: String, body: String, connection: NWConnection) async {
        guard let req = parseJSONBody(body, as: MessageBody.self) else {
            respond(over: connection, status: 400, error: "invalid JSON body or missing prompt")
            return
        }
        guard !req.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            respond(over: connection, status: 400, error: "prompt is required")
            return
        }

        let profile: ConnectionProfile
        do {
            profile = try resolveActiveProfile()
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        do {
            let result = try await runHermesChat(
                profile: profile, sessionID: sessionID, prompt: req.prompt, autoApprove: req.autoApprove
            )
            self.respond(over: connection, status: 200, json: result)
        } catch {
            self.respond(over: connection, status: 502, error: error.localizedDescription)
        }
    }

    @MainActor
    private func handleChat(body: String, connection: NWConnection) async {
        guard let req = parseJSONBody(body, as: ChatBody.self) else {
            respond(over: connection, status: 400, error: "invalid JSON body or missing prompt")
            return
        }
        guard !req.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            respond(over: connection, status: 400, error: "prompt is required")
            return
        }

        let profile: ConnectionProfile
        do {
            profile = try resolveProfileWithOverrides(hermesHome: req.hermesHome, profileName: req.profile)
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        let sessionID = req.sessionID.flatMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }

        do {
            let result = try await runHermesChat(
                profile: profile, sessionID: sessionID, prompt: req.prompt, autoApprove: req.autoApprove
            )
            self.respond(over: connection, status: 200, json: result)
        } catch {
            self.respond(over: connection, status: 502, error: error.localizedDescription)
        }
    }

    @MainActor
    private func handleTerminalRun(body: String, connection: NWConnection) async {
        guard let req = parseJSONBody(body, as: RunBody.self) else {
            respond(over: connection, status: 400, error: "invalid JSON body or missing command")
            return
        }
        guard !req.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            respond(over: connection, status: 400, error: "command is required")
            return
        }

        let profile: ConnectionProfile
        do {
            profile = try resolveProfileWithOverrides(hermesHome: req.hermesHome, profileName: req.profile)
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        do {
            let result = try await sshTransport.execute(
                on: profile, remoteCommand: req.command, standardInput: nil, allocateTTY: false
            )
            let obj = jsonObject([
                "ok": result.exitCode == 0,
                "exit_code": Int(result.exitCode),
                "stdout": result.stdout,
                "stderr": result.stderr
            ])
            self.respond(over: connection, status: 200, json: obj)
        } catch {
            self.respond(over: connection, status: 502, error: error.localizedDescription)
        }
    }

    @MainActor
    private func handleTerminalSession(body: String, connection: NWConnection) async {
        guard let req = parseJSONBody(body, as: SessionBody.self) else {
            respond(over: connection, status: 400, error: "invalid JSON body")
            return
        }

        let profile: ConnectionProfile
        do {
            profile = try resolveProfileWithOverrides(hermesHome: req.hermesHome, profileName: req.profile)
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        let tab = terminalWorkspace.addTab(
            for: profile,
            startupCommandLine: req.startupCommand,
            startupInput: req.initialInput
        )

        let sessionID = tab.id.uuidString

        // Emit a notification so the SwiftUI layer renders a visible tab for
        // this out-of-band session (mirrors Tauri's `terminal-session-attach` event).
        NotificationCenter.default.post(
            name: .controlTerminalSessionAttach,
            object: nil,
            userInfo: ["session_id": sessionID, "tab_id": tab.id.uuidString]
        )

        // Seed an empty buffer so the session is discoverable by the output endpoint.
        appendBuffer(sessionID: sessionID, text: "")

        // Bridge PTY output → rolling buffer.  The closure captures `sessionID` and
        // `self` weakly; it is called on the main queue by LocalProcess's dispatch path.
        tab.session.installOutputCapture { [weak self] slice in
            guard let self else { return }
            let text = String(bytes: slice, encoding: .utf8)
                ?? String(slice.map { Character(UnicodeScalar($0)) })
            self.appendBuffer(sessionID: sessionID, text: text)
        }

        if let cols = req.cols, let rows = req.rows {
            tab.session.resize(cols: Int(cols), rows: Int(rows))
        }

        // Start the PTY process immediately without waiting for the SwiftUI layer to
        // render a visible tab.  The callback above must be installed first so no early
        // output is lost.
        tab.session.startHeadless()

        let obj = jsonObject([
            "ok": true,
            "id": sessionID,
            "tab_id": tab.id.uuidString,
            "label": tab.title
        ])
        self.respond(over: connection, status: 200, json: obj)
    }

    @MainActor
    private func handleTerminalWrite(sessionID: String, body: String, connection: NWConnection) async {
        guard let req = parseJSONBody(body, as: WriteBody.self) else {
            respond(over: connection, status: 400, error: "invalid JSON body")
            return
        }

        guard hasBuffer(sessionID: sessionID) else {
            respond(over: connection, status: 404, error: "no such session")
            return
        }

        let input = req.enter ? (req.input + "\n") : req.input

        if let tabID = UUID(uuidString: sessionID),
           let tab = terminalWorkspace.tabs.first(where: { $0.id == tabID }) {
            tab.session.sendInput(input)
            self.respond(over: connection, status: 200, json: jsonObject(["ok": true, "session_id": sessionID]))
        } else {
            self.respond(over: connection, status: 404, error: "no such terminal session")
        }
    }

    /// GET /terminal/session/{id}/output[?raw=1]
    /// Pure read; no MainActor required — buffer access is protected by a lock.
    private func handleTerminalOutput(sessionID: String, query: String, connection: NWConnection) {
        let wantRaw = queryParam(query, key: "raw") == "1"

        if let raw = readBuffer(sessionID: sessionID) {
            let output = wantRaw ? raw : stripANSI(raw)
            respond(over: connection, status: 200, json: jsonObject(["session_id": sessionID, "output": output]))
        } else {
            respond(over: connection, status: 404, error: "no such session (or no output captured yet)")
        }
    }

    // MARK: - Workflows

    /// GET /workflows — list saved workflows for the active connection/profile.
    /// Workflows are stored locally per workspace scope (host + Hermes home), so the
    /// returned set matches the GUI Workflows tab for the active connection.
    @MainActor
    private func handleListWorkflows(connection: NWConnection) {
        let profile: ConnectionProfile
        do {
            profile = try resolveActiveProfile()
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        let workflows = connectionStore.workflows(for: profile.workspaceScopeFingerprint)
        let items: [[String: Any]] = workflows.map { workflow in
            [
                "id": workflow.id.uuidString,
                "name": workflow.name,
                "prompt": workflow.prompt,
                "skills": workflow.assignedSkills.map { skill -> [String: Any] in
                    [
                        "relative_path": skill.relativePath,
                        "slug": skill.slug,
                        "name": skill.resolvedName
                    ]
                }
            ]
        }

        self.respond(over: connection, status: 200, json: jsonObject([
            "ok": true,
            "workspace_scope": profile.workspaceScopeFingerprint,
            "workflows": items
        ]))
    }

    /// POST /workflows/{id}/launch — launch a saved workflow into a headless control
    /// terminal session (reuses the /terminal/session machinery) and return the session id.
    /// The workflow's prompt seeds the session as initial input; assigned skills are
    /// preloaded via the Hermes CLI `--skills` flags built by WorkflowLaunchInvocation.
    @MainActor
    private func handleLaunchWorkflow(workflowID: String, connection: NWConnection) {
        let profile: ConnectionProfile
        do {
            profile = try resolveActiveProfile()
        } catch {
            self.respond(over: connection, status: controlStatus(error), error: error.localizedDescription)
            return
        }

        guard let uuid = UUID(uuidString: workflowID) else {
            respond(over: connection, status: 400, error: "invalid workflow id")
            return
        }

        let workflows = connectionStore.workflows(for: profile.workspaceScopeFingerprint)
        guard let workflow = workflows.first(where: { $0.id == uuid }) else {
            respond(over: connection, status: 404, error: "no such workflow for the active connection")
            return
        }

        let invocation = WorkflowLaunchInvocation(workflow: workflow, connection: profile)

        let tab = terminalWorkspace.addTab(
            for: profile.updated(),
            startupCommandLine: invocation.startupCommandLine,
            startupInput: invocation.initialInput
        )

        let sessionID = tab.id.uuidString

        // Emit a notification so the SwiftUI layer renders a visible tab (mirrors /terminal/session).
        NotificationCenter.default.post(
            name: .controlTerminalSessionAttach,
            object: nil,
            userInfo: ["session_id": sessionID, "tab_id": tab.id.uuidString]
        )

        // Seed an empty buffer so the session is discoverable by the output endpoint.
        appendBuffer(sessionID: sessionID, text: "")

        tab.session.installOutputCapture { [weak self] slice in
            guard let self else { return }
            let text = String(bytes: slice, encoding: .utf8)
                ?? String(slice.map { Character(UnicodeScalar($0)) })
            self.appendBuffer(sessionID: sessionID, text: text)
        }

        tab.session.startHeadless()

        self.respond(over: connection, status: 200, json: jsonObject([
            "ok": true,
            "id": sessionID,
            "tab_id": tab.id.uuidString,
            "label": tab.title,
            "workflow_id": workflow.id.uuidString,
            "workflow_name": workflow.name,
            "command_line": invocation.startupCommandLine
        ]))
    }

    // MARK: - hermes CLI execution (blocking chat turn)

    @MainActor
    private func runHermesChat(
        profile: ConnectionProfile,
        sessionID: String?,
        prompt: String,
        autoApprove: Bool
    ) async throws -> [String: Any] {
        var args: [String] = []
        if let profileName = profile.cliHermesProfileName {
            args += ["--profile", profileName]
        }
        if let sessionID {
            args += ["--resume", sessionID]
        }
        if autoApprove {
            args.append("--yolo")
        }
        args += ["chat", "--quiet", "--query", prompt]

        let commandLine = profile.remoteHermesCommandLine(arguments: args)
        let result = try await sshTransport.execute(
            on: profile,
            remoteCommand: commandLine,
            standardInput: nil,
            allocateTTY: false
        )

        if result.exitCode != 0 {
            let msg = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "hermes exited with code \(result.exitCode)"
            throw ControlError(status: 502, message: msg)
        }

        // Hermes writes "session_id: <id>" to stderr.
        let detectedSessionID: String? = result.stderr
            .components(separatedBy: .newlines)
            .reversed()
            .compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                for prefix in ["session_id:", "session:"] {
                    if t.hasPrefix(prefix) {
                        let v = String(t.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        return v.isEmpty ? nil : v
                    }
                }
                return nil
            }
            .first ?? sessionID

        return [
            "ok": true,
            "session_id": detectedSessionID as Any,
            "stdout": result.stdout,
            "stderr": result.stderr
        ]
    }

    // MARK: - Profile resolution (mirrors Tauri resolve_active_profile / resolve_profile_with_overrides)

    @MainActor
    private func resolveActiveProfile() throws -> ConnectionProfile {
        let connections = connectionStore.connections
        let lastID = connectionStore.lastConnectionID

        if let lastID, let profile = connections.first(where: { $0.id == lastID }) {
            return profile
        }
        if connections.count == 1 {
            return connections[0]
        }
        throw ControlError(status: 409, message: "no active connection")
    }

    @MainActor
    private func resolveProfileWithOverrides(hermesHome: String?, profileName: String?) throws -> ConnectionProfile {
        let th = hermesHome.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let tp = profileName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }

        if th == nil && tp == nil {
            return try resolveActiveProfile()
        }

        var profile = ConnectionProfile()
        profile.isLocal = true
        profile.label = "control-override"
        if let th {
            profile.customHermesHomePath = th
        } else {
            profile.hermesProfile = tp
        }
        return profile
    }

    // MARK: - Terminal output buffer (thread-safe)

    func appendBuffer(sessionID: String, text: String) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        var buf = terminalBuffers[sessionID, default: ""]
        buf.append(text)
        if buf.count > terminalBufferLimit {
            let drop = buf.count - terminalBufferLimit
            let startIndex = buf.index(buf.startIndex, offsetBy: drop, limitedBy: buf.endIndex) ?? buf.endIndex
            buf = String(buf[startIndex...])
        }
        terminalBuffers[sessionID] = buf
    }

    private func readBuffer(sessionID: String) -> String? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return terminalBuffers[sessionID]
    }

    private func hasBuffer(sessionID: String) -> Bool {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return terminalBuffers[sessionID] != nil
    }

    // MARK: - Auth

    private func isAuthorized(headers: [String: String]) -> Bool {
        headers["authorization"] == "Bearer \(token)"
    }

    // MARK: - HTTP helpers

    private func parseHTTP(_ raw: String) -> (method: String, path: String, headers: [String: String], body: String) {
        var lines = raw.components(separatedBy: "\r\n")
        if lines.count < 2 {
            lines = raw.components(separatedBy: "\n")
        }

        var method = "GET"
        var path = "/"
        if let requestLine = lines.first {
            let parts = requestLine.split(separator: " ", maxSplits: 2)
            if parts.count >= 2 {
                method = String(parts[0]).uppercased()
                path = String(parts[1])
            }
        }

        var headers: [String: String] = [:]
        var bodyStart = 1
        for (index, line) in lines.dropFirst().enumerated() {
            if line.isEmpty {
                bodyStart = index + 2
                break
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).lowercased().trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let body = lines.dropFirst(bodyStart).joined(separator: "\r\n")
        return (method, path, headers, body)
    }

    private func respond(over connection: NWConnection, status: Int, json: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            respondRaw(over: connection, status: status, body: String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            respondRaw(over: connection, status: 500, body: "{\"error\":\"serialization failed\"}")
        }
    }

    private func respond(over connection: NWConnection, status: Int, error message: String) {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        respondRaw(over: connection, status: status, body: "{\"error\":\"\(escaped)\"}")
    }

    private func respondRaw(over connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 404: statusText = "Not Found"
        case 409: statusText = "Conflict"
        case 500: statusText = "Internal Server Error"
        case 502: statusText = "Bad Gateway"
        default:  statusText = "Status \(status)"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var out = header.data(using: .utf8) ?? Data()
        out.append(bodyData)

        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Utilities

    private func splitPathQuery(_ url: String) -> (path: String, query: String) {
        if let q = url.firstIndex(of: "?") {
            return (String(url[..<q]), String(url[url.index(after: q)...]))
        }
        return (url, "")
    }

    private func queryParam(_ query: String, key: String) -> String? {
        query.components(separatedBy: "&").compactMap { pair -> String? in
            let kv = pair.components(separatedBy: "=")
            guard kv.count >= 2, kv[0] == key else { return nil }
            return percentDecode(kv[1...].joined(separator: "="))
        }.first
    }

    private func percentDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
    }

    private func parseJSONBody<T: Decodable>(_ body: String, as type: T.Type) -> T? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let data = t.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func jsonObject(_ dict: [String: Any]) -> [String: Any] { dict }

    private func controlEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .secondsSince1970
        return enc
    }

    private func controlStatus(_ error: Error) -> Int {
        (error as? ControlError)?.status ?? 500
    }
}

// MARK: - ANSI / VT stripping

private func stripANSI(_ text: String) -> String {
    let esc = "\u{001B}"
    let bel = "\u{0007}"
    var result = text
    result = result.replacingOccurrences(
        of: "\(esc)\\][^\(bel)\(esc)]*(?:\(bel)|\(esc)\\\\)",
        with: "", options: .regularExpression
    )
    result = result.replacingOccurrences(
        of: "\(esc)\\[[0-?]*[ -/]*[@-~]",
        with: "", options: .regularExpression
    )
    return result
}

// MARK: - App version

private func appVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
}

// MARK: - Request body types

private struct MessageBody: Decodable {
    let prompt: String
    let autoApprove: Bool
    enum CodingKeys: String, CodingKey { case prompt; case autoApprove = "auto_approve" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
    }
}

private struct ChatBody: Decodable {
    let prompt: String
    let sessionID: String?
    let autoApprove: Bool
    let hermesHome: String?
    let profile: String?
    enum CodingKeys: String, CodingKey {
        case prompt; case sessionID = "session_id"; case autoApprove = "auto_approve"
        case hermesHome = "hermes_home"; case profile
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prompt = try c.decode(String.self, forKey: .prompt)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
        hermesHome = try c.decodeIfPresent(String.self, forKey: .hermesHome)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
    }
}

private struct RunBody: Decodable {
    let command: String
    let hermesHome: String?
    let profile: String?
    enum CodingKeys: String, CodingKey { case command; case hermesHome = "hermes_home"; case profile }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        command = try c.decode(String.self, forKey: .command)
        hermesHome = try c.decodeIfPresent(String.self, forKey: .hermesHome)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
    }
}

private struct SessionBody: Decodable {
    let startupCommand: String?
    let initialInput: String?
    let hermesHome: String?
    let profile: String?
    let cols: UInt16?
    let rows: UInt16?
    enum CodingKeys: String, CodingKey {
        case startupCommand = "startup_command"; case initialInput = "initial_input"
        case hermesHome = "hermes_home"; case profile; case cols; case rows
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startupCommand = try c.decodeIfPresent(String.self, forKey: .startupCommand)
        initialInput = try c.decodeIfPresent(String.self, forKey: .initialInput)
        hermesHome = try c.decodeIfPresent(String.self, forKey: .hermesHome)
        profile = try c.decodeIfPresent(String.self, forKey: .profile)
        cols = try c.decodeIfPresent(UInt16.self, forKey: .cols)
        rows = try c.decodeIfPresent(UInt16.self, forKey: .rows)
    }
}

private struct WriteBody: Decodable {
    let input: String
    let enter: Bool
    enum CodingKeys: String, CodingKey { case input; case enter }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(String.self, forKey: .input) ?? ""
        enter = try c.decodeIfPresent(Bool.self, forKey: .enter) ?? true
    }
}

// MARK: - Thread-safe boolean box

private final class Locked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ initial: T) { value = initial }

    func set(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

// MARK: - Error type

private struct ControlError: Error, LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Notification name

extension Notification.Name {
    static let controlTerminalSessionAttach = Notification.Name("HermesControlTerminalSessionAttach")
}
