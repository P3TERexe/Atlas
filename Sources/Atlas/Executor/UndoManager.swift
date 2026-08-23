import Foundation
import AppKit

@MainActor
class AtlasUndoManager {
    static let shared = AtlasUndoManager()
    
    /// Cap on retained transactions: steps can carry thousands of input
    /// names, so keeping every transaction forever would leak memory.
    private static let maxTrackedTransactions = 50
    
    private let undoManager = UndoManager()
    private var transactions: [AtlasTransaction] = []
    
    private init() {
        undoManager.levelsOfUndo = Self.maxTrackedTransactions
    }
    
    func register(transaction: AtlasTransaction) {
        transactions.append(transaction)
        if transactions.count > Self.maxTrackedTransactions {
            transactions.removeFirst(transactions.count - Self.maxTrackedTransactions)
        }
        
        // We register an undo operation with the NSUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            target.performRollback(for: transaction)
        }
        undoManager.setActionName("Atlas Action")
    }
    
    /// Drops a transaction from the undo list (e.g. already rolled back via
    /// HistoryView) so the global ⌘⇧Z can never roll it back a second time.
    func discard(id: UUID) {
        transactions.removeAll { $0.id == id }
    }
    
    func performRollback(for transaction: AtlasTransaction) {
        // Guard: skip if the transaction was already rolled back elsewhere
        // (HistoryView selective undo) or evicted from tracking.
        guard transactions.contains(where: { $0.id == transaction.id }) else { return }
        var tx = transaction
        do {
            try tx.rollback()
            transactions.removeAll { $0.id == tx.id }
        } catch {
            print("Failed to rollback transaction \(tx.id): \(error)")
        }
    }
    
    func undo() {
        if undoManager.canUndo {
            undoManager.undo()
        }
    }
}
