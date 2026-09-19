import XCTest
@testable import Atlas

final class TransactionExtraTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Rollback: backup mancante

    func testRollbackThrowsOnMissingBackup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let original = dir.appendingPathComponent("perso.txt")
        try "contenuto".write(to: original, atomically: true, encoding: .utf8)
        let phantomBackup = dir.appendingPathComponent("backup-inesistente.txt")

        var tx = AtlasTransaction(steps: [])
        tx.addBackup(original: original, backup: phantomBackup)

        XCTAssertThrowsError(try tx.rollback(), "Un backup assente deve far fallire il rollback") { error in
            guard let rollbackError = error as? RollbackError else {
                return XCTFail("Era atteso RollbackError, ricevuto: \(error)")
            }
            XCTAssertTrue(rollbackError.failures.contains { $0.contains("Backup mancante") }, "Il messaggio deve segnalare il backup mancante: \(rollbackError.failures)")
        }
    }

    // MARK: - Retryable rollback

    private struct FailingReplace: RollbackFileOperations {
        let real = FoundationRollbackFileOperations()
        func copyItem(at source: URL, to destination: URL) throws { try real.copyItem(at: source, to: destination) }
        func moveItem(at source: URL, to destination: URL) throws { try real.moveItem(at: source, to: destination) }
        func removeItem(at url: URL) throws { try real.removeItem(at: url) }
        func fileExists(at url: URL) -> Bool { real.fileExists(at: url) }
        func replaceItem(at original: URL, with replacement: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    func testRollbackFailurePreservesOriginalAndBackup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = dir.appendingPathComponent("original.txt")
        let backup = dir.appendingPathComponent("backup.txt")
        let current = Data("nuovo".utf8)
        let previous = Data("precedente".utf8)
        try current.write(to: original)
        try previous.write(to: backup)
        var tx = AtlasTransaction(steps: [])
        tx.status = .success
        tx.completedAt = Date(timeIntervalSince1970: 1234)
        tx.addCreated(url: original)
        tx.addBackup(original: original, backup: backup)

        XCTAssertThrowsError(try tx.rollback(fileOperations: FailingReplace())) { error in
            XCTAssertTrue(error is RollbackError)
        }
        XCTAssertEqual(try Data(contentsOf: original), current)
        XCTAssertEqual(try Data(contentsOf: backup), previous)
        XCTAssertEqual(tx.status, .rollbackFailed)
        XCTAssertTrue(tx.canRollback)
        XCTAssertEqual(tx.backupURLs[original], backup)
        XCTAssertEqual(tx.createdURLs, [original])

        tx = try JSONDecoder().decode(AtlasTransaction.self, from: JSONEncoder().encode(tx))
        let result = try tx.rollback()
        XCTAssertEqual(result.restoredFilesCount, 1)
        XCTAssertEqual(result.deletedFilesCount, 0)
        XCTAssertEqual(try Data(contentsOf: original), previous)
        XCTAssertEqual(tx.status, .rolledBack)
        XCTAssertEqual(tx.completedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertTrue(tx.backupURLs.isEmpty)
        XCTAssertTrue(tx.createdURLs.isEmpty)
        XCTAssertFalse(tx.canRollback)
        XCTAssertThrowsError(try tx.rollback())
        XCTAssertEqual(try Data(contentsOf: original), previous)
    }

    func testPartialFailureRetainsOnlyUnfinishedWork() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let created = dir.appendingPathComponent("created.txt")
        let original = dir.appendingPathComponent("original.txt")
        let backup = dir.appendingPathComponent("missing.txt")
        try Data("output".utf8).write(to: created)
        var tx = AtlasTransaction(steps: [])
        tx.addCreated(url: created)
        tx.addCreated(url: created)
        tx.addBackup(original: original, backup: backup)
        XCTAssertThrowsError(try tx.rollback())
        XCTAssertEqual(tx.status, .rollbackFailed)
        XCTAssertTrue(tx.createdURLs.isEmpty)
        XCTAssertEqual(tx.backupURLs[original], backup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
        // A new file at the recovered path must not be deleted by retry.
        try Data("unrelated".utf8).write(to: created)
        try Data("previous".utf8).write(to: backup)
        let result = try tx.rollback()
        XCTAssertEqual(result.deletedFilesCount, 0)
        XCTAssertEqual(result.restoredFilesCount, 1)
        XCTAssertEqual(try Data(contentsOf: original), Data("previous".utf8))
        XCTAssertEqual(try Data(contentsOf: created), Data("unrelated".utf8))
        XCTAssertEqual(tx.status, .rolledBack)
    }

    // MARK: - Codable roundtrip

    func testCodableRoundtripPreservesFields() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var tx = AtlasTransaction(steps: [
            ActionStep(id: "s1", tool: "file.rename", inputs: ["a.jpg"], format: "b#.jpg"),
        ])
        tx.query = "rinomina in b"
        tx.summary = "file.rename"
        tx.resultMessage = "Rinominato 1 file"
        tx.status = .success
        tx.completedAt = Date()
        tx.createdURLs = [dir.appendingPathComponent("b1.jpg")]
        tx.backupURLs = [dir.appendingPathComponent("a.jpg"): dir.appendingPathComponent("bk").appendingPathComponent("a.jpg")]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(tx)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AtlasTransaction.self, from: data)

        XCTAssertEqual(decoded.id, tx.id, "L'id sopravvive al roundtrip")
        XCTAssertEqual(decoded.steps.map(\.id), tx.steps.map(\.id))
        XCTAssertEqual(decoded.query, tx.query)
        XCTAssertEqual(decoded.summary, tx.summary)
        XCTAssertEqual(decoded.resultMessage, tx.resultMessage)
        XCTAssertEqual(decoded.status, tx.status)
        XCTAssertEqual(decoded.createdURLs, tx.createdURLs, "Le URL create vanno preservate")
        XCTAssertEqual(decoded.backupURLs.keys.map(\.path).sorted(), tx.backupURLs.keys.map(\.path).sorted(), "Le chiavi dei backup (originali) vanno preservate")
        for (original, backup) in tx.backupURLs {
            XCTAssertEqual(decoded.backupURLs[original]?.path, backup.path, "La coppia originale→backup va ricostruita fedelmente")
        }
    }

    // MARK: - ActionGraph

    func testEmptyGraphSortsToEmpty() throws {
        let sorted = try ActionGraph(steps: []).topologicallySorted()
        XCTAssertTrue(sorted.steps.isEmpty, "Un grafo vuoto ordina a array vuoto")
    }

    func testDuplicateStepIDsThrowInsteadOfCrashing() {
        let graph = ActionGraph(steps: [
            ActionStep(id: "doppio", tool: "image.convert", inputs: [], format: "webp"),
            ActionStep(id: "doppio", tool: "image.convert", inputs: [], format: "jpg"),
        ])

        XCTAssertThrowsError(try graph.topologicallySorted(), "Id duplicati devono produrre un errore di validazione, non un crash") { error in
            guard case ExecutorError.validationFailed(let message) = error else {
                return XCTFail("Era atteso validationFailed, ricevuto: \(error)")
            }
            XCTAssertTrue(message.contains("ID passo duplicato") && message.contains("doppio"), "Il messaggio deve citare l'id duplicato: \(message)")
        }
    }

    // MARK: - outputName(for:)

    func testOutputNameReplacesExtension() {
        let withFormat = ActionStep(id: "o1", tool: "image.convert", inputs: [], format: "webp")
        XCTAssertEqual(withFormat.outputName(for: "foto.jpg"), "foto.webp", "Il format sostituisce l'estensione")

        let withoutFormat = ActionStep(id: "o2", tool: "file.copy", inputs: [])
        XCTAssertEqual(withoutFormat.outputName(for: "foto.jpg"), "foto.jpg", "Senza format l'input resta invariato")
    }
}
