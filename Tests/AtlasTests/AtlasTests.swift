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

    func testQualifiedCompressionDefersToModel() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = FinderContext(currentDirectory: directory, selectedFiles: [], visibleFiles: [directory.appendingPathComponent("photo.png")], installedTools: [], timestamp: Date())
        XCTAssertNil(InstantActionParser.parse(query: "comprimi le immagini a qualità 50", context: context))
        XCTAssertNil(InstantActionParser.parse(query: "comprimi i file tranne photo.png", context: context))
    }

    func testPhotoCompressionExcludesNonImages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let context = FinderContext(currentDirectory: directory, selectedFiles: [directory.appendingPathComponent("photo.png"), directory.appendingPathComponent("note.txt")], visibleFiles: [], installedTools: [], timestamp: Date())
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "comprimi le immagini", context: context))
        XCTAssertEqual(graph.steps[0].tool, "file.zip")
        XCTAssertEqual(graph.steps[0].inputs, ["photo.png"])
    }

    func testSelectAllUsesVisibleFilesDespitePartialSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let selected = directory.appendingPathComponent("one.png")
        let context = FinderContext(currentDirectory: directory, selectedFiles: [selected], visibleFiles: [selected, directory.appendingPathComponent("two.jpg"), directory.appendingPathComponent("note.txt")], installedTools: [], timestamp: Date())
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "select all images", context: context))
        XCTAssertEqual(graph.steps[0].inputs, ["one.png", "two.jpg"])
    }

    func testLocalParserPreservesExternalSourcePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = directory.appendingPathComponent("external/photo.png")
        let context = FinderContext(currentDirectory: directory.appendingPathComponent("working"), selectedFiles: [external], visibleFiles: [], installedTools: [], timestamp: Date())
        let graph = try XCTUnwrap(InstantActionParser.parse(query: "jpg", context: context))
        XCTAssertEqual(graph.steps[0].inputs, [external.path])
    }

    func testNaturalLanguageInstantActionParsing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let photo1 = directory.appendingPathComponent("img1.png")
        let photo2 = directory.appendingPathComponent("img2.jpg")
        let context = FinderContext(currentDirectory: directory, selectedFiles: [photo1, photo2], visibleFiles: [photo1, photo2], installedTools: [], timestamp: Date())

        // 1. "converti le immagini in jpg"
        let g1 = try XCTUnwrap(InstantActionParser.parse(query: "converti le immagini in jpg", context: context))
        XCTAssertEqual(g1.steps[0].tool, "image.convert")
        XCTAssertEqual(g1.steps[0].format, "jpg")

        // 2. "converti in bianco e nero"
        let g2 = try XCTUnwrap(InstantActionParser.parse(query: "converti in bianco e nero", context: context))
        XCTAssertEqual(g2.steps[0].tool, "image.convert")
        XCTAssertTrue(g2.steps[0].grayscale ?? false)

        // 3. "fai una cartella Progetti"
        let g3 = try XCTUnwrap(InstantActionParser.parse(query: "fai una cartella Progetti", context: context))
        XCTAssertEqual(g3.steps[0].tool, "file.mkdir")
        XCTAssertEqual(g3.steps[0].format, "Progetti")

        // 4. "sposta le foto in Archivio"
        let g4 = try XCTUnwrap(InstantActionParser.parse(query: "sposta le foto in Archivio", context: context))
        XCTAssertEqual(g4.steps[0].tool, "file.move")
        XCTAssertEqual(g4.steps[0].format, "Archivio")

        // 5. Composite: folder + bw
        let g5 = try XCTUnwrap(InstantActionParser.parse(query: "fai una cartella e aggiungi una versione in bianco e nero di tutte le foto la cartella deve chiamarsi caccona galattica", context: context))
        XCTAssertEqual(g5.steps.count, 3)
        XCTAssertEqual(g5.steps[0].tool, "file.mkdir")
        XCTAssertEqual(g5.steps[0].format, "caccona galattica")
        XCTAssertEqual(g5.steps[1].tool, "image.convert")
        XCTAssertTrue(g5.steps[1].grayscale ?? false)
        XCTAssertEqual(g5.steps[2].tool, "file.move")
        XCTAssertEqual(g5.steps[2].format, "caccona galattica")
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
