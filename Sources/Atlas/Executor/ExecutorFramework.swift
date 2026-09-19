import Foundation

enum ExecutorError: Error, LocalizedError {
    case toolNotFound(String)
    case validationFailed(String)
    case executionFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            return "Tool non trovato: \(tool)"
        case .validationFailed(let msg):
            return "Validazione fallita: \(msg)"
        case .executionFailed(let msg):
            return msg
        }
    }
}

struct ProgressUpdate: Sendable {
    let stepIndex: Int
    let totalSteps: Int
    let itemIndex: Int
    let totalItems: Int
    let message: String
    let detail: String?
    
    init(stepIndex: Int, totalSteps: Int, itemIndex: Int = 0, totalItems: Int = 1, message: String, detail: String? = nil) {
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.itemIndex = itemIndex
        self.totalItems = totalItems
        self.message = message
        self.detail = detail
    }
    
    var fraction: Double {
        guard totalSteps > 0 else { return 0.05 }
        let stepWeight = 1.0 / Double(totalSteps)
        let base = Double(stepIndex) * stepWeight
        let subProgress = totalItems > 0 ? (Double(itemIndex) / Double(totalItems)) : 0.0
        return min(0.99, base + (stepWeight * subProgress))
    }
}

@MainActor
class ExecutorFramework {
    
    func execute(graph: ActionGraph, context: FinderContext, query: String? = nil, progress: @escaping (ProgressUpdate) -> Void = { _ in }) async throws -> AtlasTransaction {
        // Il callback per-item arriva da contesti off-main (plugin nonisolated):
        // il bridge garantisce la consegna sul main actor
        let progressBridge = ProgressBridge(handler: progress)
        // Difensivo: riordina gli step per dipendenze anche se il planner ha saltato il sort
        let graph = try graph.topologicallySorted()
        var transaction = AtlasTransaction(steps: graph.steps)
        transaction.query = query
        
        var outputsByStep: [String: [URL]] = [:]
        var runningContext = context

        // Gli step arrivano già ordinati topologicamente
        for (index, step) in graph.steps.enumerated() {
            var effectiveStep = step
            if effectiveStep.inputs.isEmpty, let deps = effectiveStep.dependsOn, !deps.isEmpty {
                let predecessorOutputs = deps.flatMap { outputsByStep[$0] ?? [] }
                if !predecessorOutputs.isEmpty {
                    effectiveStep.inputs = predecessorOutputs.map(\.path)
                }
            }

            print("[Atlas][Executor] ▶ Step \(index + 1)/\(graph.steps.count): \(effectiveStep.tool) format=\(effectiveStep.format ?? "nil") inputs=\(effectiveStep.inputs)")
            guard let capability = ToolRegistry.shared.capability(for: effectiveStep.tool) else {
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = "Tool non trovato: \(effectiveStep.tool)"
                HistoryStore.shared.record(transaction)
                AtlasUndoManager.shared.register(transaction: transaction)
                throw ExecutorError.toolNotFound(effectiveStep.tool)
            }
            
            let executor = capability.executor
            
            progress(ProgressUpdate(
                stepIndex: index,
                totalSteps: graph.steps.count,
                itemIndex: 0,
                totalItems: 1,
                message: "Validazione dello step \(index + 1)/\(graph.steps.count): \(effectiveStep.tool)",
                detail: "Verifica prerequisiti..."
            ))
            
            do {
                // 1. Validation
                try executor.validate(step: effectiveStep, context: runningContext)
            } catch {
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = error.localizedDescription
                HistoryStore.shared.record(transaction)
                AtlasUndoManager.shared.register(transaction: transaction)
                throw error
            }
            
            progress(ProgressUpdate(
                stepIndex: index,
                totalSteps: graph.steps.count,
                itemIndex: 0,
                totalItems: 1,
                message: "Esecuzione step \(index + 1)/\(graph.steps.count): \(effectiveStep.tool)",
                detail: "Avvio operazioni..."
            ))
            
            // 2. Execution with sub-item real-time progress updates
            let currentStep = effectiveStep
            let result: ActionResult
            do {
                result = try await executor.execute(step: currentStep, context: runningContext) { itemIdx, totalItems, detailMsg in
                    progressBridge.send(ProgressUpdate(
                        stepIndex: index,
                        totalSteps: graph.steps.count,
                        itemIndex: itemIdx,
                        totalItems: totalItems,
                        message: "Step \(index + 1)/\(graph.steps.count): \(currentStep.tool)",
                        detail: detailMsg
                    ))
                }
            } catch {
                let underlying: Error
                if let partial = error as? ActionExecutionError {
                    transaction.incorporate(partial.partialResult)
                    underlying = partial.underlying
                } else {
                    underlying = error
                }
                print("[Atlas][Executor] ✗ Step \(index + 1)/\(graph.steps.count) fallito: \(error)")
                progressBridge.finish()
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = underlying.localizedDescription
                HistoryStore.shared.record(transaction)
                AtlasUndoManager.shared.register(transaction: transaction)
                throw underlying
            }
            print("[Atlas][Executor] ✓ Step \(index + 1)/\(graph.steps.count) completato: \(result.outputFiles.count) file")
            outputsByStep[step.id] = result.outputFiles
            runningContext = FinderContext(
                currentDirectory: runningContext.currentDirectory,
                selectedFiles: runningContext.selectedFiles,
                visibleFiles: runningContext.visibleFiles + result.outputFiles,
                installedTools: runningContext.installedTools,
                timestamp: Date()
            )
            transaction.incorporate(result)
            
            if !result.success {
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = result.message ?? "Errore sconosciuto durante \(step.tool)"
                HistoryStore.shared.record(transaction)
                AtlasUndoManager.shared.register(transaction: transaction)
                throw ExecutorError.executionFailed(result.message ?? "Unknown error during execution of \(step.tool)")
            }
            
        }
        progressBridge.finish()
        
        transaction.status = .success
        transaction.completedAt = Date()
        transaction.summary = graph.steps.count == 1
            ? (graph.steps.first?.tool ?? "operazione")
            : "\(graph.steps.count) operazioni: \(graph.steps.map { $0.tool }.joined(separator: " → "))"
        
        HistoryStore.shared.record(transaction)
        AtlasUndoManager.shared.register(transaction: transaction)
        return transaction
    }
}
/// Serializes progress updates from plugin threads and delivers them to the
/// main actor at most every 50 ms; finish() flushes the last update before
/// execute() returns so the UI never shows a stale step.
private final class ProgressBridge: @unchecked Sendable {
    private let handler: (ProgressUpdate) -> Void
    private let queue = DispatchQueue(label: "atlas.progressbridge", qos: .userInitiated)
    private var latest: ProgressUpdate?
    private var pending = false
    private var lastSent = Date.distantPast
    private var finished = false

    init(handler: @escaping (ProgressUpdate) -> Void) {
        self.handler = handler
    }

    func send(_ update: ProgressUpdate) {
        queue.async {
            guard !self.finished else { return }
            self.latest = update
            guard !self.pending else { return }
            let elapsed = Date().timeIntervalSince(self.lastSent)
            if elapsed >= 0.05 {
                self.deliverNow()
            } else {
                self.pending = true
                self.queue.asyncAfter(deadline: .now() + (0.05 - elapsed)) { [weak self] in
                    guard let self, !self.finished else { return }
                    self.pending = false
                    self.deliverNow()
                }
            }
        }
    }

    func finish() {
        queue.async {
            self.finished = true
            self.pending = false
            self.deliverNow()
        }
    }

    private func deliverNow() {
        guard let update = latest else { return }
        latest = nil
        lastSent = Date()
        Task { @MainActor in
            self.handler(update)
        }
    }
}

