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
