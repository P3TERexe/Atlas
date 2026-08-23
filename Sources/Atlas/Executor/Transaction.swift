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

/// Thrown when a rollback could not fully restore the filesystem.
struct RollbackError: Error, LocalizedError {
    let failures: [String]
    
    var errorDescription: String? {
        "Rollback incompleto (\(failures.count) operazioni fallite):\n" + failures.joined(separator: "\n")
    }
}

/// Records a full filesystem operation for rollback and history purposes.
/// Named `AtlasTransaction` to avoid colliding with `SwiftUI.Transaction`.
struct AtlasTransaction: Codable, Identifiable {
    var id: UUID
    var steps: [ActionStep]
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
    
    /// Rolls back the transaction. Mutates `status` so a second invocation is
    /// rejected instead of silently re-running a partial restore.
    @discardableResult
    mutating func rollback() throws -> RollbackResult {
        guard status != .rolledBack else {
            throw RollbackError(failures: ["La transazione \(id.uuidString) è già stata annullata."])
        }
        status = .rolledBack
        completedAt = completedAt ?? Date()
        
        let fm = FileManager.default
        var deleted = 0
        var restored = 0
        var failures: [String] = []
        
        // 1. Delete files created by this transaction
        for url in createdURLs {
            if fm.fileExists(atPath: url.path) {
                do {
                    try fm.removeItem(at: url)
                    deleted += 1
                } catch {
                    failures.append("Eliminazione di \(url.path): \(error.localizedDescription)")
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
                    failures.append("Ripristino di \(original.path): \(error.localizedDescription)")
                }
            } else {
                failures.append("Backup mancante per \(original.path) (\(backup.path))")
            }
        }
        
        if !failures.isEmpty {
            throw RollbackError(failures: failures)
        }
        
        // 3. Remove backup directories this rollback emptied, so persistent
        //    storage does not accumulate empty per-execution folders. Only
        //    verified-empty directories are removed (never recursive).
        let parentDirs = Set(backupURLs.values.map { $0.deletingLastPathComponent().standardizedFileURL })
        for dir in parentDirs {
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                try? fm.removeItem(at: dir)
            }
        }
        
        return RollbackResult(deletedFilesCount: deleted, restoredFilesCount: restored)
    }
}
