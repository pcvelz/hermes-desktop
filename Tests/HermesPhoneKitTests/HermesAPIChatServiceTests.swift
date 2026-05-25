import Testing

@testable import HermesPhoneKit

struct HermesAPIChatServiceTests {
    @Test
    func responseExtractsAssistantTextAndToolPayloads() {
        let response = HermesAPIResponse(
            payload: .object([
                "id": .string("resp_123"),
                "status": .string("completed"),
                "model": .string("hermes-agent"),
                "output": .array([
                    .object([
                        "type": .string("function_call"),
                        "name": .string("terminal"),
                        "call_id": .string("call_1"),
                        "arguments": .string("{\"command\":\"ls\"}")
                    ]),
                    .object([
                        "type": .string("function_call_output"),
                        "call_id": .string("call_1"),
                        "output": .string("README.md")
                    ]),
                    .object([
                        "type": .string("web_search_call"),
                        "id": .string("ws_1"),
                        "status": .string("completed")
                    ]),
                    .object([
                        "type": .string("message"),
                        "role": .string("assistant"),
                        "content": .array([
                            .object([
                                "type": .string("output_text"),
                                "text": .string("Done.")
                            ])
                        ])
                    ])
                ])
            ])
        )

        #expect(response.id == "resp_123")
        #expect(response.status == "completed")
        #expect(response.model == "hermes-agent")
        #expect(response.assistantText == "Done.")
        #expect(response.toolPayloads.count == 3)
    }

    @Test
    func chatCompletionExtractsToolCallsFromAssistantMessage() {
        let response = HermesAPIChatCompletionResponse(
            payload: .object([
                "choices": .array([
                    .object([
                        "message": .object([
                            "role": .string("assistant"),
                            "content": .string(""),
                            "tool_calls": .array([
                                .object([
                                    "id": .string("call_1"),
                                    "type": .string("function"),
                                    "function": .object([
                                        "name": .string("terminal"),
                                        "arguments": .string("{\"command\":\"pwd\"}")
                                    ])
                                ])
                            ])
                        ]),
                        "finish_reason": .string("tool_calls")
                    ])
                ])
            ]),
            headers: [:]
        )

        #expect(response.finishReason == "tool_calls")
        #expect(response.toolPayloads.count == 1)
        #expect(response.toolPayloads.first?["name"]?.stringValue == "terminal")
        #expect(response.toolPayloads.first?["arguments"]?.stringValue == "{\"command\":\"pwd\"}")
    }
}
