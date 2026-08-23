import SwiftUI

/// Banner errore/avviso con copia negli appunti e chiusura.
struct ErrorBannerView: View {
    let message: String
    let onClose: () -> Void

    var body: some View {
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

            Button(action: onClose) {
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
    }
}
