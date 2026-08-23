import SwiftUI

/// Pannello debug: mostra prompt e risposta dell'ultimo tentativo di pianificazione.
struct PaletteDebugPanel: View {
    let lastPrompt: String?
    let lastResponse: String?
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("BUG / PROMPT LOGS")
                    .font(.caption2.bold())
                    .foregroundColor(.orange)
                Spacer()
                Button("Svuota") {
                    onClear()
                }
                .font(.caption2)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if let lastPrompt = lastPrompt {
                        Text("PROMPT INVIATO:")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        Text(lastPrompt)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }

                    if let lastResponse = lastResponse {
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
    }
}
