import Foundation
import AppKit

@MainActor
class AtlasUndoManager {
    static let shared = AtlasUndoManager()
    
    private let undoManager = UndoManager()
    private var transactions: [AtlasTransaction] = []
    
    private init() {}
    
    func register(transaction: AtlasTransaction) {
        transactions.append(transaction)
        
        // We register an undo operation with the NSUndoManager
        undoManager.registerUndo(withTarget: self) { target in
            target.performRollback(for: transaction)
        }
        undoManager.setActionName("Atlas Action")
    }
    
    func performRollback(for transaction: AtlasTransaction) {
        do {
            try transaction.rollback()
            // Remove from our list
            transactions.removeAll { $0.id == transaction.id }
        } catch {
            print("Failed to rollback transaction \(transaction.id): \(error)")
        }
    }
    
    func undo() {
        if undoManager.canUndo {
            undoManager.undo()
        }
    }
}
