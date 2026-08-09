import SwiftUI
import AppKit

// Notification to hide the overlay from inside SwiftUI
extension Notification.Name {
    static let atlasHideOverlay = Notification.Name("atlasHideOverlay")
}

struct CommandPaletteView: View {
    @State private var query: String = ""
    @State private var isExecuting: Bool = false
    @State private var plannedGraph: ActionGraph? = nil
    @State private var executionMessage: String? = nil
    @State private var lastTransaction: AtlasTransaction? = nil
    @State private var progress: ProgressUpdate? = nil
    @State private var selectedProvider: AIProvider = AppSettings.shared.defaultProvider
    @State private var showDebug: Bool = false
    @State private var showHistory: Bool = false
    @State private var showHelp: Bool = false
    @State private var cachedContext: FinderContext?
    @State private var currentTask: Task<Void, Never>? = nil
    @FocusState private var textFieldFocused: Bool
    
    // Terminal-style command history — backed by CommandHistoryStore (persistent)
    @ObservedObject private var commandHistoryStore = CommandHistoryStore.shared
    @State private var historyIndex: Int = -1
    @State private var savedDraft: String = ""
    
    private let contextProvider = FinderContextProvider()
    private let planner = Planner()
    private let executor = ExecutorFramework()
    
    var body: some View {
        VStack(spacing: 0) {
            // ── Input bar ─────────────────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                    .padding(.leading, 4)
                
                TextField("Cosa vuoi fare?", text: $query)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.title2)
                    .focused($textFieldFocused)
                    .onSubmit { executeCommand() }
                    .onExitCommand { dismiss() }
                    .onKeyPress(.upArrow) {
                        navigateHistory(direction: .up)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        navigateHistory(direction: .down)
                        return .handled
                    }
                
                if isExecuting {
                    // Cancel button — visible only during planning/execution
                    Button(action: cancelCurrentTask) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 13))
                            Text("Annulla")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.red.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Annulla operazione in corso")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    
                    ProgressView()
                        .scaleEffect(0.75)
                        .controlSize(.small)
                }
                
                // Model selector
                Menu {
                    ForEach(AIProvider.allCases) { provider in
                        Button(action: {
                            selectedProvider = provider
                            planner.activeProvider = provider
                            AppSettings.shared.defaultProvider = provider
                        }) {
                            HStack {
                                if provider == selectedProvider {
                                    Image(systemName: "checkmark")
                                }
                                Image(systemName: provider.icon)
                                Text(provider.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: selectedProvider.icon)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Modello AI: \(selectedProvider.rawValue)")
                
                // Settings
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Impostazioni")
                
                // History
                Button(action: {
                    showHistory.toggle()
                    showDebug = false
                }) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundColor(showHistory ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("h", modifiers: [.command])
                .help("Cronologia operazioni (Cmd+H)")
                
                // Help toggle
                Button(action: {
                    showHelp.toggle()
                    showHistory = false
                    showDebug = false
                }) {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundColor(showHelp ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Guida & limitazioni")
                
                // Debug toggle
                Button(action: {
                    showDebug.toggle()
                    showHistory = false
                    showHelp = false
                }) {
                    Image(systemName: "ladybug")
                        .font(.caption)
                        .foregroundColor(showDebug ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help("Mostra/nascondi log di debug")
                
                // Close button
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Chiudi (Esc)")
                .padding(.trailing, 8)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            
            Divider()
            
            // ── Finder Context Banner ──────────────────────────────────────
            ContextBannerView(context: cachedContext)
            
            // ── Debug Panel ───────────────────────────────────────────────
            if showDebug {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("BUG / PROMPT LOGS")
                            .font(.caption2.bold())
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Svuota") {
                            planner.clearLog()
                        }
                        .font(.caption2)
                    }
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if let lastPrompt = planner.lastPrompt {
                                Text("PROMPT INVIATO:")
                                    .font(.caption2.bold())
                                    .foregroundColor(.secondary)
                                Text(lastPrompt)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            }
                            
                            if let lastResponse = planner.lastResponse {
                                Text("RISPOSTA RICEVUTA:")
                                    .font(.caption2.bold())
                                    .foregroundColor(.secondary)
                                Text(lastResponse)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.green)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(height: 100)
                }
                .padding(8)
                .background(Color.black.opacity(0.4))
                .cornerRadius(6)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                
                Divider()
            }
            
            // ── Body area ─────────────────────────────────────────────────
            Group {
                if showHistory {
                    HistoryView(
                        onClose: { showHistory = false },
                        onReexecute: { queryText in
                            self.query = queryText
                            self.showHistory = false
                            self.executeCommand()
                        }
                    )
                } else if showHelp {
                    HelpSheetView(onClose: { showHelp = false })
                } else {
                ScrollView {
                    if let update = progress, isExecuting {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: update.fraction)
                                .progressViewStyle(.linear)
                            HStack {
                                Text(update.message)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(update.stepIndex + 1)/\(update.totalSteps)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    if let message = executionMessage {
                        if message.hasPrefix("❌") || message.hasPrefix("⚠") {
                            // Error / warning banner — constrained height to avoid layout distortion
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: message.hasPrefix("❌") ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(message.hasPrefix("❌") ? .red : .orange)
                                    .font(.title3)
                                
                                ScrollView {
                                    Text(message)
                                        .foregroundColor(.primary)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 110)
                                
                                Spacer(minLength: 4)
                                
                                if message.hasPrefix("❌") {
                                    Button(action: {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(message, forType: .string)
                                    }) {
                                        Image(systemName: "doc.on.doc")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Copia errore nel clipboard")
                                }
                                
                                Button(action: { executionMessage = nil }) {
                                    Image(systemName: "xmark")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Chiudi messaggio")
                            }
                            .padding(10)
                            .background(Color.red.opacity(0.06))
                            .cornerRadius(8)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        } else if let transaction = lastTransaction {
                            // Success: show created files
                            OutputFilesView(transaction: transaction) {
                                executionMessage = nil
                                lastTransaction = nil
                                textFieldFocused = true
                            }
                        }
                    } else if let graph = plannedGraph {
                        PreviewView(
                            graph: graph,
                            context: cachedContext ?? FinderContext(currentDirectory: nil, selectedFiles: [], visibleFiles: [], installedTools: [], timestamp: Date()),
                            onExecute: { executeGraph(graph) },
                            onCancel: {
                                plannedGraph = nil
                                query = ""
                                textFieldFocused = true
                            }
                        )
                        
                    } else {
                        // Quick Action Grid & Formats
                        QuickActionGrid { selectedCmd in
                            query = selectedCmd
                            textFieldFocused = true
                            executeCommand()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 420)
        .onAppear {
            Task { await refreshContext() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                textFieldFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await refreshContext() }
        }
    }
    
    // ── Helpers ────────────────────────────────────────────────────────
    
    private func refreshContext() async {
        cachedContext = await contextProvider.getCurrentContext()
    }
    
    private enum HistoryDirection { case up, down }
    
    private func navigateHistory(direction: HistoryDirection) {
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
    
    private func dismiss() {
        NotificationCenter.default.post(name: .atlasHideOverlay, object: nil)
    }
    
    private func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        withAnimation {
            isExecuting = false
            progress = nil
        }
        executionMessage = "⚠︎ Operazione annullata dall'utente."
        textFieldFocused = true
    }
    
    private func executeCommand() {
        guard !query.isEmpty else { return }
        saveToHistory(query)
        isExecuting = true
        progress = ProgressUpdate(stepIndex: 0, totalSteps: 1, message: "Analizzo la richiesta con \(selectedProvider.rawValue)...")
        executionMessage = nil
        plannedGraph = nil
        showHistory = false
        
        currentTask = Task { @MainActor in
            // Fetch fresh context once, off the main thread, then reuse it for planning
            let context = await contextProvider.getCurrentContext()
            guard !Task.isCancelled else { return }
            self.cachedContext = context
            
            do {
                let graph = try await planner.plan(query: query, context: context)
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
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation { self.isExecuting = false }
                self.progress = nil
                self.executionMessage = "❌ Errore durante la pianificazione (\(selectedProvider.rawValue)):\n\(error.localizedDescription)"
                self.showDebug = true
            }
        }
    }
    
    private func executeGraph(_ graph: ActionGraph) {
        isExecuting = true
        progress = ProgressUpdate(stepIndex: 0, totalSteps: graph.steps.count, message: "Inizializzazione esecuzione...")
        plannedGraph = nil
        
        currentTask = Task { @MainActor in
            // Fetch fresh context once, off the main thread, then reuse it for execution
            let context = await contextProvider.getCurrentContext()
            guard !Task.isCancelled else { return }
            self.cachedContext = context
            
            do {
                let transaction = try await executor.execute(graph: graph, context: context, query: query) { update in
                    guard !Task.isCancelled else { return }
                    self.progress = update
                }
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
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation { self.isExecuting = false }
                self.progress = nil
                self.executionMessage = "❌ Errore durante l'esecuzione:\n\(error.localizedDescription)"
                self.showDebug = true
            }
        }
    }
}

// MARK: - Output Files Panel (Screen 3)

struct OutputFilesView: View {
    let transaction: AtlasTransaction
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Banner
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.title2)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Text("Operazione completata con successo")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if transaction.createdURLs.count > 1 {
                    Button(action: revealAll) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder.fill")
                                .font(.caption2)
                            Text("Mostra tutti")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundColor(.accentColor)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.06))
            
            Divider()
            
            // File list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(transaction.createdURLs, id: \.self) { url in
                        OutputFileRow(url: url)
                    }
                }
                .padding(10)
            }
            
            Divider()
            
            // Bottom Undo Hint Bar
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Premi")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("⌘ ⇧ Z")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.1))
                        .cornerRadius(3)
                    Text("in qualsiasi momento per annullare")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))
        }
        .background(Color.primary.opacity(0.03))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.green.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private var headerTitle: String {
        let count = transaction.createdURLs.count
        if count == 0 {
            return "Operazione completata"
        } else if count == 1 {
            return "1 file creato con successo"
        } else {
            return "\(count) file creati con successo"
        }
    }
    
    private func revealAll() {
        NSWorkspace.shared.activateFileViewerSelecting(transaction.createdURLs)
    }
}

struct OutputFileRow: View {
    let url: URL
    @State private var isHovered = false
    @State private var fileSize: String = ""
    @State private var fileIcon: NSImage? = nil
    
    private var extUpper: String {
        url.pathExtension.uppercased()
    }
    
    var body: some View {
        HStack(spacing: 10) {
            if let fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Color.clear
                    .frame(width: 32, height: 32)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    
                    if !extUpper.isEmpty {
                        Text(extUpper)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12))
                            .foregroundColor(.accentColor)
                            .cornerRadius(3)
                    }
                }
                
                Text(url.deletingLastPathComponent().path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            
            Spacer()
            
            if !fileSize.isEmpty {
                Text(fileSize)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.trailing, 4)
            }
            
            // Open File Button
            Button(action: { NSWorkspace.shared.open(url) }) {
                Text("Apri")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .help("Apri file")
            
            // Reveal in Finder Button
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Mostra nel Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(url)
        }
        .task {
            guard fileSize.isEmpty else { return }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int64 {
                fileSize = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            }
            if fileIcon == nil {
                fileIcon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        .help("Doppio click per aprire")
    }
}
