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

    // MARK: - Rollback: semantica parziale fissata in test

    func testPartialFailureStillMarksRolledBack() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Un created eliminabile e un backup mancante: rollback parziale.
        let created = dir.appendingPathComponent("creato.txt")
        try "output".write(to: created, atomically: true, encoding: .utf8)
        let original = dir.appendingPathComponent("irrecuperabile.txt")
        let phantomBackup = dir.appendingPathComponent("niente.txt")

        var tx = AtlasTransaction(steps: [])
        tx.addCreated(url: created)
        tx.addBackup(original: original, backup: phantomBackup)

        XCTAssertThrowsError(try tx.rollback(), "Con almeno un fallimento il rollback lancia RollbackError")
        XCTAssertEqual(tx.status, .rolledBack, "Lo stato passa a rolledBack anche su rollback parziale (comportamento attuale, da preservare consapevolmente)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path), "Il file creato viene comunque eliminato dalla parte riuscita del rollback")
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
