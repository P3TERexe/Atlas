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
    
    func testGrayscaleShorthand() throws {
        let context = FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: [URL(fileURLWithPath: "/tmp/foto.png")],
            visibleFiles: [],
            installedTools: [],
            timestamp: Date()
        )
        
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "bw", context: context))
        XCTAssertEqual(graph.steps[0].tool, "image.convert")
        XCTAssertEqual(graph.steps[0].grayscale, true)
    }
    
    func testPDFMergeRequiresTwoFiles() {
        let context = FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: [URL(fileURLWithPath: "/tmp/a.pdf")],
            visibleFiles: [],
            installedTools: [],
            timestamp: Date()
        )
        
        XCTAssertNil(InstantActionParser.parse(query: "unisci pdf", context: context))
    }
    
    func testCompressRequestZipsAllSelected() throws {
        let context = FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: [URL(fileURLWithPath: "/tmp/a.txt"), URL(fileURLWithPath: "/tmp/b.png")],
            visibleFiles: [],
            installedTools: [],
            timestamp: Date()
        )
        
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "comprimi i file", context: context))
        XCTAssertEqual(graph.steps[0].tool, "file.zip")
        XCTAssertEqual(graph.steps[0].format, "archive.zip")
        XCTAssertEqual(graph.steps[0].inputs.count, 2)
    }
    
    func testUnknownQueryFallsBackToLLM() {
        let context = FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: [],
            visibleFiles: [],
            installedTools: [],
            timestamp: Date()
        )
        
        XCTAssertNil(InstantActionParser.parse(query: "riordina la cartella per data", context: context))
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

    // MARK: - InstantActionParser: shorthand video

    func testAudioExtractionShorthands() throws {
        let context = parserContext(visible: [URL(fileURLWithPath: "/tmp/video.mp4")])

        let mp3 = try XCTUnwrap(InstantActionParser.parse(query: "mp3", context: context))
        XCTAssertEqual(mp3.steps[0].tool, "video.extractAudio")
        XCTAssertEqual(mp3.steps[0].format, "mp3")
        XCTAssertEqual(mp3.steps[0].inputs, ["video.mp4"])

        let m4a = try XCTUnwrap(InstantActionParser.parse(query: "m4a", context: context))
        XCTAssertEqual(m4a.steps[0].tool, "video.extractAudio")
        XCTAssertEqual(m4a.steps[0].format, "m4a")
    }

    func testVideoConversionShorthands() throws {
        let context = parserContext(visible: [URL(fileURLWithPath: "/tmp/clip.mov")])

        let mp4 = try XCTUnwrap(InstantActionParser.parse(query: "mp4", context: context))
        XCTAssertEqual(mp4.steps[0].tool, "video.convert")
        XCTAssertEqual(mp4.steps[0].format, "mp4")
        XCTAssertEqual(mp4.steps[0].inputs, ["clip.mov"])

        let mov = try XCTUnwrap(InstantActionParser.parse(query: "mov", context: context))
        XCTAssertEqual(mov.steps[0].tool, "video.convert")
        XCTAssertEqual(mov.steps[0].format, "mov")
    }

    // MARK: - InstantActionParser: OCR

    func testOCRShorthands() throws {
        let context = parserContext(visible: [URL(fileURLWithPath: "/tmp/scansione.png")])

        for query in ["ocr", "rinomina ocr", "rinomina per contenuto"] {
            let graph = try XCTUnwrap(InstantActionParser.parse(query: query, context: context), "'\(query)' deve essere riconosciuto come shorthand OCR")
            XCTAssertEqual(graph.steps[0].tool, "image.ocrRename", "Query '\(query)' → image.ocrRename")
            XCTAssertEqual(graph.steps[0].inputs, ["scansione.png"])
        }
    }

    // MARK: - InstantActionParser: PDF

    func testImagesToPDFShorthandUsesCombinedFormat() throws {
        let context = parserContext(visible: [
            URL(fileURLWithPath: "/tmp/pagina1.png"),
            URL(fileURLWithPath: "/tmp/pagina2.png"),
        ])

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "immagini in pdf", context: context))
        XCTAssertEqual(graph.steps[0].tool, "pdf.fromImages")
        XCTAssertEqual(graph.steps[0].format, "combined.pdf")
    }

    func testCompressPDFShorthand() throws {
        let context = parserContext(visible: [URL(fileURLWithPath: "/tmp/doc.pdf")])

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "comprimi pdf", context: context))
        XCTAssertEqual(graph.steps[0].tool, "pdf.compress")
        XCTAssertEqual(graph.steps[0].inputs, ["doc.pdf"])
    }

    func testMergePDFShorthandWithTwoSelectedFiles() throws {
        let context = parserContext(selected: [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ])

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "unisci pdf", context: context), "Con due PDF selezionati 'unisci pdf' produce un piano")
        XCTAssertEqual(graph.steps[0].tool, "pdf.merge")
        XCTAssertEqual(graph.steps[0].inputs.count, 2)
    }

    // MARK: - InstantActionParser: selezione

    func testSelectPhotosShorthandFiltersImages() throws {
        let context = parserContext(visible: [
            URL(fileURLWithPath: "/tmp/foto.png"),
            URL(fileURLWithPath: "/tmp/doc.pdf"),
        ])

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "seleziona le foto", context: context))
        XCTAssertEqual(graph.steps[0].tool, "file.select")
        XCTAssertEqual(graph.steps[0].inputs, ["foto.png"], "Solo le immagini passano il filtro estensioni")
    }

    func testSelectPDFsShorthand() throws {
        let context = parserContext(visible: [
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
        ])

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "seleziona i pdf", context: context))
        XCTAssertEqual(graph.steps[0].tool, "file.select")
        XCTAssertEqual(graph.steps[0].inputs, ["a.pdf"])
    }

    func testSelectAllFilesShorthandHasNoExtensionFilter() throws {
        let context = parserContext(visible: [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.zip"),
        ])

        let graph = try XCTUnwrap(InstantActionParser.parse(query: "seleziona tutti i file", context: context))
        XCTAssertEqual(graph.steps[0].tool, "file.select")
        XCTAssertNil(graph.steps[0].format)
        XCTAssertEqual(Set(graph.steps[0].inputs), ["a.txt", "b.zip"], "Senza filtro estensioni prende tutti i candidati")
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
