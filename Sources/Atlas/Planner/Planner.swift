import Foundation

struct QueryComplexity: Sendable {
    let isComplex: Bool
    let reason: String?
}

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
    
    static func analyzeComplexity(query: String) -> QueryComplexity {
        let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return QueryComplexity(isComplex: false, reason: nil) }
        
        // Language-Agnostic Structural Detection:
        // 1. Multiple clause separators (semicolons, conjunction words like ' e ', ' ed ', ' and ', ' poi ', ' then ', ' dopo ')
        let conjunctionRegex = try? NSRegularExpression(pattern: #"\b(e|ed|and|poi|then|dopo)\b|[;|\n]"#, options: [.caseInsensitive])
        let conjunctionMatches = conjunctionRegex?.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)).count ?? 0
        
        // 2. Numerical repetition / count requests in any language (e.g. "7 copies", "10 volte", "3 files", "5x", "100MB")
        let hasNumberPattern = lower.range(of: "\\b\\d+\\b", options: .regularExpression) != nil
        
        // 3. Multi-word queries with sequence structure or long word count
        let words = lower.components(separatedBy: .whitespacesAndNewlines).filter({ !$0.isEmpty })
        let wordCount = words.count
        
        let isMultiClause = conjunctionMatches > 0 || (hasNumberPattern && wordCount > 4)
        
        if isMultiClause || wordCount > 15 {
            return QueryComplexity(
                isComplex: true,
                reason: "Query con sequenza di azioni o parametri numerici"
            )
        }
        
        return QueryComplexity(isComplex: false, reason: nil)
    }
    
    func plan(query: String, context: FinderContext) async throws -> ActionGraph {
        let startTime = CFAbsoluteTimeGetCurrent()
        let activeRules = RulesStore.shared.activeRules(for: query, currentFolder: context.currentDirectory?.path)
        if activeRules.isEmpty, let instantGraph = InstantActionParser.parse(query: query, context: context) {
            let sorted = try instantGraph.topologicallySorted()
            try PlanValidator.validate(graph: sorted, query: query, context: context)
            lastPrompt = "[INSTANT LOCAL PARSER (0ms)]"
            lastResponse = "Piano generato; strumenti e input controllati"
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            print("[Atlas][Planner] ⚡ instant parser hit in \(String(format: "%.3f", duration))s: tool=\(instantGraph.steps.first?.tool ?? "?") inputs=\(instantGraph.steps.first?.inputs.count ?? 0)")
            return sorted
        }
        print("[Atlas][Planner] ⚡ instant parser MISS → LLM path (visibleFiles=\(context.visibleFiles.count) selected=\(context.selectedFiles.count) dir=\(context.currentDirectory?.path ?? "nil"))")
        
        let rawComplexity = Self.analyzeComplexity(query: query)
        let isComplex = AppSettings.shared.disableThinking ? false : rawComplexity.isComplex
        let initialPrompt = activeRules.isEmpty
            ? promptBuilder.buildCompactPrompt(query: query, context: context)
            : promptBuilder.buildPrompt(query: query, context: context)
            
        lastPrompt = initialPrompt
        lastResponse = nil
        
        let settings = AppSettings.shared
        let toolIds = ToolRegistry.shared.allToolIds
        let provider: any ModelProvider = switch activeProvider {
        case .apple:
            AppleModelProvider()
        case .opencode:
            OpenCodeModelProvider(apiKey: settings.openCodeApiKey, model: settings.openCodeModel, toolIds: toolIds, disableThinking: settings.disableThinking)
        case .ollama:
            OllamaModelProvider(endpoint: settings.ollamaEndpoint, model: settings.ollamaModel, toolIds: toolIds, disableThinking: settings.disableThinking)
        case .openai:
            OpenAIModelProvider(apiKey: settings.openAIApiKey, toolIds: toolIds)
        case .claude:
            ClaudeModelProvider(apiKey: settings.claudeApiKey, toolIds: toolIds)
        case .nvidia:
            NvidiaModelProvider(apiKey: settings.nvidiaApiKey, model: settings.nvidiaModel, toolIds: toolIds, disableThinking: settings.disableThinking)
        case .openaiCompatible:
            OpenAICompatibleModelProvider(baseURL: settings.customBaseURL, model: settings.customModel, apiKey: settings.customApiKey, toolIds: toolIds, disableThinking: settings.disableThinking)
        }
        
        do {
            // Transport, authentication and decode errors do not enter correction.
            let graph = try await provider.plan(prompt: initialPrompt, isComplex: isComplex)
            try Task.checkCancellation()
            do {
                let sorted = try graph.topologicallySorted()
                try PlanValidator.validate(graph: sorted, query: query, context: context)
                lastResponse = "Piano generato; strumenti e input controllati"
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                print("[Atlas][Planner] ⏱ LLM plan completed in \(String(format: "%.2f", duration))s")
                return sorted
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                let rejectedJSON = String(decoding: try JSONEncoder().encode(graph), as: UTF8.self)
                let retryPrompt = """
                \(initialPrompt)

                ATTENTION - PREVIOUS PLAN VALIDATION FAILED:
                \(error.localizedDescription)
                REJECTED PLAN JSON:
                \(rejectedJSON)
                Correct the rejected plan, including dependency order, tools, formats and inputs. Return only the corrected plan.
                """
                lastPrompt = retryPrompt
                let secondGraph = try await provider.plan(prompt: retryPrompt, isComplex: isComplex)
                try Task.checkCancellation()
                let secondSorted = try secondGraph.topologicallySorted()
                try PlanValidator.validate(graph: secondSorted, query: query, context: context)
                lastResponse = "Piano generato; strumenti e input controllati"
                let duration = CFAbsoluteTimeGetCurrent() - startTime
                print("[Atlas][Planner] ⏱ LLM plan retry completed in \(String(format: "%.2f", duration))s")
                return secondSorted
            }
        } catch {
            if case PlannerError.llmError(let detail) = error {
                let lower = detail.lowercased()
                let contextLimitMarkers = ["context_length_exceeded", "context window", "maximum context length", "prompt too long", "input too long", "http 413"]
                if contextLimitMarkers.contains(where: lower.contains) {
                    let contextError = PlannerError.llmError("\(detail)\nIl provider ha rifiutato il contesto troppo lungo. Riduci la selezione o scegli un provider con un contesto maggiore.")
                    lastResponse = "ERRORE: \(contextError.localizedDescription)"
                    throw contextError
                }
            }
            lastResponse = "ERRORE: \(error.localizedDescription)"
            throw error
        }
    }
    
    func clearLog() {
        lastPrompt = nil
        lastResponse = nil
    }
}
