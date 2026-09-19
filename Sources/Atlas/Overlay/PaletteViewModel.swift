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
    struct PendingOperation {
        let id: UUID
        let query: String
        let graph: ActionGraph
        let context: FinderContext
    }
    @Published var progress: ProgressUpdate? = nil
    @Published private(set) var pendingOperation: PendingOperation?

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
        guard pendingOperation == nil, !isExecuting else { return }
        cachedContext = try? await contextProvider.getCurrentContext()
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
        executionMessage = "⚠︎ Annullamento in corso…"
    }

    func clearDebugLog() {
        planner.clearLog()
        lastPrompt = nil
        lastResponse = nil
    }

    func executeCommand() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard currentTask == nil else { return }
        let query = self.query
        saveToHistory(query)
        isExecuting = true
        progress = ProgressUpdate(stepIndex: 0, totalSteps: 1, message: "Analizzo la richiesta con \(AppSettings.shared.defaultProvider.rawValue)...")
        executionMessage = nil
        plannedGraph = nil
        showHistory = false

        let id = UUID()
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.currentTask = nil }
            print("[Atlas][UI] ▶ planning start query=\"\(query)\"")
            let context: FinderContext
            do {
                context = try await self.contextProvider.getCurrentContext()
            } catch {
                self.failPlanning(id: id, message: error.localizedDescription)
                return
            }
            print("[Atlas][UI] context dir=\(context.currentDirectory?.path ?? "nil") selected=\(context.selectedFiles.count) visible=\(context.visibleFiles.count)")
            guard !Task.isCancelled else { return }
            self.cachedContext = context

            do {
                self.planner.activeProvider = AppSettings.shared.defaultProvider
                let graph = try await self.planner.plan(query: query, context: context)
                self.lastPrompt = self.planner.lastPrompt
                self.lastResponse = self.planner.lastResponse
                print("[Atlas][UI] plan ok steps=\(graph.steps.count) \(self.planner.lastResponse ?? "")")
                guard !Task.isCancelled else { return }

                let assessment = RiskAssessment.analyze(graph: graph, context: context)
                if assessment.riskLevel == .none {
                    self.admit(PendingOperation(id: id, query: query, graph: graph, context: context))
                    self.run(pending: self.pendingOperation)
                } else {
                    self.admit(PendingOperation(id: id, query: query, graph: graph, context: context))
                    withAnimation {
                        self.plannedGraph = graph
                        self.isExecuting = false
                    }
                    self.progress = nil
                }
            } catch is CancellationError {
                print("[Atlas][UI] planning cancelled")
            } catch {
                self.failPlanning(id: id, message: error.localizedDescription)
            }
        }
    }

    /// Freezes the admitted query/graph/context triple. Context refresh cannot
    /// replace it, and confirm/auto-run always executes exactly this snapshot.
    private func admit(_ operation: PendingOperation) {
        pendingOperation = operation
    }

    private func failPlanning(id: UUID, message: String) {
        guard pendingOperation?.id == id || pendingOperation == nil else { return }
        withAnimation { isExecuting = false }
        progress = nil
        executionMessage = "❌ Errore durante la pianificazione (\(AppSettings.shared.defaultProvider.rawValue)):\n\(message)"
        showDebug = true
    }

    func executeGraph(_ graph: ActionGraph) {
        guard currentTask == nil else { return }
        // The confirmed pending snapshot is authoritative; never re-read Finder.
        let pending = pendingOperation
        let context = pending?.context ?? cachedContext
        guard let context else {
            isExecuting = false
            executionMessage = "❌ Contesto Finder non disponibile."
            return
        }
        let query = pending?.query ?? self.query
        isExecuting = true
        progress = ProgressUpdate(stepIndex: 0, totalSteps: graph.steps.count, message: "Inizializzazione esecuzione...")
        plannedGraph = nil

        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.currentTask = nil; self.pendingOperation = nil }
            print("[Atlas][UI] ▶ execution start steps=\(graph.steps.count)")
            guard !Task.isCancelled else { return }
            self.cachedContext = context

            do {
                let transaction = try await self.executor.execute(graph: graph, context: context, query: query) { update in
                    guard !Task.isCancelled else { return }
                    self.progress = update
                }
                print("[Atlas][UI] ✓ execution done status=\(transaction.status.rawValue) created=\(transaction.createdURLs.count)")
                guard !Task.isCancelled else { return }
                withAnimation { self.isExecuting = false }
                self.progress = nil
                self.lastTransaction = transaction
                self.cachedContext = nil
                let created = transaction.createdURLs.count
                self.executionMessage = created > 0
                    ? "✓ \(transaction.steps.count) step completati — \(created) file creati."
                    : "✓ Eseguiti \(transaction.steps.count) step con successo."
            } catch is CancellationError {
                print("[Atlas][UI] execution cancelled")
            } catch {
                guard !Task.isCancelled else { return }
                print("[Atlas][UI] ❌ execution error: \(error.localizedDescription)")
                withAnimation { self.isExecuting = false }
                self.progress = nil
                self.executionMessage = "❌ Errore durante l'esecuzione:\n\(error.localizedDescription)"
                self.showDebug = true
            }
        }
    }

    /// Confirmation path: executes the frozen pending snapshot and validates
    /// that explicit inputs still exist, without picking different homonyms.
    func confirmPendingOperation() {
        if let pending = pendingOperation {
            for step in pending.graph.steps where !step.inputs.isEmpty {
                for input in step.inputs {
                    let candidates = [input.hasPrefix("/") ? URL(fileURLWithPath: input) : pending.context.currentDirectory?.appendingPathComponent(input)]
                    if let url = candidates.compactMap({ $0 }).first,
                       !FileManager.default.fileExists(atPath: url.path) {
                        executionMessage = "❌ L'input '\(input)' non esiste più; ricrea il piano."
                        isExecuting = false
                        return
                    }
                }
            }
            run(pending: pending)
        } else if let graph = plannedGraph {
            executeGraph(graph)
        }
    }

    private func run(pending: PendingOperation?) {
        guard let pending else { return }
        executeGraph(pending.graph)
    }
}
