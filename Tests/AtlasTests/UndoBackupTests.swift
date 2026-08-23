import XCTest
@testable import Atlas

final class UndoBackupTests: XCTestCase {

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    override func tearDown() {
        BackupStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - BackupStore.newBackupDirectory

    func testNewBackupDirectoryUsesPersistentRoot() throws {
        let root = try makeTempRoot()
        BackupStore.rootOverride = root

        let dir = try BackupStore.newBackupDirectory()

        XCTAssertTrue(dir.path.hasPrefix(root.path), "Il backup deve stare sotto la root iniettata: \(dir.path)")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    // MARK: - BackupStore.prune

    func testPruneRemovesOnlyOldDirectories() throws {
        let root = try makeTempRoot()
        BackupStore.rootOverride = root

        let old = try BackupStore.newBackupDirectory()
        let recent = try BackupStore.newBackupDirectory()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86_400)],
            ofItemAtPath: old.path
        )

        BackupStore.prune(maxAgeDays: 30)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "La directory vecchia (> 30 giorni) va rimossa")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "La directory recente va conservata")
    }

    // MARK: - Rollback cleanup

    func testRollbackRemovesEmptiedBackupDir() throws {
        let workDir = try makeTempRoot()
        let original = workDir.appendingPathComponent("foto.jpg")
        try "image".write(to: original, atomically: true, encoding: .utf8)

        BackupStore.rootOverride = try makeTempRoot()
        let backupDir = try BackupStore.newBackupDirectory()
        let backupURL = backupDir.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: backupURL)
        let renamed = workDir.appendingPathComponent("vacanza_1.jpg")
        try FileManager.default.moveItem(at: original, to: renamed)

        var tx = AtlasTransaction(steps: [])
        tx.addBackup(original: original, backup: backupURL)

        _ = try tx.rollback()

        XCTAssertEqual(tx.status, .rolledBack)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "Il file originale deve essere ripristinato")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path), "Il backup è consumato dal restore")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupDir.path), "La directory backup svuotata va rimossa")

        // Secondo rollback: deve fallire, non rieseguire in silenzio
        XCTAssertThrowsError(try tx.rollback())
    }

    func testRollbackKeepsNonEmptyBackupDir() throws {
        let workDir = try makeTempRoot()
        let original = workDir.appendingPathComponent("a.txt")
        try "a".write(to: original, atomically: true, encoding: .utf8)

        BackupStore.rootOverride = try makeTempRoot()
        let backupDir = try BackupStore.newBackupDirectory()
        let backupURL = backupDir.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: backupURL)
        // File estraneo nella stessa directory: NON va toccato dalla pulizia.
        let stranger = backupDir.appendingPathComponent("altro-transazione.txt")
        try "x".write(to: stranger, atomically: true, encoding: .utf8)

        let renamed = workDir.appendingPathComponent("b.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        var tx = AtlasTransaction(steps: [])
        tx.addBackup(original: original, backup: backupURL)
        _ = try tx.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path), "La pulizia non deve cancellare file di altri")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir.path), "La directory non vuota resta")
    }
}
