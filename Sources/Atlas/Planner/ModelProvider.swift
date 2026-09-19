import Foundation
import FoundationModels

// MARK: - Shared HTTP settings

/// Timeout generoso per le richieste ai provider LLM: i modelli in modalità
/// reasoning (o sotto carico) possono impiegare oltre i 60s di default di URLSession.
private let httpRequestTimeout: TimeInterval = 300

// MARK: - Provider Enum

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case apple = "Apple Intelligence"
    case opencode = "OpenCode AI (Zen)"
    case ollama = "Ollama (Locale)"
    case openai = "OpenAI"
    case claude = "Claude"
    case nvidia = "NVIDIA Build"
    case openaiCompatible = "Custom (OpenAI-Compatible)"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .apple: return "brain.head.profile"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .ollama: return "desktopcomputer"
        case .openai: return "globe"
        case .claude: return "sparkle"
        case .nvidia: return "cpu"
        case .openaiCompatible: return "puzzlepiece.extension"
        }
    }
}

// MARK: - Provider Protocol

protocol ModelProvider: Sendable {
    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph
}

extension ModelProvider {
    func plan(prompt: String) async throws -> ActionGraph {
        try await plan(prompt: prompt, isComplex: false)
    }
}

// MARK: - Shared JSON extraction

enum ActionGraphParser {
    static func parse(_ text: String) throws -> ActionGraph {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoder = JSONDecoder()
        if let graph = try? decoder.decode(ActionGraph.self, from: Data(raw.utf8)) { return graph }

        var unwrapped = raw
        while true {
            let previous = unwrapped
            for tag in ["think", "reasoning"] {
                if unwrapped.lowercased().hasPrefix("<\(tag)>"),
                   let end = unwrapped.range(of: "</\(tag)>", options: .caseInsensitive) {
                    unwrapped = String(unwrapped[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if unwrapped.hasPrefix("```"), unwrapped.hasSuffix("```"),
               let newline = unwrapped.firstIndex(of: "\n") {
                let header = unwrapped[..<newline].lowercased()
                if header == "```" || header == "```json" {
                    unwrapped = String(unwrapped[unwrapped.index(after: newline)..<unwrapped.index(unwrapped.endIndex, offsetBy: -3)])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if unwrapped == previous { break }
        }
        if let graph = try? decoder.decode(ActionGraph.self, from: Data(unwrapped.utf8)) { return graph }

        // Only outermost balanced values are candidates: never salvage a nested
        // valid step from a malformed plan or rewrite quoted JSON contents.
        var start: String.Index?
        var closing: [Character] = []
        var inString = false
        var escaped = false
        var candidates: [ActionGraph] = []
        for index in unwrapped.indices {
            let character = unwrapped[index]
            if start == nil {
                if character == "{" || character == "[" {
                    start = index
                    closing = [character == "{" ? "}" : "]"]
                }
                continue
            }
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" { inString = true }
            else if character == "{" { closing.append("}") }
            else if character == "[" { closing.append("]") }
            else if character == "}" || character == "]" {
                guard closing.last == character else {
                    start = nil
                    closing.removeAll()
                    continue
                }
                closing.removeLast()
                if closing.isEmpty, let first = start {
                    if let graph = try? decoder.decode(ActionGraph.self, from: Data(unwrapped[first...index].utf8)) {
                        candidates.append(graph)
                    }
                    start = nil
                }
            }
        }
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 {
            throw PlannerError.decodingFailed("Risposta ambigua: contiene più piani JSON validi.")
        }
        throw PlannerError.decodingFailed("Formato JSON non valido o campi non conformi.\n\nTesto grezzo dal modello:\n\(text)")
    }
}

// MARK: - Shared structured-response parsing

/// Estrae l'ActionGraph dai payload strutturati nativi (tool calling), con
/// fallback sul parsing del testo libero esistente quando il modello non
/// emette una tool call. Il decode malformato fallisce senza retry
/// (`decodingFailed`): il retry resta appannaggio della validazione in Planner.
enum PlanResponseParser {
    /// Messaggio OpenAI-style (`choices[0].message`): prima
    /// `tool_calls[*].function.arguments` (stringa JSON), poi `content`.
    static func parseOpenAIMessage(_ message: [String: Any]) throws -> ActionGraph {
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let function = call["function"] as? [String: Any],
                      function["name"] as? String == PlanToolSchema.functionName,
                      let arguments = function["arguments"] as? String else { continue }
                return try decodeGraph(arguments, source: "tool arguments")
            }
        }

        guard let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannerError.invalidResponse
        }
        return try ActionGraphParser.parse(content)
    }

    /// Blocchi di contenuto Anthropic: primo block `tool_use` di `submit_plan`
    /// → `input`; altrimenti concat dei text blocks → parser leniente.
    static func parseClaudeContent(_ blocks: [[String: Any]]) throws -> ActionGraph {
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let name = block["name"] as? String,
                  name == PlanToolSchema.functionName,
                  let input = block["input"] else { continue }
            guard JSONSerialization.isValidJSONObject([input]),
                  let data = try? JSONSerialization.data(withJSONObject: input) else {
                throw PlannerError.decodingFailed("Input della tool use non serializzabile")
            }
            do {
                return try JSONDecoder().decode(ActionGraph.self, from: data)
            } catch {
                throw PlannerError.decodingFailed("Input tool_use non decodificabile come piano: \(error.localizedDescription)")
            }
        }

        let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlannerError.invalidResponse
        }
        return try ActionGraphParser.parse(text)
    }


    private static func decodeGraph(_ json: String, source: String) throws -> ActionGraph {
        guard let data = json.data(using: .utf8) else {
            throw PlannerError.decodingFailed("\(source) non validi come UTF-8")
        }
        do {
            return try JSONDecoder().decode(ActionGraph.self, from: data)
        } catch {
            throw PlannerError.decodingFailed("\(source) non decodificabili come ActionGraph: \(error.localizedDescription)")
        }
    }
}

// MARK: - Apple Foundation Models Provider (DEFAULT)

struct AppleModelProvider: ModelProvider {
    
    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph {
        let model = SystemLanguageModel.default
        
        guard model.isAvailable else {
            throw PlannerError.llmError("Apple Intelligence non è disponibile su questo dispositivo.")
        }
        
        let instructions = """
        You are Atlas, a macOS file automation assistant. Translate user requests into structured ActionGraph steps.
        
        RULES FOR FIELDS:
        - tool: Must be an exact tool ID from AVAILABLE TOOLS (image.convert, file.rename, file.select, file.zip, file.compress, pdf.merge, pdf.split, pdf.compress, video.extractAudio, video.convert).
        - FOR SELECT/HIGHLIGHT REQUESTS (e.g. "seleziona le immagini", "seleziona foto.png"): Use ONLY 'file.select'. DO NOT convert, rename, or modify files!
        - inputs: Array of exact filenames to process. If files are selected in CONTEXT, list ALL selected filenames in 'inputs'.
        - format: Output extension or template (e.g. "jpg", "webp", "png", "pdf", "mp3", "m4a", "zip", "foto_#.jpg"). Always set format when converting, zipping, or renaming.
        - grayscale: Set to true ONLY if user explicitly asks for Black & White, grayscale, or grigio.
        - dependsOn: Array of step IDs that must complete first (nil if no dependencies).
        """
        
        let session = LanguageModelSession(instructions: instructions)
        let response = try await session.respond(to: prompt, generating: ActionGraph.self)
        return response.content
    }
}

// MARK: - Ollama Provider (Fallback)

struct OllamaModelProvider: ModelProvider {
    var endpoint: String
    var model: String
    var disableThinking: Bool
    var session: URLSession
    /// ID dei tool registrati; vuoto = `format:"json"` (payload legacy).
    var toolIds: [String] = []

    init(endpoint: String, model: String, toolIds: [String] = [], disableThinking: Bool = false, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.model = model
        self.toolIds = toolIds
        self.disableThinking = disableThinking
        self.session = session
    }

    /// Body-builder testabile. Con `toolParameters == nil` il payload è
    /// identico al flusso storico (`format:"json"`); con lo schema diventa un
    /// oggetto (structured outputs nativi, Ollama ≥0.5).
    static func makeBody(prompt: String, isComplex: Bool, model: String,
                         toolParameters: [String: Any]?, disableThinking: Bool = false) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "format": toolParameters ?? "json",
            "options": [
                "temperature": 0.0,
                "num_predict": isComplex ? 3500 : 1200
            ]
        ]
        if disableThinking {
            body["think"] = false
        }
        return body
    }

    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph {
        let structuredSchema: [String: Any]? = toolIds.isEmpty
            ? nil
            : PlanToolSchema.parametersJSON(toolIds: toolIds)

        func run(_ schema: [String: Any]?) async throws -> ActionGraph {
            let text = try await generateText(prompt: prompt, isComplex: isComplex, toolParameters: schema)
            return try ActionGraphParser.parse(text)
        }

        guard let structured = structuredSchema else {
            return try await run(nil)
        }

        do {
            return try await run(structured)
        } catch PlannerError.decodingFailed {
            // Fallback unico (coerente col budget retry attuale): formato
            // JSON semplice e prompt originale, poi eventuale errore propagato.
            return try await run(nil)
        }
    }

    /// Esegue /api/generate e ritorna il testo di risposta. Se il server
    /// rifiuta esplicitamente lo schema strutturato (HTTP 400) riprova una
    /// volta sola con `format:"json"`.
    private func generateText(prompt: String, isComplex: Bool, toolParameters: [String: Any]?) async throws -> String {
        let requestBody = Self.makeBody(
            prompt: prompt,
            isComplex: isComplex,
            model: model,
            toolParameters: toolParameters,
            disableThinking: disableThinking
        )

        guard let url = URL(string: endpoint) else {
            throw PlannerError.llmError("Endpoint Ollama non valido: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = httpRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlannerError.llmError("Nessuna risposta da Ollama su \(endpoint).")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Only an explicit unsupported schema rejection warrants legacy format.
            let lower = body.lowercased()
            if toolParameters != nil, httpResponse.statusCode == 400,
               lower.contains("format"), (lower.contains("schema") || lower.contains("unmarshal")) {
                return try await generateText(prompt: prompt, isComplex: isComplex, toolParameters: nil)
            }
            throw PlannerError.llmError("Errore Ollama (HTTP \(httpResponse.statusCode)): \(body)")
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = jsonObject["response"] as? String else {
            throw PlannerError.invalidResponse
        }

        return responseText
    }
}

// MARK: - OpenAI Provider

struct OpenAIModelProvider: ModelProvider {
    var apiKey: String
    var model: String = "gpt-4o-mini"
    var session: URLSession
    /// ID dei tool registrati; vuoto = nessun tool calling (payload legacy).
    var toolIds: [String] = []

    init(apiKey: String, toolIds: [String] = [], session: URLSession = .shared) {
        self.apiKey = apiKey
        self.toolIds = toolIds
        self.session = session
    }

    /// Body-builder testabile. Con `toolParameters == nil` il payload è
    /// identico al flusso prompt-JSON storico.
    static func makeBody(prompt: String, isComplex: Bool, model: String,
                         toolParameters: [String: Any]?) -> [String: Any] {
        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "You are a filesystem assistant. Translate the user request into a structured ActionGraph JSON. Use tool IDs from the available tools list. Output ONLY the JSON object."
            ],
            [
                "role": "user",
                "content": prompt
            ]
        ]

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.0,
            "max_tokens": isComplex ? 3500 : 1200
        ]
        if let params = toolParameters {
            // Tool calling attivo: response_format json_object è ridondante e
            // alcuni endpoint rifiutano la combinazione.
            body["tools"] = [[
                "type": "function",
                "function": [
                    "name": PlanToolSchema.functionName,
                    "description": PlanToolSchema.description,
                    "parameters": params
                ]
            ]]
            body["tool_choice"] = ["type": "function", "function": ["name": PlanToolSchema.functionName]]
        } else {
            body["response_format"] = ["type": "json_object"]
        }
        return body
    }

    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph {
        guard !apiKey.isEmpty else {
            throw PlannerError.llmError("OpenAI non configurato. Imposta la tua API key nelle impostazioni.")
        }

        let requestBody = Self.makeBody(
            prompt: prompt,
            isComplex: isComplex,
            model: model,
            toolParameters: toolIds.isEmpty ? nil : PlanToolSchema.parametersJSON(toolIds: toolIds)
        )
        
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw PlannerError.llmError("URL OpenAI non valido")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = httpRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlannerError.llmError("Nessuna risposta da OpenAI")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PlannerError.llmError("Errore OpenAI (HTTP \(httpResponse.statusCode)): \(body)")
        }
        
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = jsonObject["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw PlannerError.invalidResponse
        }

        return try PlanResponseParser.parseOpenAIMessage(message)
    }
}

// MARK: - Claude Provider

struct ClaudeModelProvider: ModelProvider {
    var apiKey: String
    var model: String = "claude-sonnet-4-5"
    /// ID dei tool registrati; vuoto = nessun tool calling (payload legacy).
    var toolIds: [String] = []

    init(apiKey: String, toolIds: [String] = []) {
        self.apiKey = apiKey
        self.toolIds = toolIds
    }

    /// Body-builder testabile. Con `toolParameters == nil` il payload è
    /// identico al flusso prompt-JSON storico.
    static func makeBody(prompt: String, isComplex: Bool, model: String,
                         toolParameters: [String: Any]?) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": isComplex ? 3500 : 1200,
            "temperature": 0.0,
            "system": "You are a filesystem assistant. Translate the user request into a structured ActionGraph JSON. Use tool IDs from the available tools list. Output ONLY the raw JSON object, no markdown.",
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        if let params = toolParameters {
            // Anthropic: tools e tool_choice top-level (non dentro messages).
            body["tools"] = [[
                "name": PlanToolSchema.functionName,
                "description": PlanToolSchema.description,
                "input_schema": params
            ]]
            body["tool_choice"] = ["type": "tool", "name": PlanToolSchema.functionName]
        }
        return body
    }

    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph {
        guard !apiKey.isEmpty else {
            throw PlannerError.llmError("Claude non configurato. Imposta la tua API key nelle impostazioni.")
        }

        let requestBody = Self.makeBody(
            prompt: prompt,
            isComplex: isComplex,
            model: model,
            toolParameters: toolIds.isEmpty ? nil : PlanToolSchema.parametersJSON(toolIds: toolIds)
        )

        
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw PlannerError.llmError("URL Anthropic non valido")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = httpRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlannerError.llmError("Nessuna risposta da Anthropic")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PlannerError.llmError("Errore Anthropic (HTTP \(httpResponse.statusCode)): \(body)")
        }
        
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArray = jsonObject["content"] as? [[String: Any]] else {
            throw PlannerError.invalidResponse
        }

        return try PlanResponseParser.parseClaudeContent(contentArray)
    }
}

// MARK: - NVIDIA Build Provider

struct NvidiaModelProvider: ModelProvider {
    var apiKey: String
    var model: String
    var session: URLSession
    /// ID dei tool registrati; vuoto = nessun tool calling (payload legacy).
    var toolIds: [String] = []

    init(apiKey: String, model: String = "meta/llama-3.3-70b-instruct", toolIds: [String] = [], session: URLSession = .shared) {
        self.apiKey = apiKey
        if model.isEmpty || model.contains("deepseek-v4-flash") {
            self.model = "meta/llama-3.3-70b-instruct"
        } else {
            self.model = model
        }
        self.toolIds = toolIds
        self.session = session
    }

    /// Body-builder testabile. Con `toolParameters == nil` il payload è
    /// identico al flusso prompt-JSON storico.
    static func makeBody(prompt: String, isComplex: Bool, model: String,
                         toolParameters: [String: Any]?) -> [String: Any] {
        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": "You are a filesystem assistant. Translate the user request into a structured ActionGraph JSON. Use tool IDs from the available tools list. Output ONLY the JSON object."
            ],
            [
                "role": "user",
                "content": prompt
            ]
        ]

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.0,
            "max_tokens": isComplex ? 3500 : 1200
        ]
        if !isComplex {
            body["thinking"] = ["type": "disabled"]
        }
        if let params = toolParameters {
            body["tools"] = [[
                "type": "function",
                "function": [
                    "name": PlanToolSchema.functionName,
                    "description": PlanToolSchema.description,
                    "parameters": params
                ]
            ]]
            body["tool_choice"] = ["type": "function", "function": ["name": PlanToolSchema.functionName]]
        }
        return body
    }
    
    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph {
        guard !apiKey.isEmpty else {
            throw PlannerError.llmError("NVIDIA Build non configurato. Imposta la tua API key nelle impostazioni.")
        }
        

        let requestBody = Self.makeBody(
            prompt: prompt,
            isComplex: isComplex,
            model: model,
            toolParameters: toolIds.isEmpty ? nil : PlanToolSchema.parametersJSON(toolIds: toolIds)
        )

        
        guard let url = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions") else {
            throw PlannerError.llmError("URL NVIDIA Build non valido")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = httpRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let maxAttempts = 3
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                guard let networkError = error as? URLError, attempt < maxAttempts else {
                    throw error
                }
                switch networkError.code {
                case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                     .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                     .resourceUnavailable:
                    break
                default:
                    throw error
                }
                try await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            try Task.checkCancellation()
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PlannerError.llmError("Nessuna risposta da NVIDIA Build")
            }
            let status = httpResponse.statusCode
            if (status == 429 || (500...599).contains(status)), attempt < maxAttempts {
                try await Task.sleep(nanoseconds: 1_200_000_000)
                continue
            }
            guard status == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                throw PlannerError.llmError("Errore NVIDIA Build (HTTP \(status)): \(body)")
            }
            guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = jsonObject["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any] else {
                throw PlannerError.invalidResponse
            }
            return try PlanResponseParser.parseOpenAIMessage(message)
        }
    }
}

// MARK: - OpenAI-Compatible Provider (OpenCode, GLM-5.2, LM Studio, etc.)

struct OpenAICompatibleModelProvider: ModelProvider {
    var baseURL: String
    var model: String
    var apiKey: String
    /// ID dei tool registrati; vuoto = nessun tool calling (payload legacy).
    var toolIds: [String] = []

    init(baseURL: String, model: String, apiKey: String, toolIds: [String] = []) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.toolIds = toolIds
    }

    /// Body-builder testabile. Con `toolParameters == nil` il payload è
    /// identico al flusso prompt-JSON storico.
    static func makeBody(prompt: String, isComplex: Bool, model: String,
                         toolParameters: [String: Any]?) -> [String: Any] {
        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": """
                You are Atlas, a filesystem automation assistant.
                You MUST translate the user request into a raw valid JSON object with a top-level "steps" array.
                Example valid schema:
                {
                  "steps": [
                    {
                      "id": "step_1",
                      "tool": "image.convert",
                      "inputs": ["file1.png"],
                      "format": "jpg"
                    }
                  ]
                }
                CRITICAL: Output ONLY the raw JSON starting with { and ending with }. Do NOT write any markdown fences, conversational intro, reasoning tags, or explanations!
                """
            ],
            [
                "role": "user",
                "content": prompt
            ]
        ]

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.0,
            "max_tokens": isComplex ? 3500 : 1200
        ]
        if !isComplex {
            body["thinking"] = ["type": "disabled"]
            body["reasoning_effort"] = "low"
        }
        if let params = toolParameters {
            // Tool calling attivo: response_format json_object è ridondante e
            // alcuni endpoint rifiutano la combinazione.
            body["tools"] = [[
                "type": "function",
                "function": [
                    "name": PlanToolSchema.functionName,
                    "description": PlanToolSchema.description,
                    "parameters": params
                ]
            ]]
            body["tool_choice"] = ["type": "function", "function": ["name": PlanToolSchema.functionName]]
        } else {
            body["response_format"] = ["type": "json_object"]
        }
        return body
    }
    
    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph {
        guard !baseURL.isEmpty else {
            throw PlannerError.llmError("Provider custom non configurato. Imposta il Base URL nelle impostazioni.")
        }
        
        let activeModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "local-model" : model
        
        // Normalize the base URL: strip trailing slash, ensure we call /chat/completions
        let normalizedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        let urlString = normalizedBase.hasSuffix("/chat/completions")
            ? normalizedBase
            : normalizedBase + "/chat/completions"
        
        guard let url = URL(string: urlString) else {
            throw PlannerError.llmError("Base URL non valido: \(baseURL)")
        }
        

        let requestBody = Self.makeBody(
            prompt: prompt,
            isComplex: isComplex,
            model: activeModel,
            toolParameters: toolIds.isEmpty ? nil : PlanToolSchema.parametersJSON(toolIds: toolIds)
        )

        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = httpRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlannerError.llmError("Nessuna risposta dal provider custom: \(baseURL)")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PlannerError.llmError("Errore provider custom (HTTP \(httpResponse.statusCode)): \(body)")
        }
        
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = jsonObject["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw PlannerError.invalidResponse
        }

        return try PlanResponseParser.parseOpenAIMessage(message)
    }
}

// MARK: - OpenCode AI (Zen) Provider

struct OpenCodeModelProvider: ModelProvider {
    var apiKey: String
    var model: String
    /// ID dei tool registrati; vuoto = nessun tool calling (payload legacy).
    var toolIds: [String] = []

    init(apiKey: String, model: String = "deepseek-v4-flash-free", toolIds: [String] = []) {
        self.apiKey = apiKey
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "deepseek-v4-flash-free" : model
        self.toolIds = toolIds
    }

    /// Body-builder testabile. Con `toolParameters == nil` il payload è
    /// identico al flusso prompt-JSON storico.
    static func makeBody(prompt: String, isComplex: Bool, model: String,
                         toolParameters: [String: Any]?) -> [String: Any] {
        let messages: [[String: Any]] = [
            [
                "role": "system",
                "content": """
                You are Atlas, a filesystem automation assistant.
                You MUST output ONLY a raw JSON object starting with { and ending with }.
                Do NOT output any conversational text, thinking, or introduction before the JSON!
                Example valid schema:
                {
                  "steps": [
                    {
                      "id": "step_1",
                      "tool": "file.select",
                      "inputs": ["foto_1.jpg"]
                    }
                  ]
                }
                """
            ],
            [
                "role": "user",
                "content": prompt
            ]
        ]

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
            "temperature": 0.0,
            "max_tokens": isComplex ? 3500 : 2500,
            "reasoning_effort": isComplex ? "medium" : "low"
        ]
        if let params = toolParameters {
            // Tool calling attivo: response_format json_object è ridondante e
            // alcuni endpoint rifiutano la combinazione.
            body["tools"] = [[
                "type": "function",
                "function": [
                    "name": PlanToolSchema.functionName,
                    "description": PlanToolSchema.description,
                    "parameters": params
                ]
            ]]
            body["tool_choice"] = ["type": "function", "function": ["name": PlanToolSchema.functionName]]
        } else {
            body["response_format"] = ["type": "json_object"]
        }
        return body
    }
    
    func plan(prompt: String, isComplex: Bool) async throws -> ActionGraph {
        guard !apiKey.isEmpty else {
            throw PlannerError.llmError("OpenCode AI non configurato. Inserisci la tua API Key (opencode.ai/auth) nelle impostazioni.")
        }
        
        let urlString = "https://opencode.ai/zen/v1/chat/completions"
        guard let url = URL(string: urlString) else {
            throw PlannerError.llmError("URL OpenCode non valido")
        }
        

        let requestBody = Self.makeBody(
            prompt: prompt,
            isComplex: isComplex,
            model: model,
            toolParameters: toolIds.isEmpty ? nil : PlanToolSchema.parametersJSON(toolIds: toolIds)
        )

        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = httpRequestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            // Retry una volta: l'endpoint Zen può essere lento sotto carico
            try await Task.sleep(nanoseconds: 2_000_000_000)
            (data, response) = try await URLSession.shared.data(for: request)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlannerError.llmError("Nessuna risposta da OpenCode AI")
        }
        
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PlannerError.llmError("Errore OpenCode AI (HTTP \(httpResponse.statusCode)): \(body)")
        }
        
        guard let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = jsonObject["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            throw PlannerError.decodingFailed("Formato risposta da OpenCode AI non riconosciuto.\n\nTesto grezzo dal server:\n\(rawBody)")
        }
        
        // Il modello Zen può lasciare content vuoto e mettere tutto in
        // reasoning_content: promuoviamolo prima del parser condiviso.
        var effectiveMessage = message
        if message["tool_calls"] == nil,
           ((message["content"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let reasoning = message["reasoning_content"] as? String {
            effectiveMessage["content"] = reasoning
        }

        return try PlanResponseParser.parseOpenAIMessage(effectiveMessage)
    }
}
