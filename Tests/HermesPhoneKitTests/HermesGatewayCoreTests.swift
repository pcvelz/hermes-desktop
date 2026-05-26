import Foundation
import Testing

@testable import HermesPhoneKit

actor CapturedGatewayLines {
    private var lines: [String] = []

    func append(_ line: String) {
        lines.append(line)
    }

    func firstLine() -> String? {
        lines.first
    }
}

struct HermesGatewayCoreTests {
    @Test
    func rpcRequestMatchesResponseByID() async throws {
        let client = HermesGatewayRPCClient()
        let capturedLines = CapturedGatewayLines()
        await client.attachSender { line in
            await capturedLines.append(line)
        }

        let requestTask = Task {
            try await client.request(method: "session.create", params: ["client": .string("test")], timeout: 2)
        }

        var requestID: Int?
        for _ in 0..<20 {
            if let line = await capturedLines.firstLine(),
               let data = line.data(using: .utf8),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                requestID = object["id"] as? Int
                #expect(object["method"] as? String == "session.create")
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let id = try #require(requestID)
        await client.handleStdoutLine("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"session_id\":\"session-1\"}}")

        let result = try await requestTask.value
        #expect(result?.objectValue?["session_id"]?.stringValue == "session-1")
    }

    @Test
    func rpcDecodesGatewayEventsFromJsonLines() async throws {
        let client = HermesGatewayRPCClient()
        let events = client.events
        let eventTask = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        await client.handleStdoutLine("{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"type\":\"message.delta\",\"session_id\":\"session-1\",\"payload\":{\"delta\":\"hello\"}}}")

        let event = try #require(await eventTask.value)
        #expect(event.type == "message.delta")
        #expect(event.sessionID == "session-1")
        #expect(event.payload["delta"]?.stringValue == "hello")
    }

    @Test
    func rpcReportsInvalidFramesAsParseEvents() async throws {
        let client = HermesGatewayRPCClient()
        let events = client.events
        let eventTask = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        await client.handleStdoutLine("not json")

        let event = try #require(await eventTask.value)
        #expect(event.type == "gateway.parse_error")
        #expect(event.payload["line"]?.stringValue == "not json")
    }

    @Test
    func commandDispatchResultsMapToPrimaryActions() {
        let skill = HermesGatewayCommandResult(.object([
            "type": .string("skill"),
            "message": .string("Use the selected skill")
        ]))
        #expect(skill.primaryAction == .submit("Use the selected skill"))

        let exec = HermesGatewayCommandResult(.object([
            "type": .string("exec"),
            "output": .string("Model switched")
        ]))
        #expect(exec.primaryAction == .render("Model switched"))

        let alias = HermesGatewayCommandResult(.object([
            "type": .string("alias"),
            "target": .string("/model")
        ]))
        #expect(alias.primaryAction == .alias("/model"))
    }

    @Test
    func capabilityProbeParsesBooleansAndReasons() {
        #expect(HermesNativeChatCapabilityProbe.bool(from: "1\n"))
        #expect(HermesNativeChatCapabilityProbe.bool(from: "true"))
        #expect(!HermesNativeChatCapabilityProbe.bool(from: "0"))

        var missingPython = HermesChatBootstrapStatus(sshConnected: true)
        #expect(HermesNativeChatCapabilityProbe.fallbackReason(for: missingPython) == "python3 is not available on the remote host.")

        let missingGateway = HermesChatBootstrapStatus(
            sshConnected: true,
            pythonAvailable: true,
            hermesCLIAvailable: true,
            tuiGatewayAvailable: false
        )
        #expect(HermesNativeChatCapabilityProbe.fallbackReason(for: missingGateway) == "tui_gateway.entry is not importable on this host.")

        missingPython.pythonAvailable = true
        missingPython.hermesCLIAvailable = false
        #expect(HermesNativeChatCapabilityProbe.fallbackReason(for: missingPython) == "Hermes CLI is not available on the remote host.")
    }
}
