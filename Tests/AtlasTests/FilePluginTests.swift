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

    func testRenameNoOpDoesNotOfferDestructiveUndo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try makeFile(in: dir, named: "a_1.txt", content: "unchanged")
        let step = ActionStep(id: "noop", tool: "file.rename", inputs: [original.lastPathComponent], format: "a_#.txt")
        let result = try await RenameFilesAction().execute(step: step, context: context(in: dir, files: [original]))
        XCTAssertTrue(result.outputFiles.isEmpty)
        XCTAssertTrue(result.backupURLs.isEmpty)
        var transaction = AtlasTransaction(steps: [step])
        transaction.incorporate(result)
        transaction.status = .success
        XCTAssertFalse(transaction.canRollback)
        try transaction.rollback()
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "unchanged")
    }

    func testRenameOverlappingSourcesPreserveContentsAndUndo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: backups) }
        BackupStore.rootOverride = backups
        let first = try makeFile(in: dir, named: "a.txt", content: "A")
        let second = try makeFile(in: dir, named: "item_1.txt", content: "B")
        let step = ActionStep(id: "overlap", tool: "file.rename", inputs: [first.lastPathComponent, second.lastPathComponent], format: "item_#.txt")
        let result = try await RenameFilesAction().execute(step: step, context: context(in: dir, files: [first, second]))
        let last = dir.appendingPathComponent("item_2.txt")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: last, encoding: .utf8), "B")
        var transaction = AtlasTransaction(steps: [step])
        transaction.incorporate(result)
        transaction.status = .success
        try transaction.rollback()
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: last.path))
    }

    func testRenameDuplicateTargetsRejectBeforeMutation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makeFile(in: dir, named: "a.txt", content: "A")
        let second = try makeFile(in: dir, named: "b.txt", content: "B")
        let target = dir.appendingPathComponent("same.txt")
        do {
            _ = try await RenameFilesAction.rename([(first, target), (second, target)])
            XCTFail("Duplicate destinations must be rejected")
        } catch let failure as ActionExecutionError {
            XCTAssertTrue(failure.partialResult.outputFiles.isEmpty)
            XCTAssertTrue(failure.partialResult.backupURLs.isEmpty)
        }
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRenameSecondPublicationFailureRetainsRecoveryJournal() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: backups) }
        BackupStore.rootOverride = backups
        let first = try makeFile(in: dir, named: "a.txt", content: "A")
        let second = try makeFile(in: dir, named: "b.txt", content: "B")
        let published = dir.appendingPathComponent("renamed.txt")
        let impossible = dir.appendingPathComponent("missing/renamed.txt")
        do {
            _ = try await RenameFilesAction.rename([(first, published), (second, impossible)])
            XCTFail("Publishing into an absent directory must fail")
        } catch let failure as ActionExecutionError {
            XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "A")
            XCTAssertTrue(failure.partialResult.outputFiles.contains { url in
                url != published && (try? String(contentsOf: url, encoding: .utf8)) == "B"
            })
            var transaction = AtlasTransaction(steps: [])
            transaction.incorporate(failure.partialResult)
            transaction.status = .failed
            XCTAssertTrue(transaction.canRollback)
            try transaction.rollback()
            XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "A")
            XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "B")
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["a.txt", "b.txt"])
        }
    }

    func testCopySecondItemFailureRollsBackFirstCopyWithoutChangingExistingFolder() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makeFile(in: dir, named: "a.txt", content: "A")
        let second = try makeFile(in: dir, named: "b.txt", content: "B")
        let folder = dir.appendingPathComponent("copie", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let retained = try makeFile(in: folder, named: "keep.txt", content: "keep")
        let step = ActionStep(id: "partial", tool: "file.copy", inputs: [first.lastPathComponent, second.lastPathComponent], format: "1")
        do {
            _ = try await CopyFilesAction().execute(step: step, context: context(in: dir, files: [first, second]), progress: { index, _, _ in
                if index == 2 { try? FileManager.default.removeItem(at: second) }
            })
            XCTFail("The second source disappeared")
        } catch let failure as ActionExecutionError {
            let copy = folder.appendingPathComponent("a_copia_1.txt")
            XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "A")
            var transaction = AtlasTransaction(steps: [step])
            transaction.incorporate(failure.partialResult)
            transaction.status = .failed
            try transaction.rollback()
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "keep")
            XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "A")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["keep.txt"])
        }
    }

    func testExplicitCopyDoesNotExpandFinderSelection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try makeFile(in: dir, named: "a.txt", content: "A")
        let second = try makeFile(in: dir, named: "b.txt", content: "B")
        let step = ActionStep(id: "scope", tool: "file.copy", inputs: ["a.txt"], format: "1")
        let result = try await CopyFilesAction().execute(step: step, context: context(in: dir, files: [first, second]))
        let folder = dir.appendingPathComponent("copie")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["a_copia_1.txt"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a_copia_1.txt"), encoding: .utf8), "A")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "B")
        XCTAssertEqual(result.outputFiles.filter { $0.pathExtension == "txt" }.count, 1)
    }

    func testMissingExplicitCopyFailsWithoutFallingBackToSelection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let selected = try makeFile(in: dir, named: "selected.txt", content: "unchanged")
        let snapshot = context(in: dir, files: [selected])
        let step = ActionStep(id: "missing", tool: "file.copy", inputs: ["missing.txt"], format: "1")
        XCTAssertThrowsError(try CopyFilesAction().validate(step: step, context: snapshot))
        do {
            _ = try await CopyFilesAction().execute(step: step, context: snapshot)
            XCTFail("An explicit missing source must fail")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["selected.txt"])
            XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "unchanged")
        }
    }

    func testResolutionPreservesFullPathsOrderAndFrozenCandidates() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let external = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: external) }
        let local = try makeFile(in: dir, named: "same.txt", content: "local")
        let remote = try makeFile(in: external, named: "same.txt", content: "external")
        let snapshot = FinderContext(currentDirectory: dir, selectedFiles: [remote, local, remote], visibleFiles: [local], installedTools: [], timestamp: Date())
        let implicit = ActionStep(id: "implicit", tool: "file.copy", inputs: [], format: "1")
        XCTAssertEqual(try InputResolver.resolve(step: implicit, context: snapshot), [remote, local])
        let explicit = ActionStep(id: "explicit", tool: "file.copy", inputs: [remote.path, "same.txt", remote.absoluteString], format: "1")
        XCTAssertEqual(try InputResolver.resolve(step: explicit, context: snapshot), [remote, local])
        let visibleSnapshot = FinderContext(currentDirectory: dir, selectedFiles: [], visibleFiles: [local], installedTools: [], timestamp: Date())
        _ = try makeFile(in: dir, named: "appeared-later.txt")
        XCTAssertEqual(try InputResolver.resolve(step: implicit, context: visibleSnapshot), [local])
        let directoryStep = ActionStep(id: "directory", tool: "file.copy", inputs: [external.path], format: "1")
        XCTAssertThrowsError(try CopyFilesAction().validate(step: directoryStep, context: snapshot))
        XCTAssertEqual(try InputResolver.resolve(step: directoryStep, context: snapshot, allowDirectories: true), [external])
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
        XCTAssertEqual(result.outputFiles.filter { $0.pathExtension == "pdf" }.count, 3)
        let copieDir = dir.appendingPathComponent("copie", isDirectory: true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: copieDir.path).count, 3, "Le copie vanno nella cartella 'copie'")

        // 2 copie nella cartella 'backup'
        let stepNamed = ActionStep(id: "c2", tool: "file.copy", inputs: ["relazione.pdf"], format: "2;backup")
        let result2 = try await CopyFilesAction().execute(step: stepNamed, context: context(in: dir, files: [source]))
        XCTAssertEqual(result2.outputFiles.filter { $0.pathExtension == "pdf" }.count, 2)
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

    private func zipMember(_ member: String, in archive: URL) async throws -> String {
        // unzip accepts glob patterns; bracket the leading dash so it is not an option.
        let pattern = member.hasPrefix("-") ? "[-]" + member.dropFirst() : member
        let result = try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/unzip"),
            arguments: ["-p", archive.path, pattern]
        )
        XCTAssertTrue(result.isSuccess, result.stderr)
        return result.stdout
    }

    func testZipPreservesRelativeHierarchyInsteadOfRootNamesake() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let root = try makeFile(in: dir, named: "a.txt", content: "root")
        let nested = try makeFile(in: sub, named: "a.txt", content: "nested")
        let step = ActionStep(id: "z1", tool: "file.zip", inputs: ["sub/a.txt", "a.txt"])
        let result = try await ZipFilesAction().execute(step: step, context: context(in: dir, files: [root, nested]))
        let archive = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(result.outputFiles.count, 1)
        let nestedContent = try await zipMember("sub/a.txt", in: archive)
        let rootContent = try await zipMember("a.txt", in: archive)
        XCTAssertEqual(nestedContent, "nested")
        XCTAssertEqual(rootContent, "root")
    }

    func testZipExternalSourceUsesItsBytesAndCleansOnlyStaging() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let external = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: external) }
        let rootNamesake = try makeFile(in: dir, named: "outside.txt", content: "not requested")
        let source = try makeFile(in: external, named: "outside.txt", content: "external bytes")
        let local = try makeFile(in: dir, named: "local.txt", content: "local bytes")
        let step = ActionStep(id: "external", tool: "file.zip", inputs: ["local.txt", source.path])
        let result = try await ZipFilesAction().execute(step: step, context: context(in: dir, files: [local, rootNamesake]))
        let archive = try XCTUnwrap(result.outputFiles.first)
        let externalContent = try await zipMember("outside.txt", in: archive)
        let localContent = try await zipMember("local.txt", in: archive)
        XCTAssertEqual(externalContent, "external bytes")
        XCTAssertEqual(localContent, "local bytes")
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "external bytes")
        XCTAssertEqual(try String(contentsOf: rootNamesake, encoding: .utf8), "not requested")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["local.txt", "outside.txt", archive.lastPathComponent])
    }

    func testZipDuplicateExternalBasenamesRejectBeforeAnyArchive() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let external = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: external) }
        let local = try makeFile(in: dir, named: "same.txt", content: "local")
        let remote = try makeFile(in: external, named: "same.txt", content: "external")
        let snapshot = context(in: dir, files: [local, remote])
        let executors: [any ActionExecutor] = [ZipFilesAction(), CompressFilesAction()]
        for executor in executors {
            let step = ActionStep(id: "duplicates", tool: "file.zip", inputs: [local.path, remote.path])
            XCTAssertThrowsError(try executor.validate(step: step, context: snapshot))
            do {
                _ = try await executor.execute(step: step, context: snapshot)
                XCTFail("Duplicate basenames must fail before zip starts")
            } catch {
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["same.txt"])
                XCTAssertEqual(try String(contentsOf: local, encoding: .utf8), "local")
                XCTAssertEqual(try String(contentsOf: remote, encoding: .utf8), "external")
            }
        }
    }

    func testZipPreviewAndExecutionPreserveQuotedAndDashLeadingNames() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try ["il mio file.png", "l'archivio.txt", "-options.txt"].map {
            try makeFile(in: dir, named: $0, content: $0)
        }
        let step = ActionStep(id: "quoted", tool: "file.zip", inputs: files.map(\.lastPathComponent))
        let snapshot = context(in: dir, files: files)
        let commands = try XCTUnwrap(ZipFilesAction().shellCommands(step: step, context: snapshot))
        let previewResult = try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", commands.joined(separator: " && ")]
        )
        XCTAssertTrue(previewResult.isSuccess, previewResult.stderr)
        let actual = try await ZipFilesAction().execute(step: step, context: snapshot)
        let executedArchive = try XCTUnwrap(actual.outputFiles.first)
        for archive in [dir.appendingPathComponent("archive.zip"), executedArchive] {
            for file in files {
                let content = try await zipMember(file.lastPathComponent, in: archive)
                XCTAssertEqual(content, file.lastPathComponent)
            }
        }
    }

    func testCompressPerFilePreservesNestedAndExternalContent() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let external = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: external) }
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let a = try makeFile(in: sub, named: "a.txt", content: "nested")
        _ = try makeFile(in: dir, named: "a.txt", content: "wrong root")
        let b = try makeFile(in: external, named: "-b.txt", content: "external")
        let step = ActionStep(id: "compress", tool: "file.compress", inputs: ["sub/a.txt", b.path])
        let result = try await CompressFilesAction().execute(step: step, context: context(in: dir, files: [a, b]))
        XCTAssertEqual(result.outputFiles.count, 2)
        let first = try XCTUnwrap(result.outputFiles.first { $0.lastPathComponent == "a.zip" })
        let second = try XCTUnwrap(result.outputFiles.first { $0.lastPathComponent == "-b.zip" })
        let nestedContent = try await zipMember("sub/a.txt", in: first)
        let externalContent = try await zipMember("-b.txt", in: second)
        XCTAssertEqual(nestedContent, "nested")
        XCTAssertEqual(externalContent, "external")
    }

    // MARK: - Trash & rollback

    func testTrashAndRollbackRestores() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backupRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: backupRoot) }
        BackupStore.rootOverride = backupRoot

        let name = "atl-test-\(UUID().uuidString).txt"
        let file = try makeFile(in: dir, named: name)
        let step = ActionStep(id: "t1", tool: "file.trash", inputs: [name])

        let result = try await TrashFilesAction().execute(step: step, context: context(in: dir, files: [file]))

        XCTAssertTrue(result.success, "Lo spostamento nel Cestino deve riuscire")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Il file non deve più essere nella cartella originale")
        XCTAssertNotNil(result.backupURLs[file])
        defer { for url in result.outputFiles { try? FileManager.default.removeItem(at: url) } }

        var tx = AtlasTransaction(steps: [step])
        for output in result.outputFiles { tx.addCreated(url: output) }
        for (original, backup) in result.backupURLs { tx.addBackup(original: original, backup: backup) }
        _ = try tx.rollback()

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "contenuto")
    }
}
