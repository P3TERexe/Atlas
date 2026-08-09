import SwiftUI

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    let onClose: () -> Void
    var onReexecute: ((String) -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Cronologia", systemImage: "clock.arrow.circlepath")
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
                    Text("Nessuna operazione eseguita")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
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
        HStack(spacing: 8) {
            statusIcon
                .foregroundColor(statusColor)
            
            VStack(alignment: .leading, spacing: 1) {
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
            
            HStack(spacing: 4) {
                if transaction.status == .success {
                    Button {
                        if let res = store.rollback(id: transaction.id) {
                            rollbackMessage = "Annullata (\(res.deletedFilesCount) eliminati)"
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Annulla operazione")
                } else if transaction.status == .rolledBack {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .help("Annullata")
                }
                
                // Redo button
                if let query = transaction.query ?? transaction.summary {
                    Button {
                        onReexecute?(query)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .font(.caption2)
                            .foregroundColor(.accentColor)
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Riesegui")
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
    }
    
    private var title: String {
        transaction.query ?? transaction.summary ?? transaction.toolNames.joined(separator: ", ")
    }
    
    private var subtitle: String {
        var parts: [String] = []
        if let message = transaction.resultMessage, transaction.status != .success {
            return message
        }
        parts.append(transaction.toolNames.joined(separator: " → "))
        let count = transaction.createdURLs.count
        if count > 0 {
            parts.append("· \(count) file")
        }
        return parts.joined(separator: " ")
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
