import XCTest
import Synchronization
@testable import Atlas

/// Provider contracts use isolated URLProtocol sessions; no real network calls.
final class ToolCallingTests: XCTestCase, @unchecked Sendable {

    private let toolIds = ["image.convert", "file.zip", "file.select"]

    private var schemaParams: [String: Any] {
        PlanToolSchema.parametersJSON(toolIds: toolIds)
    }

    // MARK: - PlanToolSchema

    func testSchemaShape() throws {
        XCTAssertEqual(PlanToolSchema.functionName, "submit_plan")
        let steps = try XCTUnwrap(schemaParams["properties"] as? [String: Any])["steps"] as? [String: Any]
        XCTAssertNotNil(steps)
        let items = try XCTUnwrap(steps?["items"] as? [String: Any])
        let props = try XCTUnwrap(items["properties"] as? [String: Any])
        let tool = try XCTUnwrap(props["tool"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(tool["enum"] as? [String]), toolIds)
        XCTAssertEqual(try XCTUnwrap(items["required"] as? [String]), ["id", "tool", "inputs"])
        XCTAssertEqual(try XCTUnwrap(schemaParams["required"] as? [String]), ["steps"])
    }

    // MARK: - OpenAI-style builders (senza tools = payload legacy)

    func testOpenAIDefaultRequestOmitsUnsupportedReasoning() async throws {
        let stub = ProviderHTTPStub(status: 200, body: ProviderHTTPStub.openAIResponse)
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.unregister() }
        let provider = OpenAIModelProvider(apiKey: "fixture", session: session)
        assertGraph(try await provider.plan(prompt: "fixture", isComplex: true))
        let body = try stub.firstRequestBody()
        XCTAssertNil(body["reasoning_effort"])
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
    }

    func testOllamaDisabledThinkingUsesTopLevelThink() async throws {
        let response = try JSONSerialization.data(withJSONObject: ["response": ProviderHTTPStub.graphJSON])
        let stub = ProviderHTTPStub(status: 200, body: response)
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.unregister() }
        let provider = OllamaModelProvider(endpoint: "https://ollama.invalid/api/generate", model: "fixture", disableThinking: true, session: session)
        assertGraph(try await provider.plan(prompt: "fixture", isComplex: true))
        let body = try stub.firstRequestBody()
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertNil((body["options"] as? [String: Any])?["thinking"])
        let enabled = OllamaModelProvider.makeBody(prompt: "fixture", isComplex: false, model: "fixture", toolParameters: nil, disableThinking: false)
        XCTAssertNil(enabled["think"])
        XCTAssertNil((enabled["options"] as? [String: Any])?["thinking"])
    }

    func testNvidiaUnauthorizedDoesNotRetry() async throws {
        let stub = ProviderHTTPStub(status: 401, body: Data("unauthorized".utf8))
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.unregister() }
        do {
            _ = try await NvidiaModelProvider(apiKey: "fixture", session: session).plan(prompt: "fixture", isComplex: false)
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
        }
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testNvidiaServiceUnavailableStopsAfterThreeAttempts() async throws {
        let stub = ProviderHTTPStub(status: 503, body: Data("unavailable".utf8))
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.unregister() }
        do {
            _ = try await NvidiaModelProvider(apiKey: "fixture", session: session).plan(prompt: "fixture", isComplex: false)
            XCTFail("Expected service failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("503"))
        }
        XCTAssertEqual(stub.requestCount, 3)
    }

    func testNvidiaCancellationStopsRetrying() async throws {
        let received = expectation(description: "first request")
        let stub = ProviderHTTPStub(status: 503, body: Data(), onRequest: { received.fulfill() })
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.unregister() }
        let task = Task {
            try await NvidiaModelProvider(apiKey: "fixture", session: session).plan(prompt: "fixture", isComplex: false)
        }
        await fulfillment(of: [received], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testNvidiaCancelledTransportDoesNotRetry() async throws {
        let stub = ProviderHTTPStub(status: 200, body: Data(), error: URLError(.cancelled))
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.unregister() }
        do {
            _ = try await NvidiaModelProvider(apiKey: "fixture", session: session).plan(prompt: "fixture", isComplex: false)
            XCTFail("Expected transport cancellation")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
        XCTAssertEqual(stub.requestCount, 1)
    }

    func testNvidiaMalformedPlanDoesNotRetry() async throws {
        let response = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "not a plan"]]]])
        let stub = ProviderHTTPStub(status: 200, body: response)
        let session = stub.makeSession()
        defer { session.invalidateAndCancel(); stub.unregister() }
        do {
            _ = try await NvidiaModelProvider(apiKey: "fixture", session: session).plan(prompt: "fixture", isComplex: false)
            XCTFail("Expected decode failure")
        } catch {
            guard case PlannerError.decodingFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertEqual(stub.requestCount, 1)
    }


    func testOpenAIBodyWithTools() throws {
        let body = OpenAIModelProvider.makeBody(prompt: "p", isComplex: false, model: "gpt-4o-mini", toolParameters: schemaParams)
        // Parametri invariati
        XCTAssertEqual(body["model"] as? String, "gpt-4o-mini")
        XCTAssertEqual(body["temperature"] as? Double, 0.0)
        XCTAssertEqual(body["max_tokens"] as? Int, 1200)
        // response_format rimosso quando i tools sono attivi
        XCTAssertNil(body["response_format"])

        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "submit_plan")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertNotNil(try XCTUnwrap(parameters["properties"] as? [String: Any])["steps"] as? [String: Any])

        let choice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "function")
        let choiceFn = try XCTUnwrap(choice["function"] as? [String: Any])
        XCTAssertEqual(choiceFn["name"] as? String, "submit_plan")
    }

    func testNvidiaBodyWithoutAndWithTools() throws {
        let legacy = NvidiaModelProvider.makeBody(prompt: "p", isComplex: false, model: "meta/llama-3.3-70b-instruct", toolParameters: nil)
        XCTAssertNil(legacy["tools"])
        XCTAssertNil(legacy["tool_choice"])
        XCTAssertNil(legacy["response_format"])
        XCTAssertEqual(legacy["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(legacy["max_tokens"] as? Int, 1200)

        let withTools = NvidiaModelProvider.makeBody(prompt: "p", isComplex: true, model: "m", toolParameters: schemaParams)
        XCTAssertNil(withTools["thinking"])
        let tools = try XCTUnwrap(withTools["tools"] as? [[String: Any]])
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "submit_plan")
        let choice = try XCTUnwrap(withTools["tool_choice"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(choice["function"] as? [String: Any])["name"] as? String, "submit_plan")
    }

    func testCompatibleBodyWithoutAndWithTools() throws {
        let legacy = OpenAICompatibleModelProvider.makeBody(prompt: "p", isComplex: false, model: "local-model", toolParameters: nil)
        XCTAssertNil(legacy["tools"])
        XCTAssertEqual(legacy["response_format"] as? [String: String], ["type": "json_object"])
        XCTAssertEqual(legacy["reasoning_effort"] as? String, "low")

        let withTools = OpenAICompatibleModelProvider.makeBody(prompt: "p", isComplex: true, model: "local-model", toolParameters: schemaParams)
        XCTAssertNil(withTools["response_format"])
        XCTAssertNotNil(withTools["tools"])
        XCTAssertNotNil(withTools["tool_choice"])
    }

    func testOpenCodeBodyKeepsMaxTokensAndEffort() throws {
        let legacyComplex = OpenCodeModelProvider.makeBody(prompt: "p", isComplex: true, model: "deepseek-v4-flash-free", toolParameters: nil)
        XCTAssertEqual(legacyComplex["max_tokens"] as? Int, 3500)
        XCTAssertEqual(legacyComplex["reasoning_effort"] as? String, "medium")

        let withToolsSimple = OpenCodeModelProvider.makeBody(prompt: "p", isComplex: false, model: "m", toolParameters: schemaParams)
        XCTAssertEqual(withToolsSimple["max_tokens"] as? Int, 2500)
        XCTAssertEqual(withToolsSimple["reasoning_effort"] as? String, "low")
        XCTAssertNil(withToolsSimple["response_format"])
        XCTAssertNotNil(withToolsSimple["tools"])
    }

    // MARK: - Claude builder

    func testClaudeBodyWithoutToolsIsLegacy() {
        let body = ClaudeModelProvider.makeBody(prompt: "p", isComplex: false, model: "claude-sonnet-4-5", toolParameters: nil)
        XCTAssertNil(body["tools"])
        XCTAssertNil(body["tool_choice"])
        XCTAssertEqual(body["max_tokens"] as? Int, 1200)
        XCTAssertEqual(body["temperature"] as? Double, 0.0)
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1)
    }

    func testClaudeBodyTopLevelTools() throws {
        let body = ClaudeModelProvider.makeBody(prompt: "p", isComplex: true, model: "claude-sonnet-4-5", toolParameters: schemaParams)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "submit_plan")
        let inputSchema = try XCTUnwrap(tools[0]["input_schema"] as? [String: Any])
        XCTAssertEqual(inputSchema["type"] as? String, "object")
        let choice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "tool")
        XCTAssertEqual(choice["name"] as? String, "submit_plan")
    }

    // MARK: - Ollama builder

    func testOllamaFormatSwitchesBetweenJSONAndSchema() throws {
        let legacy = OllamaModelProvider.makeBody(prompt: "p", isComplex: false, model: "llama3", toolParameters: nil)
        XCTAssertEqual(legacy["format"] as? String, "json")
        XCTAssertEqual((legacy["options"] as? [String: Any])?["num_predict"] as? Int, 1200)

        let structured = OllamaModelProvider.makeBody(prompt: "p", isComplex: true, model: "llama3", toolParameters: schemaParams)
        let format = try XCTUnwrap(structured["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "object")
        XCTAssertNotNil(format["properties"])
    }

    // MARK: - parseOpenAIMessage

    private func assertGraph(_ graph: ActionGraph, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(graph.steps.count, 1, file: file, line: line)
        XCTAssertEqual(graph.steps.first?.id, "a", file: file, line: line)
        XCTAssertEqual(graph.steps.first?.tool, "file.zip", file: file, line: line)
    }

    func testParseOpenAIMessageFromToolCall() throws {
        let arguments = "{\"steps\":[{\"id\":\"a\",\"tool\":\"file.zip\",\"inputs\":[]}]}"
        let message: [String: Any] = [
            "role": "assistant",
            "content": NSNull(),
            "tool_calls": [[
                "id": "call_1",
                "type": "function",
                "function": [
                    "name": "submit_plan",
                    "arguments": arguments
                ]
            ]]
        ]
        assertGraph(try PlanResponseParser.parseOpenAIMessage(message))
    }

    func testParseOpenAIMessageFallsBackToFencedContent() throws {
        let message: [String: Any] = [
            "content": "Ecco il piano:\n```json\n{\"steps\":[{\"id\":\"a\",\"tool\":\"file.zip\",\"inputs\":[]}]}\n```"
        ]
        assertGraph(try PlanResponseParser.parseOpenAIMessage(message))
    }

    func testParseOpenAIMessageMalformedArgumentsThrowsDecodingFailed() {
        let message: [String: Any] = [
            "tool_calls": [[
                "function": [
                    "name": "submit_plan",
                    "arguments": "{not json at all"
                ]
            ]]
        ]
        XCTAssertThrowsError(try PlanResponseParser.parseOpenAIMessage(message)) { error in
            guard case PlannerError.decodingFailed = error else {
                return XCTFail("Atteso decodingFailed, ottenuto \(error)")
            }
        }
    }

    func testParseOpenAIMessageEmptyContentThrowsInvalidResponse() {
        XCTAssertThrowsError(try PlanResponseParser.parseOpenAIMessage(["content": ""])) { error in
            guard case PlannerError.invalidResponse = error else {
                return XCTFail("Atteso invalidResponse, ottenuto \(error)")
            }
        }
    }

    // MARK: - parseClaudeContent

    func testParseClaudeToolUseBlock() throws {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "Calcolo il piano."],
            [
                "type": "tool_use",
                "id": "toolu_1",
                "name": "submit_plan",
                "input": ["steps": [["id": "a", "tool": "file.zip", "inputs": []]]]
            ]
        ]
        assertGraph(try PlanResponseParser.parseClaudeContent(blocks))
    }

    func testParseClaudeTextOnlyFallback() throws {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "{\"steps\":[{\"id\":\"a\",\"tool\":\"file.zip\",\"inputs\":[]}]}" ]
        ]
        assertGraph(try PlanResponseParser.parseClaudeContent(blocks))
    }

    func testParseClaudeMixedBlocksPreferToolUse() throws {
        let blocks: [[String: Any]] = [
            ["type": "text", "text": "{\"steps\":[{\"id\":\"sbagliato\",\"tool\":\"file.select\",\"inputs\":[]}]}" ],
            [
                "type": "tool_use",
                "name": "submit_plan",
                "input": ["steps": [["id": "a", "tool": "file.zip", "inputs": []]]]
            ]
        ]
        assertGraph(try PlanResponseParser.parseClaudeContent(blocks))
    }
}

private final class ProviderHTTPStub: Sendable {
    static let graphJSON = #"{"steps":[{"id":"a","tool":"file.zip","inputs":[]}]}"#
    static let openAIResponse = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": graphJSON]]]])
    private static let registry = Mutex<[String: ProviderHTTPStub]>([:])
    private let id = UUID().uuidString
    private let requests = Mutex<[Data]>([])
    let status: Int
    let body: Data
    let error: URLError?
    let onRequest: (@Sendable () -> Void)?

    init(status: Int, body: Data, error: URLError? = nil, onRequest: (@Sendable () -> Void)? = nil) {
        self.status = status
        self.body = body
        self.error = error
        self.onRequest = onRequest
    }

    var requestCount: Int { requests.withLock { $0.count } }

    func makeSession() -> URLSession {
        Self.registry.withLock { $0[id] = self }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Atlas-Fixture": id]
        return URLSession(configuration: configuration)
    }

    func unregister() { Self.registry.withLock { _ = $0.removeValue(forKey: id) } }

    static func find(for request: URLRequest) -> ProviderHTTPStub? {
        guard let id = request.value(forHTTPHeaderField: "X-Atlas-Fixture") else { return nil }
        return registry.withLock { $0[id] }
    }

    func record(_ request: URLRequest) {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        requests.withLock { $0.append(data) }
        onRequest?()
    }

    func firstRequestBody() throws -> [String: Any] {
        let data = try XCTUnwrap(requests.withLock { $0.first })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class ProviderStubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = ProviderHTTPStub.find(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        stub.record(request)
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
