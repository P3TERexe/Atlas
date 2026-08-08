import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    let onClose: () -> Void
    var onReexecute: ((String) -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Cronologia operazioni", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if !store.transactions.isEmpty {
                    Button("Pulisci") {
                        store.clear()
                    }
                    .font(.caption)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            
            Divider()
            
            if store.transactions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("Nessuna operazione ancora eseguita")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.transactions) { transaction in
                            HistoryRow(transaction: transaction, onReexecute: onReexecute)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryRow: View {
    let transaction: AtlasTransaction
    var onReexecute: ((String) -> Void)? = nil
    @ObservedObject private var store = HistoryStore.shared
    @State private var rollbackMessage: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                    .foregroundColor(statusColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 6) {
                    if transaction.status == .success {
                        Button {
                            if let res = store.rollback(id: transaction.id) {
                                rollbackMessage = "Annullata (\(res.deletedFilesCount) eliminati)"
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.caption2)
                                Text("Annulla")
                                    .font(.caption2)
                            }
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Annulla questa specifica operazione")
                    } else if transaction.status == .rolledBack {
                        Text("Annullata")
                            .font(.caption2.bold())
                            .foregroundColor(.gray)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    
                    // Redo / Riesegui button
                    if let query = transaction.query ?? transaction.summary {
                        Button {
                            onReexecute?(query)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.uturn.forward")
                                    .font(.caption2)
                                Text("Redo")
                                    .font(.caption2)
                            }
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help("Riesegui questo comando nel Finder")
                    }
                }
            }
            
            if !transaction.createdURLs.isEmpty {
                Text("\(transaction.createdURLs.count) file creati")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }
    
    private var title: String {
        transaction.query ?? transaction.summary ?? transaction.toolNames.joined(separator: ", ")
    }
    
    private var subtitle: String {
        if let message = transaction.resultMessage, transaction.status != .success {
            return message
        }
        return transaction.toolNames.joined(separator: " → ")
    }
    
    private var statusIcon: Image {
        switch transaction.status {
        case .success: return Image(systemName: "checkmark.circle.fill")
        case .failed: return Image(systemName: "xmark.circle.fill")
        case .executing: return Image(systemName: "circle.dotted")
        case .rolledBack: return Image(systemName: "arrow.uturn.backward.circle.fill")
        }
    }
    
    private var statusColor: Color {
        switch transaction.status {
        case .success: return .green
        case .failed: return .red
        case .executing: return .orange
        case .rolledBack: return .gray
        }
    }
    
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "it_IT")
        return formatter
    }()
    
    private var formattedDate: String {
        guard let date = transaction.completedAt ?? transaction.startedAt as Date? else { return "" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
