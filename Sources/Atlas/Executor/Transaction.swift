import Foundation

enum TransactionStatus: String, Codable {
    case executing
    case success
    case failed
    case rollbackFailed
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

protocol RollbackFileOperations {
    func copyItem(at source: URL, to destination: URL) throws
    func replaceItem(at original: URL, with replacement: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
}

struct FoundationRollbackFileOperations: RollbackFileOperations {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func replaceItem(at original: URL, with replacement: URL) throws {
        _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement, backupItemName: nil, options: [])
    }
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }
    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
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
    var undoSupported = true
    
    init(steps: [ActionStep]) {
        self.id = UUID()
        self.steps = steps
    }
    
    // MARK: - Codable
    // `[URL: URL]` cannot be encoded directly by JSONEncoder (URL is not a
    // RawRepresentable key), so backups are persisted as an array of pairs.
    
    private enum CodingKeys: String, CodingKey {
        case id, steps, backupURLs, createdURLs, query, summary, resultMessage, status, startedAt, completedAt
        case undoSupported
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
        undoSupported = try c.decodeIfPresent(Bool.self, forKey: .undoSupported) ?? true
        
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
        try c.encode(undoSupported, forKey: .undoSupported)
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

    mutating func incorporate(_ result: ActionResult) {
        undoSupported = undoSupported && result.undoSupported
        let previouslyCreated = Set(createdURLs)
        for (original, backup) in result.backupURLs {
            if backupURLs[original] == nil && !previouslyCreated.contains(original) {
                backupURLs[original] = backup
            }
        }
        let retained = Set(backupURLs.values)
        for backup in Set(result.backupURLs.values) where !retained.contains(backup) {
            try? FileManager.default.removeItem(at: backup)
        }
        var known = Set(createdURLs)
        for output in result.outputFiles where known.insert(output).inserted {
            createdURLs.append(output)
        }
        resultMessage = result.message ?? resultMessage
    }
    
    var canRollback: Bool {
        guard undoSupported else { return false }
        switch status {
        case .success, .failed, .rollbackFailed:
            return !createdURLs.isEmpty || !backupURLs.isEmpty
        case .executing, .rolledBack:
            return false
        }
    }

    static func restoreBackup(original: URL, backup: URL) throws {
        try restoreBackup(original: original, backup: backup, fileOperations: FoundationRollbackFileOperations())
    }

    private static func restoreBackup(original: URL, backup: URL, fileOperations: any RollbackFileOperations) throws {
        guard fileOperations.fileExists(at: backup) else {
            throw RollbackError(failures: ["Backup mancante per \(original.path) (\(backup.path))"])
        }
        let temporary = original.deletingLastPathComponent().appendingPathComponent(".atlas-restore-\(UUID().uuidString)")
        defer {
            if fileOperations.fileExists(at: temporary) { try? fileOperations.removeItem(at: temporary) }
        }
        try fileOperations.copyItem(at: backup, to: temporary)
        if fileOperations.fileExists(at: original) {
            try fileOperations.replaceItem(at: original, with: temporary)
        } else {
            try fileOperations.moveItem(at: temporary, to: original)
        }
        // Recovery succeeded. A cleanup failure leaves only an orphan backup.
        try? fileOperations.removeItem(at: backup)
    }

    /// Retains only unfinished recovery operations so failed rollback can be retried.
    @discardableResult
    mutating func rollback(fileOperations: any RollbackFileOperations = FoundationRollbackFileOperations()) throws -> RollbackResult {
        guard status != .rolledBack else {
            throw RollbackError(failures: ["La transazione \(id.uuidString) è già stata annullata."])
        }
        var deleted = 0
        var restored = 0
        var failures: [String] = []
        var seen = Set<URL>()
        createdURLs = createdURLs.filter { seen.insert($0).inserted }
        let created = createdURLs
        let backups = backupURLs
        let parents = Set(backups.values.map { $0.deletingLastPathComponent().standardizedFileURL })

        for url in created where backups[url] == nil {
            do {
                if fileOperations.fileExists(at: url) {
                    try fileOperations.removeItem(at: url)
                    deleted += 1
                }
                createdURLs.removeAll { $0 == url }
            } catch {
                failures.append("Eliminazione di \(url.path): \(error.localizedDescription)")
            }
        }
        for (original, backup) in backups {
            do {
                try Self.restoreBackup(original: original, backup: backup, fileOperations: fileOperations)
                backupURLs.removeValue(forKey: original)
                createdURLs.removeAll { $0 == original }
                restored += 1
            } catch {
                failures.append("Ripristino di \(original.path): \(error.localizedDescription)")
            }
        }
        for directory in parents {
            guard !backupURLs.values.contains(where: { $0.deletingLastPathComponent().standardizedFileURL == directory }) else { continue }
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? fileOperations.removeItem(at: directory)
            }
        }
        if !failures.isEmpty {
            status = .rollbackFailed
            throw RollbackError(failures: failures)
        }
        status = .rolledBack
        return RollbackResult(deletedFilesCount: deleted, restoredFilesCount: restored)
    }
}
