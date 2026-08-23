import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    
    @Published private(set) var transactions: [AtlasTransaction] = []
    
    private let fileURL: URL
    
    private init() {
        fileURL = Self.storeURL(fileName: "history.json")
        load()
    }
    
    /// Injection point per i test; nil = directory reale di Application Support.
    nonisolated(unsafe) static var directoryOverride: URL?

    private static func storeURL(fileName: String) -> URL {
        let base = directoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Atlas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
    
    /// Cap for input lists persisted in history.json: step inputs (file
    /// names) are not needed for rollback (that uses backupURLs/createdURLs),
    /// so keeping them bounded keeps the JSON lightweight.
    private static let maxPersistedInputsPerStep = 1000
    
    func record(_ transaction: AtlasTransaction) {
        var tx = transaction
        tx.steps = tx.steps.map { step in
            guard step.inputs.count > Self.maxPersistedInputsPerStep else { return step }
            var bounded = step
            bounded.inputs = Array(step.inputs.prefix(Self.maxPersistedInputsPerStep))
            return bounded
        }
        transactions.insert(tx, at: 0)
        if transactions.count > 100 {
            transactions.removeLast(transactions.count - 100)
        }
        save()
    }
    
    func clear() {
        transactions.removeAll()
        save()
    }
    
    @discardableResult
    func rollback(id: UUID) -> RollbackResult? {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else { return nil }
        var tx = transactions[index]
        guard tx.status == .success else { return nil }
        
        do {
            let result = try tx.rollback()
            tx.status = .rolledBack
            tx.resultMessage = "Annullata: \(result.deletedFilesCount) file eliminati, \(result.restoredFilesCount) ripristinati."
            transactions[index] = tx
            save()
            // Keep the global ⌘⇧Z stack in sync: this transaction must not be
            // rolled back a second time from there.
            AtlasUndoManager.shared.discard(id: id)
            return result
        } catch {
            print("Rollback failed for transaction \(id): \(error)")
            return nil
        }
    }
    
    // MARK: - Persistence
    
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            transactions = try decoder.decode([AtlasTransaction].self, from: data)
        } catch {
            // Quarantine the unreadable store instead of silently losing it.
            let backupURL = fileURL.appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            print("Failed to decode history.json (quarantined to \(backupURL.lastPathComponent)): \(error)")
        }
    }
    
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(transactions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to persist history.json: \(error)")
        }
    }
}
