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
    let message: String
    
    var fraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(stepIndex) / Double(totalSteps)
    }
}

@MainActor
class ExecutorFramework {
    
    func execute(graph: ActionGraph, context: FinderContext, query: String? = nil, progress: @escaping (ProgressUpdate) -> Void = { _ in }) async throws -> AtlasTransaction {
        // Difensivo: riordina gli step per dipendenze anche se il planner ha saltato il sort
        let graph = try graph.topologicallySorted()
        var transaction = AtlasTransaction(steps: graph.steps)
        transaction.query = query
        
        // Gli step arrivano già ordinati topologicamente
        for (index, step) in graph.steps.enumerated() {
            guard let capability = ToolRegistry.shared.capability(for: step.tool) else {
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = "Tool non trovato: \(step.tool)"
                HistoryStore.shared.record(transaction)
                throw ExecutorError.toolNotFound(step.tool)
            }
            
            let executor = capability.executor
            
            progress(ProgressUpdate(
                stepIndex: index,
                totalSteps: graph.steps.count,
                message: "Validazione dello step \(index + 1)/\(graph.steps.count): \(step.tool)"
            ))
            
            do {
                // 1. Validation
                try executor.validate(step: step, context: context)
            } catch {
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = error.localizedDescription
                HistoryStore.shared.record(transaction)
                throw error
            }
            
            progress(ProgressUpdate(
                stepIndex: index,
                totalSteps: graph.steps.count,
                message: "Esecuzione step \(index + 1)/\(graph.steps.count): \(step.tool)"
            ))
            
            // 2. Execution
            let result: ActionResult
            do {
                result = try await executor.execute(step: step, context: context)
            } catch {
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = error.localizedDescription
                HistoryStore.shared.record(transaction)
                throw error
            }
            
            if !result.success {
                transaction.status = .failed
                transaction.completedAt = Date()
                transaction.resultMessage = result.message ?? "Errore sconosciuto durante \(step.tool)"
                HistoryStore.shared.record(transaction)
                throw ExecutorError.executionFailed(result.message ?? "Unknown error during execution of \(step.tool)")
            }
            
            for file in result.outputFiles {
                transaction.addCreated(url: file)
            }
            for (original, backup) in result.backupURLs {
                transaction.addBackup(original: original, backup: backup)
            }
            transaction.resultMessage = result.message ?? transaction.resultMessage
        }
        
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
