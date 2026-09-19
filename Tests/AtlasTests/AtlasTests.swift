import XCTest
@testable import Atlas

final class AtlasTests: XCTestCase {
    
    // MARK: - InstantActionParser
    
    func testImageFormatShorthand() throws {
        let context = FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: [],
            visibleFiles: [URL(fileURLWithPath: "/tmp/foto.png")],
            installedTools: [],
            timestamp: Date()
        )
        
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "webp", context: context))
        XCTAssertEqual(graph.steps.count, 1)
        XCTAssertEqual(graph.steps[0].tool, "image.convert")
        XCTAssertEqual(graph.steps[0].format, "webp")
        XCTAssertEqual(graph.steps[0].inputs, ["foto.png"])
    }
    
    func testJpegNormalizedToJpg() throws {
        let context = FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: [URL(fileURLWithPath: "/tmp/foto.jpeg")],
            visibleFiles: [],
            installedTools: [],
            timestamp: Date()
        )
        
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "jpeg", context: context))
        XCTAssertEqual(graph.steps[0].format, "jpg")
    }
    
    func testNaturalLanguagePhrasesDeferToLLM() {
        let context = parserContext(
            selected: [URL(fileURLWithPath: "/tmp/foto.png")],
            visible: [URL(fileURLWithPath: "/tmp/foto.png"), URL(fileURLWithPath: "/tmp/doc.pdf")]
        )
        
        let naturalLanguageQueries = [
            "seleziona le foto",
            "seleziona foto",
            "seleziona tutti i file",
            "seleziona i pdf",
            "comprimi le foto",
            "comprimi immagini",
            "comprimi i file",
            "unisci pdf",
            "unisci i pdf",
            "bianco e nero",
            "bw",
            "foto in bianco e nero",
            "immagini in pdf",
            "ocr rename",
            "rinomina per contenuto",
            "fai una cartella caccona galattica",
            "converti le immagini in jpg",
            "select all images",
            "zip em up",
            "mp3",
            "mp4"
        ]
        
        for query in naturalLanguageQueries {
            XCTAssertNil(InstantActionParser.parse(query: query, context: context),
                         "Query '\(query)' deve essere gestita dall'LLM e non da frasi hardcodate locali")
        }
    }
    
    private func parserContext(selected: [URL] = [], visible: [URL] = []) -> FinderContext {
        FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: selected,
            visibleFiles: visible,
            installedTools: [],
            timestamp: Date()
        )
    }

    // MARK: - InstantActionParser: precedenza di resolveInputs

    func testSelectionTakesPrecedenceOverVisibleFiles() throws {
        let context = parserContext(
            selected: [URL(fileURLWithPath: "/tmp/sel.png")],
            visible: [
                URL(fileURLWithPath: "/tmp/sel.png"),
                URL(fileURLWithPath: "/tmp/visibile.webp"),
            ]
        )

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "webp", context: context))
        XCTAssertEqual(graph.steps[0].inputs, ["sel.png"], "Con una selezione attiva si ignorano gli altri file visibili")
    }

    func testEmptySelectionFallsBackToVisibleFilteredByExtensions() throws {
        let context = parserContext(visible: [
            URL(fileURLWithPath: "/tmp/foto.heic"),
            URL(fileURLWithPath: "/tmp/note.txt"),
        ])

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "jpg", context: context))
        XCTAssertEqual(graph.steps[0].inputs, ["foto.heic"], "Senza selezione si usano i visibili filtrati per estensione convertibile")
    }

    func testLocalParserPreservesExternalSourcePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = directory.appendingPathComponent("external/photo.png")
        let context = FinderContext(currentDirectory: directory.appendingPathComponent("working"), selectedFiles: [external], visibleFiles: [], installedTools: [], timestamp: Date())
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "jpg", context: context))
        XCTAssertEqual(graph.steps[0].inputs, [external.path])
    }
    
    // MARK: - FinderSelector
    
    func testAppleScriptLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(FinderSelector.appleScriptLiteral("pippo\"jpg"), "\"pippo\\\"jpg\"")
        XCTAssertEqual(FinderSelector.appleScriptLiteral(#"a\b"#), #""a\\b""#)
    }
    
    func testSelectScriptUsesSelectCommandAndResolvesAliasesOutsideTell() {
        let script = FinderSelector.buildSelectScript(
            directory: URL(fileURLWithPath: "/tmp/foto"),
            files: [URL(fileURLWithPath: "/tmp/foto/a.jpg"), URL(fileURLWithPath: "/tmp/foto/b.jpg")]
        )
        
        XCTAssertTrue(script.contains(#"set end of theItems to (POSIX file thePath as alias)"#))
        XCTAssertTrue(script.contains("select theItems"))
        XCTAssertTrue(script.contains(#"tell application "Finder""#))
        XCTAssertLessThan(script.range(of: #"tell application "Finder""#)!.lowerBound, script.range(of: "select theItems")!.lowerBound)
    }
    
    // MARK: - ActionGraph.topologicallySorted
    
    func testTopologicalSortHonorsDependencies() throws {
        let graph = ActionGraph(steps: [
            ActionStep(id: "step_3", tool: "image.convert", inputs: [], format: "webp", dependsOn: ["step_1"]),
            ActionStep(id: "step_2", tool: "file.zip", inputs: [], dependsOn: ["step_1"]),
            ActionStep(id: "step_1", tool: "image.convert", inputs: []),
        ])
        
        let sorted = try graph.topologicallySorted()
        XCTAssertEqual(sorted.steps.map(\.id), ["step_1", "step_3", "step_2"])
    }
    
    func testTopologicalSortThrowsOnCycle() {
        let graph = ActionGraph(steps: [
            ActionStep(id: "a", tool: "image.convert", inputs: [], dependsOn: ["b"]),
            ActionStep(id: "b", tool: "image.convert", inputs: [], dependsOn: ["a"]),
        ])
        
        XCTAssertThrowsError(try graph.topologicallySorted())
    }
    
    func testTopologicalSortThrowsOnUnknownDependency() {
        let graph = ActionGraph(steps: [
            ActionStep(id: "a", tool: "image.convert", inputs: [], dependsOn: ["fantasma"]),
        ])
        
        XCTAssertThrowsError(try graph.topologicallySorted())
    }
}
