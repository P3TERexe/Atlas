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
    
    private static func storeURL(fileName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Atlas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
    
    func record(_ transaction: AtlasTransaction) {
        transactions.insert(transaction, at: 0)
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
            return result
        } catch {
            print("Rollback failed for transaction \(id): \(error)")
            return nil
        }
    }
    
    // MARK: - Persistence
    
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        do {
            let decoded = try decoder.decode([AtlasTransaction].self, from: data)
            transactions = decoded
        } catch {
            print("Failed to decode history.json on launch: \(error)")
        }
    }
    
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(transactions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
