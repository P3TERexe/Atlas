import Foundation

/// Persistent home for undo backups. Replaces the old `/tmp/AtlasBackups`
/// location, which macOS may purge between reboots and which made rollbacks
/// fail with "Backup mancante" days later.
///
/// Retention is bounded by `prune(maxAgeDays:)`, called once at app launch.
/// Each backup directory is keyed by a fresh UUID; the original→backup mapping
/// lives on in `AtlasTransaction.backupURLs`, so rollback keeps working across
/// restarts as long as the directory survives (now guaranteed outside `/tmp`).
enum BackupStore {

    /// Injection point for tests; `nil` means the real Application Support root.
    nonisolated(unsafe) static var rootOverride: URL?

    /// `<Application Support>/Atlas/Backups`, created on demand. Falls back to
    /// the temporary directory exactly like HistoryStore.storeURL when the
    /// Application Support domain is unavailable.
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base
            .appendingPathComponent("Atlas", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates and returns a fresh backup directory under the active root.
    static func newBackupDirectory() throws -> URL {
        let root = rootOverride ?? defaultRoot()
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Deletes backup directories older than `maxAgeDays`. Directories whose
    /// modification date cannot be read are skipped (conservative: never delete
    /// what we cannot age-classify).
    static func prune(maxAgeDays: Int = 30) {
        let fm = FileManager.default
        let root = rootOverride ?? defaultRoot()
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        for child in children {
            guard let modified = try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            if modified < cutoff {
                try? fm.removeItem(at: child)
            }
        }
    }
}
