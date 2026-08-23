import XCTest
@testable import Atlas

final class FilePluginTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(in directory: URL, named name: String, content: String = "contenuto") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func context(in directory: URL, files: [URL] = []) -> FinderContext {
        FinderContext(
            currentDirectory: directory,
            selectedFiles: files,
            visibleFiles: files,
            installedTools: [],
            timestamp: Date()
        )
    }

    override func tearDown() {
        BackupStore.rootOverride = nil
        super.tearDown()
    }

    // MARK: - Batch rename

    func testRenameBatchRenamesAndBackups() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backupRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: backupRoot) }
        BackupStore.rootOverride = backupRoot

        let originals = try (1...3).map { try makeFile(in: dir, named: "foto\($0).jpg") }
        let step = ActionStep(id: "s1", tool: "file.rename", inputs: originals.map(\.lastPathComponent), format: "vacanza_#.jpg")

        let result = try await RenameFilesAction().execute(step: step, context: context(in: dir, files: originals))

        XCTAssertTrue(result.success, "Il batch rename deve riuscire")
        XCTAssertEqual(result.outputFiles.count, 3, "Tre file in ingresso → tre output")
        XCTAssertEqual(result.backupURLs.count, 3, "Ogni sorgente deve avere un backup per l'undo")
        for (index, original) in originals.enumerated() {
            let renamed = dir.appendingPathComponent("vacanza_\(index + 1).jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path), "Deve esistere \(renamed.lastPathComponent)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "L'originale \(original.lastPathComponent) non deve più esserci")
        }
        for (original, backup) in result.backupURLs {
            XCTAssertTrue(backup.path.hasPrefix(backupRoot.path), "Il backup di \(original.lastPathComponent) deve stare sotto la root iniettata: \(backup.path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "Il backup fisico di \(original.lastPathComponent) deve esistere")
        }
    }

    func testRenameOverwriteRestoresTargetOnRollback() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backupRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: backupRoot) }
        BackupStore.rootOverride = backupRoot

        let source = try makeFile(in: dir, named: "a.jpg", content: "sorgente")
        let target = try makeFile(in: dir, named: "b1.jpg", content: "target-preesistente")
        let step = ActionStep(id: "s1", tool: "file.rename", inputs: ["a.jpg"], format: "b#.jpg")

        let result = try await RenameFilesAction().execute(step: step, context: context(in: dir, files: [source]))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.backupURLs.count, 2, "Devono essere tracciati sia il sorgente sia il target sovrascritto")
        XCTAssertNotNil(result.backupURLs[target], "Il target pre-esistente deve avere un backup dedicato")

        var tx = AtlasTransaction(steps: [step])
        tx.query = "rinomina"
        for url in result.outputFiles { tx.addCreated(url: url) }
        for (original, backup) in result.backupURLs { tx.addBackup(original: original, backup: backup) }

        _ = try tx.rollback()

        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "sorgente", "La sorgente originale va ripristinata")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "target-preesistente", "Il contenuto del target sovrascritto deve essere ripristinato senza perdite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "Dopo il rollback il file rinominato è eliminato e il target torna a esistere")
    }

    // MARK: - Copy action

    func testCopyActionCreatesNFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = try makeFile(in: dir, named: "relazione.pdf")

        // 3 copie nella cartella di default
        let stepDefault = ActionStep(id: "c1", tool: "file.copy", inputs: ["relazione.pdf"], format: "3")
        let result = try await CopyFilesAction().execute(step: stepDefault, context: context(in: dir, files: [source]))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputFiles.count, 3, "'format' 3 → tre copie")
        let copieDir = dir.appendingPathComponent("copie", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copieDir.path).count, 3, "Le copie vanno nella cartella 'copie'")

        // 2 copie nella cartella 'backup'
        let stepNamed = ActionStep(id: "c2", tool: "file.copy", inputs: ["relazione.pdf"], format: "2;backup")
        let result2 = try await CopyFilesAction().execute(step: stepNamed, context: context(in: dir, files: [source]))
        XCTAssertEqual(result2.outputFiles.count, 2, "'2;backup' → due copie")
        let backupDir = dir.appendingPathComponent("backup", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: backupDir.path).count, 2, "Il nome cartella dopo ';' viene rispettato")

        // Copia count invalido: validate deve rifiutare
        XCTAssertThrowsError(try CopyFilesAction().validate(step: ActionStep(id: "c3", tool: "file.copy", inputs: ["relazione.pdf"], format: "0"), context: context(in: dir, files: [source])), "'0' copie non è un numero valido") { error in
            guard case ExecutorError.validationFailed = error else {
                return XCTFail("Era atteso validationFailed, ricevuto: \(error)")
            }
        }
        XCTAssertThrowsError(try CopyFilesAction().validate(step: ActionStep(id: "c4", tool: "file.copy", inputs: ["relazione.pdf"]), context: context(in: dir, files: [source])), "Senza 'format' la validazione deve fallire") { error in
            guard case ExecutorError.validationFailed = error else {
                return XCTFail("Era atteso validationFailed, ricevuto: \(error)")
            }
        }
    }

    // MARK: - Zip / Compress

    func testZipSingleArchive() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try makeFile(in: dir, named: "a.txt", content: "alpha")
        let b = try makeFile(in: dir, named: "b.txt", content: "beta")
        let step = ActionStep(id: "z1", tool: "file.zip", inputs: [a.lastPathComponent, b.lastPathComponent])

        let result = try await ZipFilesAction().execute(step: step, context: context(in: dir, files: [a, b]))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputFiles.count, 1, "Più file → un unico archivio")
        let archive = try XCTUnwrap(result.outputFiles.first)
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0, "L'archivio ZIP non deve essere vuoto")
    }

    /// Bug: la stringa di anteprima interpolava i nomi file senza quoting —
    /// spazi e apici producevano un comando zsh non valido.
    func testZipPreviewQuotesShellMetacharacters() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try makeFile(in: dir, named: "il mio file.png")
        let b = try makeFile(in: dir, named: "l'archivio.txt")
        let step = ActionStep(id: "z2", tool: "file.zip", inputs: [a.lastPathComponent, b.lastPathComponent])

        let commands = ZipFilesAction().shellCommands(step: step, context: context(in: dir, files: [a, b]))
        let command = try XCTUnwrap(commands?.first)

        XCTAssertTrue(command.contains("'il mio file.png'"), "Il nome con spazi deve essere quotato: \(command)")
        XCTAssertTrue(command.contains("'l'\\''archivio.txt'"), "L'apice deve avere escape POSIX: \(command)")
        XCTAssertFalse(command.contains(" il mio file.png "), "Mai nomi non quotati nell'anteprima")
    }

    func testCompressPerFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try makeFile(in: dir, named: "a.txt")
        let b = try makeFile(in: dir, named: "b.txt")
        let step = ActionStep(id: "z2", tool: "file.compress", inputs: [a.lastPathComponent, b.lastPathComponent])

        let result = try await CompressFilesAction().execute(step: step, context: context(in: dir, files: [a, b]))

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputFiles.count, 2, "Un archivio per ciascun file")
        XCTAssertTrue(result.outputFiles.contains { $0.lastPathComponent == "a.zip" }, "Manca l'archivio per a.txt")
        XCTAssertTrue(result.outputFiles.contains { $0.lastPathComponent == "b.zip" }, "Manca l'archivio per b.txt")
    }

    // MARK: - Trash & rollback

    func testTrashAndRollbackRestores() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let name = "atl-test-\(UUID().uuidString).txt"
        let file = try makeFile(in: dir, named: name)
        let step = ActionStep(id: "t1", tool: "file.trash", inputs: [name])

        let result = try await TrashFilesAction().execute(step: step, context: context(in: dir, files: [file]))

        XCTAssertTrue(result.success, "Lo spostamento nel Cestino deve riuscire")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Il file non deve più essere nella cartella originale")
        let trashURL = try XCTUnwrap(result.backupURLs[file], "L'URL nel Cestino va tracciato come backup per l'undo")
        defer { try? FileManager.default.removeItem(at: trashURL) }

        var tx = AtlasTransaction(steps: [step])
        for (original, backup) in result.backupURLs { tx.addBackup(original: original, backup: backup) }
        _ = try tx.rollback()

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Dopo il rollback il file torna nella cartella originale")
    }
}
