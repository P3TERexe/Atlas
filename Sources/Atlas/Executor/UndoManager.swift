import Foundation

@MainActor
final class AtlasUndoManager: ObservableObject {
    static let shared = AtlasUndoManager()
    private static let maxTrackedTransactions = 50
    private var transactionIDs: [UUID] = []
    @Published private(set) var rollbackError: String?

    private init() {}

    func register(transaction: AtlasTransaction) {
        guard transaction.canRollback, !transactionIDs.contains(transaction.id) else { return }
        transactionIDs.append(transaction.id)
        if transactionIDs.count > Self.maxTrackedTransactions {
            transactionIDs.removeFirst(transactionIDs.count - Self.maxTrackedTransactions)
        }
    }

    func discard(id: UUID) {
        transactionIDs.removeAll { $0 == id }
    }

    func undo() {
        guard let id = transactionIDs.last else { return }
        do {
            try HistoryStore.shared.rollback(id: id)
            rollbackError = nil
        } catch {
            rollbackError = error.localizedDescription
        }
    }
}
