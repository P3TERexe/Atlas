import Foundation

enum TransactionStatus: String, Codable {
    case executing
    case success
    case failed
    case rolledBack
}

struct RollbackResult {
    let deletedFilesCount: Int
    let restoredFilesCount: Int
}

/// Records a full filesystem operation for rollback and history purposes.
/// Named `AtlasTransaction` to avoid colliding with `SwiftUI.Transaction`.
struct AtlasTransaction: Codable, Identifiable {
    let id: UUID
    let steps: [ActionStep]
    var backupURLs: [URL: URL] = [:] // original -> backup
    var createdURLs: [URL] = []      // files created by this transaction
    var query: String?
    var summary: String?
    var resultMessage: String?
    var status: TransactionStatus = .executing
    var startedAt: Date = Date()
    var completedAt: Date?
    
    init(steps: [ActionStep]) {
        self.id = UUID()
        self.steps = steps
    }
    
    // MARK: - Codable
    // `[URL: URL]` cannot be encoded directly by JSONEncoder (URL is not a
    // RawRepresentable key), so backups are persisted as an array of pairs.
    
    private enum CodingKeys: String, CodingKey {
        case id, steps, backupURLs, createdURLs, query, summary, resultMessage, status, startedAt, completedAt
    }
    
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        steps = try c.decode([ActionStep].self, forKey: .steps)
        createdURLs = try c.decodeIfPresent([URL].self, forKey: .createdURLs) ?? []
        query = try c.decodeIfPresent(String.self, forKey: .query)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        resultMessage = try c.decodeIfPresent(String.self, forKey: .resultMessage)
        status = try c.decodeIfPresent(TransactionStatus.self, forKey: .status) ?? .executing
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        
        var decodedBackups: [URL: URL] = [:]
        if let pairs = try c.decodeIfPresent([[String: String]].self, forKey: .backupURLs) {
            for pair in pairs {
                if let original = pair["original"], let backup = pair["backup"] {
                    decodedBackups[URL(fileURLWithPath: original)] = URL(fileURLWithPath: backup)
                }
            }
        }
        backupURLs = decodedBackups
    }
    
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(steps, forKey: .steps)
        try c.encode(backupURLs.map { ["original": $0.key.path, "backup": $0.value.path] }, forKey: .backupURLs)
        try c.encode(createdURLs, forKey: .createdURLs)
        try c.encodeIfPresent(query, forKey: .query)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(resultMessage, forKey: .resultMessage)
        try c.encode(status, forKey: .status)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
    }
    
    var toolNames: [String] {
        steps.map { $0.tool }
    }
    
    mutating func addBackup(original: URL, backup: URL) {
        backupURLs[original] = backup
    }
    
    mutating func addCreated(url: URL) {
        createdURLs.append(url)
    }
    
    @discardableResult
    func rollback() throws -> RollbackResult {
        let fm = FileManager.default
        var deleted = 0
        var restored = 0
        
        // 1. Delete files created by this transaction
        for url in createdURLs {
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    deleted += 1
                } catch {
                    print("Failed to remove created file \(url.path): \(error)")
                }
            }
        }
        
        // 2. Restore files that were backed up
        for (original, backup) in backupURLs {
            if fm.fileExists(atPath: backup.path) {
                do {
                    if fm.fileExists(atPath: original.path) {
                        try fm.removeItem(at: original)
                    }
                    try fm.moveItem(at: backup, to: original)
                    restored += 1
                } catch {
                    print("Failed to restore backup \(backup.path) to \(original.path): \(error)")
                }
            }
        }
        
        return RollbackResult(deletedFilesCount: deleted, restoredFilesCount: restored)
    }
}
