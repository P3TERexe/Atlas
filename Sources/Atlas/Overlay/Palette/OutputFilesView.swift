import SwiftUI

/// Pannello dei file creati dall'ultima transazione completata (Screen 3).
struct OutputFilesView: View {
    let transaction: AtlasTransaction
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — single line
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.title3)

                Text(headerTitle)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

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
                .help("Chiudi (⌘⇧Z per annullare)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.06))

            Divider()

            // File list (capped: migliaia di righe con icone NSImage
            // appesantiscono o bloccano l'UI, es. selezionando tutte le foto)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(transaction.createdURLs.prefix(200)), id: \.self) { url in
                        OutputFileRow(url: url)
                    }
                    if transaction.createdURLs.count > 200 {
                        Text("… e altri \(transaction.createdURLs.count - 200) file")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(10)
            }
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
            return "Completato"
        } else if count == 1 {
            return "1 file creato"
        } else {
            return "\(count) file creati"
        }
    }

    private func revealAll() {
        Task {
            await FinderSelector.select(urls: transaction.createdURLs)
        }
    }
}
