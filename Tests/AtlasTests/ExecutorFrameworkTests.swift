import XCTest
@testable import Atlas

@MainActor
final class ExecutorFrameworkTests: XCTestCase {

    // MARK: - Fixtures

    /// Root unica per l'intera suite: `HistoryStore.shared` cattura il fileURL
    /// alla prima inizializzazione, quindi l'override deve restare stabile
    /// tra i test della classe.
    private static var storeRoot: URL?

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func context(in directory: URL) -> FinderContext {
        FinderContext(
            currentDirectory: directory,
            selectedFiles: [],
            visibleFiles: [],
            installedTools: [],
            timestamp: Date()
        )
    }

    private static func realStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Atlas", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private var realStoreMTimeAtStart: Date?

    override func setUp() async throws {
        try await super.setUp()
        if ExecutorFrameworkTests.storeRoot == nil {
            ExecutorFrameworkTests.storeRoot = try makeTempDir()
        }
        HistoryStore.directoryOverride = ExecutorFrameworkTests.storeRoot

        // Timestamp del vero history.json (se esiste): non deve cambiare.
        let realURL = Self.realStoreURL()
        realStoreMTimeAtStart = (try? FileManager.default.attributesOfItem(atPath: realURL.path))?[.modificationDate] as? Date
    }

    override func tearDown() async throws {
        // Il record finito nei test deve essere atterrato nella dir iniettata…
        let overridden = try XCTUnwrap(ExecutorFrameworkTests.storeRoot)
        let storeFile = overridden.appendingPathComponent("Atlas").appendingPathComponent("history.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeFile.path), "history.json deve vivere nella directory iniettata, non in quella reale")

        // …e quello reale non deve essere stato toccato.
        let realURL = Self.realStoreURL()
        if let before = realStoreMTimeAtStart,
           let after = (try? FileManager.default.attributesOfItem(atPath: realURL.path))?[.modificationDate] as? Date {
            XCTAssertEqual(before, after, "Il vero ~/Library/Application Support/Atlas/history.json non deve essere modificato dai test")
        }

        HistoryStore.directoryOverride = nil
        try await super.tearDown()
    }

    private func lastRecordedTransaction() -> AtlasTransaction? {
        HistoryStore.shared.transactions.first
    }

    // MARK: - Tool inesistente

    func testUnknownToolFailsAndRecords() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "nope", inputs: []),
        ])

        do {
            _ = try await ExecutorFramework().execute(graph: graph, context: context(in: dir))
            XCTFail("Un tool inesistente deve far fallire l'esecuzione")
        } catch {
            guard case ExecutorError.toolNotFound(let tool) = error else {
                XCTFail("Era atteso toolNotFound, ricevuto: \(error)")
                return
            }
            XCTAssertEqual(tool, "nope")
        }

        let recorded = lastRecordedTransaction()
        XCTAssertEqual(recorded?.status, .failed, "La transazione fallita va registrata in cronologia")
        XCTAssertEqual(recorded?.resultMessage, "Tool non trovato: nope")
    }

    // MARK: - Validazione fallita

    func testValidationFailureRecordsTransaction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "shell.run", inputs: [], format: "rm -rf /"),
        ])

        do {
            _ = try await ExecutorFramework().execute(graph: graph, context: context(in: dir), query: "ripulisci tutto")
            XCTFail("Un comando bloccato da ShellGuard deve fallire la validazione")
        } catch {
            guard case ExecutorError.validationFailed = error else {
                XCTFail("Era atteso validationFailed, ricevuto: \(error)")
                return
            }
        }

        let recorded = lastRecordedTransaction()
        XCTAssertEqual(recorded?.status, .failed, "Anche il fallimento di validazione va registrato")
        XCTAssertEqual(recorded?.query, "ripulisci tutto", "La query utente viene allegata alla transazione")
    }

    // MARK: - Successo con undo registrato

    func testSuccessRegistersUndoAndHistory() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "shell.calc", inputs: [], format: "5 * 12"),
        ])

        let transaction = try await ExecutorFramework().execute(graph: graph, context: context(in: dir))

        XCTAssertEqual(transaction.status, .success)
        XCTAssertNotNil(transaction.resultMessage, "Il calcolo deve produrre un messaggio col risultato")
        XCTAssertTrue(transaction.resultMessage?.contains("60") == true, "bc deve valutare 5 * 12 = 60: \(transaction.resultMessage ?? "nil")")

        let recorded = lastRecordedTransaction()
        XCTAssertEqual(recorded?.id, transaction.id, "L'ultima transazione registrata è quella appena eseguita")
        XCTAssertEqual(recorded?.status, .success, "Il successo va registrato in cronologia (base dell'undo ⌘⇧Z)")
        XCTAssertEqual(recorded?.summary, "shell.calc")
    }
}
