import SwiftUI
import AppKit

// Notification to hide the overlay from inside SwiftUI
extension Notification.Name {
    static let atlasHideOverlay = Notification.Name("atlasHideOverlay")
}

struct CommandPaletteView: View {
    @StateObject private var vm = PaletteViewModel()
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Input bar ─────────────────────────────────────────────────
            PaletteInputBar(
                settings: AppSettings.shared,
                query: $vm.query,
                textFieldFocus: $textFieldFocused,
                isExecuting: vm.isExecuting,
                onExecute: { vm.executeCommand() },
                onCancel: {
                    vm.cancel()
                    textFieldFocused = true
                },
                onDismiss: dismiss,
                onHistoryUp: { vm.navigateHistory(direction: .up) },
                onHistoryDown: { vm.navigateHistory(direction: .down) },
                onToggleHistory: {
                    vm.showHistory.toggle()
                    vm.showDebug = false
                    vm.showHelp = false
                },
                onToggleHelp: {
                    vm.showHelp.toggle()
                    vm.showHistory = false
                    vm.showDebug = false
                },
                onToggleDebug: {
                    vm.showDebug.toggle()
                    vm.showHistory = false
                    vm.showHelp = false
                },
                isDebugVisible: vm.showDebug
            )
            .padding(.vertical, 12)
            .padding(.horizontal, 12)

            Divider()

            // ── Finder Context Banner ──────────────────────────────────────
            ContextBannerView(context: vm.cachedContext)

            // ── Debug Panel ───────────────────────────────────────────────
            if vm.showDebug {
                PaletteDebugPanel(
                    lastPrompt: vm.lastPrompt,
                    lastResponse: vm.lastResponse,
                    onClear: { vm.clearDebugLog() }
                )

                Divider()
            }

            // ── Body area ─────────────────────────────────────────────────
            Group {
                if vm.showHistory {
                    HistoryView(
                        onClose: { vm.showHistory = false },
                        onReexecute: { queryText in
                            vm.query = queryText
                            vm.showHistory = false
                            vm.executeCommand()
                        }
                    )
                } else if vm.showHelp {
                    HelpSheetView(onClose: { vm.showHelp = false })
                } else {
                ScrollView {
                    if let update = vm.progress, vm.isExecuting {
                        ProgressCardView(progress: update)
                    }

                    if let message = vm.executionMessage {
                        if message.hasPrefix("❌") || message.hasPrefix("⚠") {
                            // Error / warning banner — constrained height to avoid layout distortion
                            ErrorBannerView(message: message, onClose: { vm.executionMessage = nil })
                        } else if let transaction = vm.lastTransaction {
                            // Success: show created files
                            OutputFilesView(transaction: transaction) {
                                vm.executionMessage = nil
                                vm.lastTransaction = nil
                                textFieldFocused = true
                            }
                        }
                    } else if let graph = vm.plannedGraph {
                        PreviewView(
                            graph: graph,
                            context: vm.cachedContext ?? FinderContext(currentDirectory: nil, selectedFiles: [], visibleFiles: [], installedTools: [], timestamp: Date()),
                            onExecute: { vm.confirmPendingOperation() },
                            onCancel: {
                                vm.plannedGraph = nil
                                vm.query = ""
                                textFieldFocused = true
                            }
                        )

                    } else {
                        // Quick Action Grid & Formats
                        QuickActionGrid { selectedCmd in
                            vm.query = selectedCmd
                            textFieldFocused = true
                            vm.executeCommand()
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
            Task { await vm.refreshContext() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                textFieldFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await vm.refreshContext() }
        }
    }

    private func dismiss() {
        NotificationCenter.default.post(name: .atlasHideOverlay, object: nil)
    }
}
