import Foundation

enum PlannerError: Error, LocalizedError {
    case invalidResponse
    case decodingFailed(String)
    case llmError(String)
    case validationFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Risposta non valida dal modello."
        case .decodingFailed(let msg):
            return "Errore di decodifica JSON: \(msg)"
        case .llmError(let msg):
            return msg
        case .validationFailed(let msg):
            return "Controllo di aderenza alla richiesta fallito: \(msg)"
        }
    }
}

@MainActor
class Planner {
    let promptBuilder = PromptBuilder()
    var activeProvider: AIProvider = AppSettings.shared.defaultProvider
    private(set) var lastPrompt: String?
    private(set) var lastResponse: String?
    
    func plan(query: String, context: FinderContext) async throws -> ActionGraph {
        // ⚡ Phase 1: Try Instant Action Parser (0ms local execution without LLM latency)
        if let instantGraph = InstantActionParser.parse(query: query, context: context) {
            lastPrompt = "[INSTANT LOCAL PARSER (0ms)]"
            lastResponse = "⚡ Piano locale istantaneo generato (0ms)"
            return instantGraph
        }
        
        let isSmallContextModel = activeProvider == .apple || activeProvider == .ollama
        let initialPrompt = isSmallContextModel
            ? promptBuilder.buildCompactPrompt(query: query, context: context)
            : promptBuilder.buildPrompt(query: query, context: context)
            
        lastPrompt = initialPrompt
        lastResponse = nil
        
        let settings = AppSettings.shared
        let provider: any ModelProvider = switch activeProvider {
        case .apple:
            AppleModelProvider()
        case .opencode:
            OpenCodeModelProvider(apiKey: settings.openCodeApiKey, model: settings.openCodeModel)
        case .ollama:
            OllamaModelProvider(endpoint: settings.ollamaEndpoint, model: settings.ollamaModel)
        case .openai:
            OpenAIModelProvider(apiKey: settings.openAIApiKey)
        case .claude:
            ClaudeModelProvider(apiKey: settings.claudeApiKey)
        case .nvidia:
            NvidiaModelProvider(apiKey: settings.nvidiaApiKey, model: settings.nvidiaModel)
        case .openaiCompatible:
            OpenAICompatibleModelProvider(baseURL: settings.customBaseURL, model: settings.customModel, apiKey: settings.customApiKey)
        }
        
        // Attempt 1: Standard generation
        do {
            let graph = try await provider.plan(prompt: initialPrompt)
            let sorted = try graph.topologicallySorted()
            
            // Validation Pass 1
            do {
                try PlanValidator.validate(graph: sorted, query: query, context: context)
                lastResponse = "✓ Piano generato e verificato (\(sorted.steps.count) step)"
                return sorted
            } catch let validationError {
                // Attempt 2: Self-correction retry prompt
                let retryPrompt = """
                \(initialPrompt)
                
                ATTENTION - PREVIOUS PLAN VALIDATION FAILED:
                \(validationError.localizedDescription)
                Please fix your JSON plan so it strictly adheres to the user request and uses valid tools/formats.
                """
                lastPrompt = retryPrompt
                
                let secondGraph = try await provider.plan(prompt: retryPrompt)
                let secondSorted = try secondGraph.topologicallySorted()
                try PlanValidator.validate(graph: secondSorted, query: query, context: context)
                
                lastResponse = "✓ Piano rigenerato e verificato dopo correzione automatic (\(secondSorted.steps.count) step)"
                return secondSorted
            }
        } catch {
            lastResponse = "❌ ERRORE: \(error.localizedDescription)"
            throw error
        }
    }
    
    func clearLog() {
        lastPrompt = nil
        lastResponse = nil
    }
}
