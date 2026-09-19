import Foundation

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    
    @Published private(set) var transactions: [AtlasTransaction] = []
    @Published private(set) var persistenceError: String?
    private(set) var loadSucceeded = true
    
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
        if let index = transactions.firstIndex(where: { $0.id == tx.id }) {
            transactions[index] = tx
        } else {
            transactions.insert(tx, at: 0)
        }
        if transactions.count > 100 {
            for evicted in transactions.suffix(transactions.count - 100) {
                AtlasUndoManager.shared.discard(id: evicted.id)
            }
            transactions.removeLast(transactions.count - 100)
        }
        save()
    }
    
    func clear() {
        for transaction in transactions { AtlasUndoManager.shared.discard(id: transaction.id) }
        transactions.removeAll()
        save()
    }
    
    @discardableResult
    func rollback(id: UUID) throws -> RollbackResult {
        guard let index = transactions.firstIndex(where: { $0.id == id }) else {
            throw RollbackError(failures: ["Transazione non trovata: \(id)"])
        }
        var tx = transactions[index]
        guard tx.canRollback else {
            throw RollbackError(failures: ["Transazione non annullabile: \(id)"])
        }
        do {
            let result = try tx.rollback()
            tx.resultMessage = "Annullata: \(result.deletedFilesCount) file eliminati, \(result.restoredFilesCount) ripristinati."
            transactions[index] = tx
            save()
            AtlasUndoManager.shared.discard(id: id)
            return result
        } catch {
            tx.resultMessage = error.localizedDescription
            transactions[index] = tx
            save()
            throw error
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
            loadSucceeded = false
            persistenceError = "Impossibile caricare la cronologia: \(error.localizedDescription)"
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
            persistenceError = nil
        } catch {
            persistenceError = "Impossibile salvare la cronologia: \(error.localizedDescription)"
            print("Failed to persist history.json: \(error)")
        }
    }
}
