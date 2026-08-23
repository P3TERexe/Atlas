import Foundation
import SwiftUI

/// View-model della palette comandi: possiede la pipeline
/// planner → executor e lo stato osservabile dalla UI.
@MainActor
final class PaletteViewModel: ObservableObject {
    // Stato UI-driven esportato
    @Published var query: String = ""
    @Published var isExecuting: Bool = false
    @Published var plannedGraph: ActionGraph? = nil
    @Published var executionMessage: String? = nil
    @Published var lastTransaction: AtlasTransaction? = nil
    @Published var progress: ProgressUpdate? = nil

    // Pannelli secondari (Cronologia / Guida / Debug)
    @Published var showDebug: Bool = false
    @Published var showHistory: Bool = false
    @Published var showHelp: Bool = false

    // Contesto Finder corrente (banner + preview)
    @Published var cachedContext: FinderContext?

    // Ultimo scambio col planner, per il DebugPanel
    @Published var lastPrompt: String?
    @Published var lastResponse: String?

    // Servizi
    private let contextProvider = FinderContextProvider()
    private let planner = Planner()
    private let executor = ExecutorFramework()

    private var currentTask: Task<Void, Never>? = nil

    // Terminal-style command history — backed by CommandHistoryStore (persistent)
    private let commandHistoryStore = CommandHistoryStore.shared
    private var historyIndex: Int = -1
    private var savedDraft: String = ""

    func refreshContext() async {
        cachedContext = await contextProvider.getCurrentContext()
    }

    enum HistoryDirection { case up, down }

    func navigateHistory(direction: HistoryDirection) {
        let commandHistory = commandHistoryStore.history
        guard !commandHistory.isEmpty else { return }

        switch direction {
        case .up:
            if historyIndex == -1 {
                savedDraft = query
                historyIndex = commandHistory.count - 1
            } else if historyIndex > 0 {
                historyIndex -= 1
            }
            query = commandHistory[historyIndex]

        case .down:
            if historyIndex == -1 { return }
            if historyIndex < commandHistory.count - 1 {
                historyIndex += 1
                query = commandHistory[historyIndex]
            } else {
                historyIndex = -1
                query = savedDraft
            }
        }
    }

    private func saveToHistory(_ text: String) {
        commandHistoryStore.append(text)
        historyIndex = -1
        savedDraft = ""
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        withAnimation {
            isExecuting = false
            progress = nil
        }
        executionMessage = "⚠︎ Operazione annullata dall'utente."
    }

    func clearDebugLog() {
        planner.clearLog()
        lastPrompt = nil
        lastResponse = nil
    }

    func executeCommand() {
        guard !query.isEmpty else { return }
        saveToHistory(query)
        isExecuting = true
        progress = ProgressUpdate(stepIndex: 0, totalSteps: 1, message: "Analizzo la richiesta con \(AppSettings.shared.defaultProvider.rawValue)...")
        executionMessage = nil
        plannedGraph = nil
        showHistory = false

        currentTask = Task { @MainActor in
            // Fetch fresh context once, off the main thread, then reuse it for planning
            print("[Atlas][UI] ▶ planning start query=\"\(query)\"")
            let context = await contextProvider.getCurrentContext()
            print("[Atlas][UI] context dir=\(context.currentDirectory?.path ?? "nil") selected=\(context.selectedFiles.count) visible=\(context.visibleFiles.count)")
            guard !Task.isCancelled else { return }
            self.cachedContext = context

            do {
                planner.activeProvider = AppSettings.shared.defaultProvider
                let graph = try await planner.plan(query: query, context: context)
                lastPrompt = planner.lastPrompt
                lastResponse = planner.lastResponse
                print("[Atlas][UI] plan ok steps=\(graph.steps.count) \(planner.lastResponse ?? "")")
                guard !Task.isCancelled else { return }

                let assessment = RiskAssessment.analyze(graph: graph, context: context)
                if assessment.riskLevel == .none {
                    // Instant 0ms execution for zero risk operations (file.select, shell.calc, read-only)
                    self.executeGraph(graph)
                } else {
                    self.plannedGraph = graph
                    withAnimation { self.isExecuting = false }
                    self.progress = nil
                }
            } catch is CancellationError {
                // Silently handled — cancelCurrentTask() already updated UI
                print("[Atlas][UI] planning cancelled")
            } catch {
                print("[Atlas][UI] ❌ planning error: \(error.localizedDescription)")
                guard !Task.isCancelled else { return }
                withAnimation { self.isExecuting = false }
                self.progress = nil
                self.executionMessage = "❌ Errore durante la pianificazione (\(AppSettings.shared.defaultProvider.rawValue)):\n\(error.localizedDescription)"
                self.showDebug = true
            }
        }
    }

    func executeGraph(_ graph: ActionGraph) {
        isExecuting = true
        progress = ProgressUpdate(stepIndex: 0, totalSteps: graph.steps.count, message: "Inizializzazione esecuzione...")
        plannedGraph = nil

        currentTask = Task { @MainActor in
            // Fetch fresh context once, off the main thread, then reuse it for execution
            print("[Atlas][UI] ▶ execution start steps=\(graph.steps.count)")
            let context = await contextProvider.getCurrentContext()
            print("[Atlas][UI] exec context dir=\(context.currentDirectory?.path ?? "nil") selected=\(context.selectedFiles.count) visible=\(context.visibleFiles.count)")
            guard !Task.isCancelled else { return }
            self.cachedContext = context

            do {
                let transaction = try await executor.execute(graph: graph, context: context, query: query) { update in
                    guard !Task.isCancelled else { return }
                    self.progress = update
                }
                print("[Atlas][UI] ✓ execution done status=\(transaction.status.rawValue) created=\(transaction.createdURLs.count)")
                guard !Task.isCancelled else { return }
                withAnimation { self.isExecuting = false }
                self.progress = nil
                self.lastTransaction = transaction
                self.cachedContext = nil // Refresh cache for next run
                let created = transaction.createdURLs.count
                self.executionMessage = created > 0
                    ? "✓ \(transaction.steps.count) step completati — \(created) file creati."
                    : "✓ Eseguiti \(transaction.steps.count) step con successo."
            } catch is CancellationError {
                // Silently handled — cancelCurrentTask() already updated UI
                print("[Atlas][UI] execution cancelled")
            } catch {
                print("[Atlas][UI] ❌ execution error: \(error.localizedDescription)")
                guard !Task.isCancelled else { return }
                withAnimation { self.isExecuting = false }
                self.progress = nil
                self.executionMessage = "❌ Errore durante l'esecuzione:\n\(error.localizedDescription)"
                self.showDebug = true
            }
        }
    }
}
