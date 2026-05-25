import Foundation

final class HermesAPIChatService: @unchecked Sendable {
    private let sshTransport: SSHTransport

    init(sshTransport: SSHTransport) {
        self.sshTransport = sshTransport
    }

    func probe(
        connection: ConnectionProfile,
        apiKey: String?
    ) async -> HermesChatBootstrapStatus {
        var status = HermesChatBootstrapStatus(apiServerPort: connection.resolvedAPIServerPort)

        do {
            var response = try await request(
                connection: connection,
                apiKey: apiKey,
                path: "/v1/capabilities",
                method: "GET",
                body: nil,
                timeoutSeconds: 10
            )

            if shouldBootstrapGateway(after: response) {
                let bootstrap = try await bootstrapGateway(connection: connection, apiKey: apiKey)
                status.sshConnected = true
                status.pythonAvailable = true
                status.hermesCLIAvailable = bootstrap.hermesCLIAvailable

                if !bootstrap.ok {
                    status.fallbackReason = bootstrap.error ?? "Hermes chat API is not available on this host yet."
                    return status
                }

                response = try await request(
                    connection: connection,
                    apiKey: apiKey,
                    path: "/v1/capabilities",
                    method: "GET",
                    body: nil,
                    timeoutSeconds: 10
                )
            }

            status.sshConnected = true
            status.pythonAvailable = true
            status.hermesCLIAvailable = true
            status.apiServerAvailable = response.ok
            status.apiAuthenticated = response.ok
            status.apiModel = response.payload?.objectValue.flatMap { value(in: $0, keys: ["model"]) }
            status.canUseNativeChat = response.ok

            if response.ok {
                status.hermesVersion = status.apiModel
                return status
            }

            status.fallbackReason = response.error ?? "Hermes chat API is not reachable on port \(connection.resolvedAPIServerPort)."
            if response.statusCode == 401 || response.statusCode == 403 {
                status.apiAuthenticated = false
                status.fallbackReason = "Hermes chat API rejected the API key. Update the connection's API Key."
            }
            return status
        } catch {
            status.fallbackReason = error.localizedDescription
            return status
        }
    }

    func createResponse(
        connection: ConnectionProfile,
        apiKey: String?,
        input: JSONValue,
        conversationID: String,
        previousResponseID: String?
    ) async throws -> HermesAPIResponse {
        let body = responseBody(input: input, conversationID: conversationID, previousResponseID: previousResponseID)

        let response = try await request(
            connection: connection,
            apiKey: apiKey,
            path: "/v1/responses",
            method: "POST",
            body: .object(body),
            timeoutSeconds: 180
        )

        guard response.ok, let payload = response.payload else {
            throw HermesAPIChatServiceError.remote(
                statusCode: response.statusCode,
                message: response.error ?? "Hermes chat API returned an empty response."
            )
        }

        return HermesAPIResponse(payload: payload)
    }

    func createResponseStream(
        connection: ConnectionProfile,
        apiKey: String?,
        input: JSONValue,
        conversationID: String,
        previousResponseID: String?,
        onEvent: @escaping @Sendable (HermesAPIStreamEvent) async -> Void
    ) async throws -> HermesAPIResponse? {
        var body = responseBody(input: input, conversationID: conversationID, previousResponseID: previousResponseID)
        body["stream"] = .bool(true)

        try await streamRequest(
            connection: connection,
            apiKey: apiKey,
            path: "/v1/responses",
            method: "POST",
            body: .object(body),
            timeoutSeconds: 180,
            headers: nil,
            onEvent: onEvent
        )
        return nil
    }

    func createChatCompletionStream(
        connection: ConnectionProfile,
        apiKey: String?,
        message: String,
        sessionID: String,
        onEvent: @escaping @Sendable (HermesAPIStreamEvent) async -> Void
    ) async throws {
        let body: [String: JSONValue] = [
            "model": .string("hermes-agent"),
            "stream": .bool(true),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string(message)
                ])
            ])
        ]

        try await streamRequest(
            connection: connection,
            apiKey: apiKey,
            path: "/v1/chat/completions",
            method: "POST",
            body: .object(body),
            timeoutSeconds: 180,
            headers: ["X-Hermes-Session-Id": sessionID],
            onEvent: onEvent
        )
    }

    func createChatCompletion(
        connection: ConnectionProfile,
        apiKey: String?,
        message: String,
        sessionID: String
    ) async throws -> HermesAPIChatCompletionResponse {
        let body: [String: JSONValue] = [
            "model": .string("hermes-agent"),
            "stream": .bool(false),
            "messages": .array([
                .object([
                    "role": .string("user"),
                    "content": .string(message)
                ])
            ])
        ]

        let response = try await request(
            connection: connection,
            apiKey: apiKey,
            path: "/v1/chat/completions",
            method: "POST",
            body: .object(body),
            timeoutSeconds: 180,
            headers: ["X-Hermes-Session-Id": sessionID]
        )

        guard response.ok, let payload = response.payload else {
            throw HermesAPIChatServiceError.remote(
                statusCode: response.statusCode,
                message: response.error ?? "Hermes chat API returned an empty response."
            )
        }

        return HermesAPIChatCompletionResponse(
            payload: payload,
            headers: response.headers ?? [:]
        )
    }

    private func responseBody(
        input: JSONValue,
        conversationID: String,
        previousResponseID: String?
    ) -> [String: JSONValue] {
        var body: [String: JSONValue] = [
            "model": .string("hermes-agent"),
            "input": input,
            "store": .bool(true)
        ]
        if let previousResponseID, !previousResponseID.isEmpty {
            body["previous_response_id"] = .string(previousResponseID)
        } else {
            body["conversation"] = .string(conversationID)
        }
        return body
    }

    private func request(
        connection: ConnectionProfile,
        apiKey: String?,
        path: String,
        method: String,
        body: JSONValue?,
        timeoutSeconds: Int,
        headers: [String: String]? = nil
    ) async throws -> HermesAPIServiceEnvelope {
        let request = HermesAPIRequest(
            port: connection.resolvedAPIServerPort,
            apiKey: normalizedAPIKey(apiKey),
            path: path,
            method: method,
            body: body,
            timeoutSeconds: timeoutSeconds,
            headers: headers
        )
        let script = try RemotePythonScript.wrap(request, body: apiRequestScript)
        return try await sshTransport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: HermesAPIServiceEnvelope.self
        )
    }

    private func streamRequest(
        connection: ConnectionProfile,
        apiKey: String?,
        path: String,
        method: String,
        body: JSONValue?,
        timeoutSeconds: Int,
        headers: [String: String]?,
        onEvent: @escaping @Sendable (HermesAPIStreamEvent) async -> Void
    ) async throws {
        let request = HermesAPIRequest(
            port: connection.resolvedAPIServerPort,
            apiKey: normalizedAPIKey(apiKey),
            path: path,
            method: method,
            body: body,
            timeoutSeconds: timeoutSeconds,
            headers: {
                var merged = headers ?? [:]
                merged["Accept"] = "text/event-stream"
                return merged
            }()
        )
        let script = try RemotePythonScript.wrap(request, body: apiStreamRequestScript)
        try await sshTransport.executeJSONLines(
            on: connection,
            pythonScript: script,
            responseType: HermesAPIStreamEnvelope.self
        ) { envelope in
            guard envelope.ok else {
                throw HermesAPIChatServiceError.remote(
                    statusCode: envelope.statusCode,
                    message: envelope.error ?? "Hermes chat API stream failed."
                )
            }
            guard let payload = envelope.payload else { return }
            await onEvent(HermesAPIStreamEvent(type: envelope.event ?? payload.objectValue.flatMap { self.value(in: $0, keys: ["type"]) } ?? "data", payload: payload))
        }
    }

    private func bootstrapGateway(
        connection: ConnectionProfile,
        apiKey: String?
    ) async throws -> HermesAPIBootstrapEnvelope {
        let request = HermesAPIBootstrapRequest(
            port: connection.resolvedAPIServerPort,
            apiKey: normalizedAPIKey(apiKey)
        )
        let script = try RemotePythonScript.wrap(request, body: apiBootstrapScript)
        return try await sshTransport.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: HermesAPIBootstrapEnvelope.self
        )
    }

    private func shouldBootstrapGateway(after response: HermesAPIServiceEnvelope) -> Bool {
        guard !response.ok else { return false }
        guard response.statusCode == nil else { return false }
        let error = response.error?.lowercased() ?? ""
        return error.contains("connection refused")
            || error.contains("errno 111")
            || error.contains("actively refused")
            || error.contains("connection reset")
    }

    private var apiRequestScript: String {
        """
        import http.client
        import traceback
        import urllib.parse

        request = payload

        def api_headers():
            headers = {
                "Accept": "application/json",
                "Content-Type": "application/json",
            }
            api_key = normalize_text(request.get("api_key"))
            if api_key:
                headers["Authorization"] = "Bearer " + api_key
            return headers

        try:
            body_value = request.get("body")
            body_data = None
            if body_value is not None:
                body_data = json.dumps(body_value, ensure_ascii=False).encode("utf-8")

            connection = http.client.HTTPConnection(
                "127.0.0.1",
                int(request.get("port") or 8642),
                timeout=int(request.get("timeout_seconds") or 30),
            )
            headers = api_headers()
            extra_headers = request.get("headers") or {}
            if isinstance(extra_headers, dict):
                for key, value in extra_headers.items():
                    key_text = normalize_text(key)
                    value_text = normalize_text(value)
                    if key_text and value_text:
                        headers[key_text] = value_text

            connection.request(
                request.get("method") or "GET",
                request.get("path") or "/v1/health",
                body=body_data,
                headers=headers,
            )
            response = connection.getresponse()
            response_body = response.read().decode("utf-8", errors="replace")
            connection.close()

            parsed = None
            if response_body.strip():
                try:
                    parsed = json.loads(response_body)
                except Exception:
                    parsed = None

            ok = 200 <= response.status < 300
            error = None
            if not ok:
                if isinstance(parsed, dict):
                    raw_error = parsed.get("error")
                    if isinstance(raw_error, dict):
                        error = raw_error.get("message") or json.dumps(raw_error, ensure_ascii=False)
                    else:
                        error = stringify(raw_error)
                if not error:
                    error = response_body.strip() or response.reason

            print(json.dumps({
                "ok": ok,
                "status_code": response.status,
                "payload": parsed,
                "raw_body": response_body if parsed is None else None,
                "headers": dict(response.getheaders()),
                "error": error,
            }, ensure_ascii=False))
        except Exception as exc:
            print(json.dumps({
                "ok": False,
                "status_code": None,
                "payload": None,
                "raw_body": None,
                "error": str(exc),
            }, ensure_ascii=False))
        """
    }

    private var apiStreamRequestScript: String {
        """
        import http.client

        request = payload

        def emit(value):
            print(json.dumps(value, ensure_ascii=False), flush=True)

        def api_headers():
            headers = {
                "Accept": "text/event-stream",
                "Content-Type": "application/json",
            }
            api_key = normalize_text(request.get("api_key"))
            if api_key:
                headers["Authorization"] = "Bearer " + api_key
            return headers

        try:
            body_value = request.get("body")
            body_data = None
            if body_value is not None:
                body_data = json.dumps(body_value, ensure_ascii=False).encode("utf-8")

            connection = http.client.HTTPConnection(
                "127.0.0.1",
                int(request.get("port") or 8642),
                timeout=int(request.get("timeout_seconds") or 30),
            )
            headers = api_headers()
            extra_headers = request.get("headers") or {}
            if isinstance(extra_headers, dict):
                for key, value in extra_headers.items():
                    key_text = normalize_text(key)
                    value_text = normalize_text(value)
                    if key_text and value_text:
                        headers[key_text] = value_text

            connection.request(
                request.get("method") or "GET",
                request.get("path") or "/v1/responses",
                body=body_data,
                headers=headers,
            )
            response = connection.getresponse()

            if not (200 <= response.status < 300):
                response_body = response.read().decode("utf-8", errors="replace")
                parsed = None
                try:
                    parsed = json.loads(response_body) if response_body.strip() else None
                except Exception:
                    pass
                error = response.reason
                if isinstance(parsed, dict):
                    raw_error = parsed.get("error")
                    if isinstance(raw_error, dict):
                        error = raw_error.get("message") or json.dumps(raw_error, ensure_ascii=False)
                    elif raw_error:
                        error = stringify(raw_error)
                elif response_body.strip():
                    error = response_body.strip()
                emit({"ok": False, "status_code": response.status, "payload": parsed, "error": error})
                connection.close()
                raise SystemExit(0)

            content_type = dict(response.getheaders()).get("Content-Type", "")
            if "text/event-stream" not in content_type.lower():
                response_body = response.read().decode("utf-8", errors="replace")
                parsed = json.loads(response_body) if response_body.strip() else None
                emit({"ok": True, "event": "response.completed", "payload": {"response": parsed}})
                connection.close()
                raise SystemExit(0)

            event_name = None
            while True:
                raw_line = response.readline()
                if not raw_line:
                    break
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line:
                    event_name = None
                    continue
                if line.startswith(":"):
                    continue
                if line.startswith("event:"):
                    event_name = line[6:].strip() or None
                    continue
                if not line.startswith("data:"):
                    continue

                data_text = line[5:].strip()
                if data_text == "[DONE]":
                    emit({"ok": True, "event": "done", "payload": {}})
                    continue
                try:
                    parsed = json.loads(data_text)
                except Exception:
                    emit({"ok": True, "event": event_name or "data", "payload": {"text": data_text}})
                    continue
                parsed_event = None
                if isinstance(parsed, dict):
                    parsed_event = parsed.get("type") or parsed.get("event")
                emit({"ok": True, "event": event_name or parsed_event or "data", "payload": parsed})

            connection.close()
        except Exception as exc:
            emit({"ok": False, "status_code": None, "payload": None, "error": str(exc)})
        """
    }

    private var apiBootstrapScript: String {
        """
        import os
        import pathlib
        import socket
        import subprocess
        import time

        request = payload
        port = int(request.get("port") or 8642)
        api_key = normalize_text(request.get("api_key"))

        def port_is_open():
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.75):
                    return True
            except Exception:
                return False

        def gateway_processes():
            try:
                output = subprocess.check_output(
                    ["ps", "-axo", "pid=,command="],
                    text=True,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:
                return []

            rows = []
            current_pid = str(os.getpid())
            for raw_line in output.splitlines():
                line = raw_line.strip()
                lowered = line.lower()
                if not line or line.startswith(current_pid + " "):
                    continue
                if "hermes" in lowered and "gateway" in lowered:
                    rows.append(line)
            return rows

        def wait_for_port(deadline_seconds):
            deadline = time.time() + deadline_seconds
            while time.time() < deadline:
                if port_is_open():
                    return True
                time.sleep(0.35)
            return port_is_open()

        try:
            hermes_bin = find_hermes_binary(request)
            if not hermes_bin:
                print(json.dumps({
                    "ok": False,
                    "started": False,
                    "already_running": False,
                    "hermes_cli_available": False,
                    "error": "Hermes CLI not found on the remote host.",
                }, ensure_ascii=False))
                raise SystemExit(0)

            if port_is_open():
                print(json.dumps({
                    "ok": True,
                    "started": False,
                    "already_running": True,
                    "hermes_cli_available": True,
                    "error": None,
                }, ensure_ascii=False))
                raise SystemExit(0)

            running_gateways = gateway_processes()
            if running_gateways:
                print(json.dumps({
                    "ok": False,
                    "started": False,
                    "already_running": True,
                    "hermes_cli_available": True,
                    "error": (
                        "Hermes is already running, but its chat API is not listening on "
                        f"127.0.0.1:{port}. Restart Hermes for this profile with API_SERVER_ENABLED=true "
                        f"and API_SERVER_PORT={port}. A Telegram-only setup does not automatically "
                        "enable the HTTP chat API."
                    ),
                }, ensure_ascii=False))
                raise SystemExit(0)

            hermes_home = resolved_hermes_home(request)
            log_dir = hermes_home / "logs"
            log_dir.mkdir(parents=True, exist_ok=True)
            log_path = log_dir / "mobile-chat-api.log"

            env = os.environ.copy()
            env["HERMES_HOME"] = str(hermes_home)
            env["API_SERVER_ENABLED"] = "true"
            env["API_SERVER_HOST"] = "127.0.0.1"
            env["API_SERVER_PORT"] = str(port)
            if api_key:
                env["API_SERVER_KEY"] = api_key

            with open(log_path, "ab", buffering=0) as log_file:
                log_file.write(b"\\n[Hermes mobile] starting chat API service\\n")
                subprocess.Popen(
                    [hermes_bin, "gateway"],
                    stdin=subprocess.DEVNULL,
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                    env=env,
                    start_new_session=True,
                    close_fds=True,
                )

            if wait_for_port(8):
                print(json.dumps({
                    "ok": True,
                    "started": True,
                    "already_running": False,
                    "hermes_cli_available": True,
                    "error": None,
                }, ensure_ascii=False))
                raise SystemExit(0)

            print(json.dumps({
                "ok": False,
                "started": True,
                "already_running": False,
                "hermes_cli_available": True,
                "error": (
                    f"Started Hermes, but the chat API did not begin listening on "
                    f"127.0.0.1:{port}. Check {tilde(log_path)} on the remote host."
                ),
            }, ensure_ascii=False))
        except Exception as exc:
            print(json.dumps({
                "ok": False,
                "started": False,
                "already_running": False,
                "hermes_cli_available": True,
                "error": str(exc),
            }, ensure_ascii=False))
        """
    }

    private func value(in payload: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func normalizedAPIKey(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct HermesAPIStreamEvent: Sendable {
    let type: String
    let payload: JSONValue
}

struct HermesAPIChatCompletionResponse: Sendable {
    let payload: JSONValue
    let headers: [String: String]

    var id: String? {
        payload.objectValue.flatMap { value(in: $0, keys: ["id"]) }
    }

    var model: String? {
        payload.objectValue.flatMap { value(in: $0, keys: ["model"]) }
    }

    var sessionID: String? {
        headers.first { key, _ in key.caseInsensitiveCompare("X-Hermes-Session-Id") == .orderedSame }?.value
    }

    var finishReason: String? {
        guard let choice = payload.objectValue?["choices"]?.arrayValue?.first?.objectValue else { return nil }
        return value(in: choice, keys: ["finish_reason"])
    }

    var assistantText: String {
        guard let choice = payload.objectValue?["choices"]?.arrayValue?.first?.objectValue,
              let message = choice["message"]?.objectValue else {
            return ""
        }
        return value(in: message, keys: ["content"]) ?? ""
    }

    var toolPayloads: [[String: JSONValue]] {
        guard let choice = payload.objectValue?["choices"]?.arrayValue?.first?.objectValue,
              let message = choice["message"]?.objectValue else {
            return []
        }

        var payloads: [[String: JSONValue]] = []
        if let toolCalls = message["tool_calls"]?.arrayValue {
            payloads.append(contentsOf: toolCalls.compactMap { call in
                guard var object = call.objectValue else { return nil }
                if let function = object["function"]?.objectValue {
                    if object["name"] == nil, let name = function["name"] {
                        object["name"] = name
                    }
                    if object["arguments"] == nil, let arguments = function["arguments"] {
                        object["arguments"] = arguments
                    }
                }
                if object["type"] == nil {
                    object["type"] = .string("function_call")
                }
                return object
            })
        }
        if var functionCall = message["function_call"]?.objectValue {
            functionCall["type"] = functionCall["type"] ?? .string("function_call")
            payloads.append(functionCall)
        }
        return payloads
    }

    private func value(in payload: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

struct HermesAPIResponse: Sendable {
    let payload: JSONValue

    var id: String? {
        payload.objectValue.flatMap { value(in: $0, keys: ["id", "response_id"]) }
    }

    var status: String? {
        payload.objectValue.flatMap { value(in: $0, keys: ["status"]) }
    }

    var model: String? {
        payload.objectValue.flatMap { value(in: $0, keys: ["model"]) }
    }

    var outputItems: [JSONValue] {
        payload.objectValue?["output"]?.arrayValue ?? []
    }

    var assistantText: String {
        outputItems.compactMap { item -> String? in
            guard let object = item.objectValue else { return nil }
            guard value(in: object, keys: ["type"]) == "message" else { return nil }
            let role = value(in: object, keys: ["role"]) ?? "assistant"
            guard role == "assistant" else { return nil }
            return object["content"]?.arrayValue?.compactMap { contentItem -> String? in
                guard let content = contentItem.objectValue else { return nil }
                return value(in: content, keys: ["text"])
            }.joined(separator: "")
        }.joined(separator: "\n")
    }

    var toolPayloads: [[String: JSONValue]] {
        outputItems.compactMap { item in
            guard let object = item.objectValue else { return nil }
            let type = value(in: object, keys: ["type"]) ?? ""
            guard isToolItemType(type) else { return nil }
            return object
        }
    }

    private func isToolItemType(_ itemType: String) -> Bool {
        guard itemType != "message", itemType != "reasoning" else { return false }
        return itemType == "function_call" ||
            itemType == "function_call_output" ||
            itemType == "custom_tool_call" ||
            itemType == "custom_tool_call_output" ||
            itemType.hasSuffix("_call") ||
            itemType.hasSuffix("_call_output")
    }

    private func value(in payload: [String: JSONValue], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private struct HermesAPIRequest: Encodable {
    let port: Int
    let apiKey: String?
    let path: String
    let method: String
    let body: JSONValue?
    let timeoutSeconds: Int
    let headers: [String: String]?

    enum CodingKeys: String, CodingKey {
        case port
        case apiKey = "api_key"
        case path
        case method
        case body
        case timeoutSeconds = "timeout_seconds"
        case headers
    }
}

private struct HermesAPIBootstrapRequest: Encodable {
    let port: Int
    let apiKey: String?

    enum CodingKeys: String, CodingKey {
        case port
        case apiKey = "api_key"
    }
}

private struct HermesAPIStreamEnvelope: Decodable, Sendable {
    let ok: Bool
    let event: String?
    let payload: JSONValue?
    let statusCode: Int?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case event
        case payload
        case statusCode = "status_code"
        case error
    }
}

private struct HermesAPIServiceEnvelope: Decodable {
    let ok: Bool
    let statusCode: Int?
    let payload: JSONValue?
    let rawBody: String?
    let headers: [String: String]?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case statusCode = "status_code"
        case payload
        case rawBody = "raw_body"
        case headers
        case error
    }
}

private struct HermesAPIBootstrapEnvelope: Decodable {
    let ok: Bool
    let started: Bool
    let alreadyRunning: Bool
    let hermesCLIAvailable: Bool
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case started
        case alreadyRunning = "already_running"
        case hermesCLIAvailable = "hermes_cli_available"
        case error
    }
}

enum HermesAPIChatServiceError: LocalizedError, Sendable {
    case remote(statusCode: Int?, message: String)

    var errorDescription: String? {
        switch self {
        case .remote(let statusCode, let message):
            if let statusCode {
                return "Hermes chat API returned HTTP \(statusCode): \(message)"
            }
            return message
        }
    }
}
