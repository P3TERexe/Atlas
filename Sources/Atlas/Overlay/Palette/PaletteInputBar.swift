import SwiftUI

/// Input bar della palette: sparkles icon, text field con navigazione
/// cronologia, spinner/annullamento, toggle pensiero AI, menu modello,
/// menu "Altro" e pulsante chiudi.
struct PaletteInputBar: View {
    @ObservedObject var settings: AppSettings
    @Binding var query: String
    let textFieldFocus: FocusState<Bool>.Binding
    let isExecuting: Bool
    let onExecute: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void
    let onHistoryUp: () -> Void
    let onHistoryDown: () -> Void
    let onToggleHistory: () -> Void
    let onToggleHelp: () -> Void
    let onToggleDebug: () -> Void
    let isDebugVisible: Bool

    private var selectedProvider: AIProvider { settings.defaultProvider }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundColor(.accentColor)
                .font(.title2)
                .padding(.leading, 4)

            TextField("Cosa vuoi fare?", text: $query)
                .font(.title2)
                .focused(textFieldFocus)
                .onSubmit { onExecute() }
                .onExitCommand { onDismiss() }
                .onKeyPress(.upArrow) {
                    onHistoryUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onHistoryDown()
                    return .handled
                }

            if isExecuting {
                // Cancel button — visible only during planning/execution
                Button(action: onCancel) {
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

            // Quick Thinking/Fast mode toggle button
            Button(action: {
                settings.disableThinking.toggle()
            }) {
                HStack(spacing: 3) {
                    Image(systemName: settings.disableThinking ? "bolt.fill" : "brain.head.profile")
                        .font(.system(size: 9))
                        .foregroundColor(settings.disableThinking ? .orange : .purple)
                    Text(settings.disableThinking ? "Veloce" : "Pensiero")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(settings.disableThinking ? .orange : .purple)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background((settings.disableThinking ? Color.orange : Color.purple).opacity(0.12))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .help(settings.disableThinking ? "Pensiero AI disabilitato (modalità veloce). Clicca per abilitare" : "Pensiero AI abilitato. Clicca per disabilitare")

            // Model selector — scrive direttamente su AppSettings
            Menu {
                ForEach(AIProvider.allCases) { provider in
                    Button(action: {
                        settings.defaultProvider = provider
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

            // More menu (Settings, History, Help, Debug)
            Menu {
                Button(action: onToggleHistory) {
                    Label("Cronologia", systemImage: "clock.arrow.circlepath")
                }

                Button(action: onToggleHelp) {
                    Label("Guida", systemImage: "questionmark.circle")
                }

                Button(action: {
                    settings.disableThinking.toggle()
                }) {
                    Label(
                        settings.disableThinking ? "Pensiero AI: Disabilitato (Veloce)" : "Pensiero AI: Abilitato",
                        systemImage: settings.disableThinking ? "bolt.fill" : "brain.head.profile"
                    )
                }

                Divider()

                Button(action: onToggleDebug) {
                    Label(isDebugVisible ? "Nascondi debug" : "Debug", systemImage: "ladybug")
                }

                Divider()

                SettingsLink {
                    Label("Impostazioni…", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Altro (Cronologia, Guida, Debug, Impostazioni)")

            // Close button
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Chiudi (Esc)")
            .padding(.trailing, 8)
        }
    }
}
