import XCTest
@testable import Atlas

@MainActor
final class PlanValidatorTests: XCTestCase {
    private func withContext(_ names: [String], body: (FinderContext) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try names.map { name in
            let url = directory.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
            return url
        }
        try body(FinderContext(currentDirectory: directory, selectedFiles: [], visibleFiles: urls, installedTools: [], timestamp: Date()))
    }

    func testSourceExtensionDoesNotOverrideRequestedConversion() throws {
        try withContext(["foto.png"]) { context in
            let graph = ActionGraph(steps: [ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "jpg")])
            try PlanValidator.validate(graph: graph, query: "converti foto.png in jpg", context: context)
            try PlanValidator.validate(graph: graph, query: "convert selected images to jpg", context: context)
        }
    }

    func testEmptyPlanAndUnknownToolAreRejected() throws {
        try withContext([]) { context in
            XCTAssertThrowsError(try PlanValidator.validate(graph: ActionGraph(steps: []), query: "anything", context: context)) {
                guard case PlanValidationError.emptyPlan = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            let graph = ActionGraph(steps: [ActionStep(id: "s1", tool: "unknown.tool")])
            XCTAssertThrowsError(try PlanValidator.validate(graph: graph, query: "anything", context: context)) {
                guard case PlanValidationError.toolNotFound("unknown.tool") = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testCanonicalSelectionRejectsModification() throws {
        try withContext(["foto.png"]) { context in
            let graph = ActionGraph(steps: [ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "jpg")])
            XCTAssertThrowsError(try PlanValidator.validate(graph: graph, query: "seleziona le foto", context: context)) {
                guard case PlanValidationError.intentMismatch = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testCanonicalZipRejectsOtherFileTools() throws {
        try withContext(["foto.png"]) { context in
            let wrong = ActionGraph(steps: [ActionStep(id: "s1", tool: "file.select", inputs: ["foto.png"])])
            XCTAssertThrowsError(try PlanValidator.validate(graph: wrong, query: "zip", context: context))
            let graph = try XCTUnwrap(InstantActionParser.parse(query: "comprimi le foto", context: context))
            try PlanValidator.validate(graph: graph, query: "comprimi le foto", context: context)
        }
    }

    func testCanonicalConversionChecksFormatAndGrayscale() throws {
        try withContext(["foto.png"]) { context in
            let graph = ActionGraph(steps: [ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "png")])
            XCTAssertThrowsError(try PlanValidator.validate(graph: graph, query: "jpg", context: context)) {
                guard case PlanValidationError.formatMismatch = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            XCTAssertThrowsError(try PlanValidator.validate(graph: graph, query: "bianco e nero", context: context)) {
                guard case PlanValidationError.grayscaleMissing = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
        }
    }

    func testMissingAndWrongTypeExplicitInputsNeverFallBack() throws {
        try withContext(["foto.png", "note.txt"]) { original in
            let context = FinderContext(currentDirectory: original.currentDirectory, selectedFiles: [original.visibleFiles[0]], visibleFiles: original.visibleFiles, installedTools: [], timestamp: Date())
            let missing = ActionGraph(steps: [ActionStep(id: "s1", tool: "image.convert", inputs: ["missing.png"], format: "jpg")])
            XCTAssertThrowsError(try PlanValidator.validate(graph: missing, query: "converti", context: context))
            let wrongType = ActionGraph(steps: [ActionStep(id: "s1", tool: "image.convert", inputs: ["note.txt"], format: "jpg")])
            XCTAssertThrowsError(try PlanValidator.validate(graph: wrongType, query: "converti", context: context))
        }
    }

    func testDeclaredDependencyOutputAcceptedButGuessedOutputRejected() throws {
        try withContext(["foto.png"]) { context in
            let convert = ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "jpg")
            let consume = ActionStep(id: "s2", tool: "file.zip", inputs: ["foto.jpg"], format: "archive.zip", dependsOn: ["s1"])
            try PlanValidator.validate(graph: ActionGraph(steps: [consume, convert]), query: "converti poi archivia", context: context)
            var missingDependency = consume
            missingDependency.dependsOn = nil
            XCTAssertThrowsError(try PlanValidator.validate(graph: ActionGraph(steps: [convert, missingDependency]), query: "converti poi archivia", context: context))
            var guessed = consume
            guessed.inputs = ["unrelated.jpg"]
            XCTAssertThrowsError(try PlanValidator.validate(graph: ActionGraph(steps: [convert, guessed]), query: "converti poi archivia", context: context))
            let rename = ActionStep(id: "s1", tool: "file.rename", inputs: ["foto.png"], format: "jpg")
            XCTAssertThrowsError(try PlanValidator.validate(graph: ActionGraph(steps: [rename, consume]), query: "rinomina poi archivia", context: context))
        }
    }

    func testStructuralErrorsAreNotSkippedForSelection() throws {
        try withContext(["foto.png"]) { context in
            let graph = ActionGraph(steps: [ActionStep(id: "s1", tool: "file.select", inputs: ["foto.png"], dependsOn: ["missing"])])
            XCTAssertThrowsError(try PlanValidator.validate(graph: graph, query: "seleziona le foto", context: context))
        }
    }

    func testCompletePromptCandidateArraysPreserveNamesAndCounts() throws {
        let names = (1...21).map { "file-\($0).png" } + ["quote\" and\nnewline.png"]
        try withContext(names) { original in
            let context = FinderContext(currentDirectory: original.currentDirectory, selectedFiles: Array(original.visibleFiles.prefix(11)), visibleFiles: original.visibleFiles, installedTools: [], timestamp: Date())
            let builder = PromptBuilder()
            let selectedJSON = String(decoding: try JSONEncoder().encode(Array(names.prefix(11))), as: UTF8.self)
            let visibleJSON = String(decoding: try JSONEncoder().encode(names), as: UTF8.self)
            for prompt in [builder.buildPrompt(query: "converti", context: context), builder.buildCompactPrompt(query: "converti", context: context)] {
                XCTAssertTrue(prompt.contains("Selected Files (count: 11):"))
                XCTAssertTrue(prompt.contains("Visible Files (count: 22):"))
                XCTAssertTrue(prompt.contains(selectedJSON))
                XCTAssertTrue(prompt.contains(visibleJSON))
            }
        }
    }
}

final class ActionGraphDecodingTests: XCTestCase {
    func testMalformedInputsAndDependenciesThrow() throws {
        let invalidSteps = [
            #"{"id":"s","tool":"file.zip"}"#,
            #"{"id":"s","tool":"file.zip","inputs":null}"#,
            #"{"id":"s","tool":"file.zip","inputs":42}"#,
            #"{"id":"s","tool":"file.zip","inputs":["a",42]}"#,
            #"{"id":"s","tool":"file.zip","inputs":[],"dependsOn":{}}"#,
            #"{"id":"s","tool":"file.zip","inputs":[],"format":42}"#,
            #"{"id":"s","tool":"file.zip","inputs":[],"grayscale":"true"}"#,
            #"{"id":"s","tool":"file.zip","inputs":[],"quality":"50"}"#,
        ]
        for step in invalidSteps {
            XCTAssertThrowsError(try JSONDecoder().decode(ActionStep.self, from: Data(step.utf8)))
            XCTAssertThrowsError(try ActionGraphParser.parse("{\"steps\":[\(step)]}"))
        }
    }

    func testStringCoercionAndOptionalDependencies() throws {
        let step = try JSONDecoder().decode(ActionStep.self, from: Data(#"{"id":"s","tool":"file.zip","inputs":"a.txt","dependsOn":"first"}"#.utf8))
        XCTAssertEqual(step.inputs, ["a.txt"])
        XCTAssertEqual(step.dependsOn, ["first"])
        let noDependency = try JSONDecoder().decode(ActionStep.self, from: Data(#"{"id":"s","tool":"file.zip","inputs":[],"dependsOn":null}"#.utf8))
        XCTAssertNil(noDependency.dependsOn)
    }

    func testLiteralTagsEscapesAndBracesSurviveEveryWrapper() throws {
        let input = "literal <think>do not strip</think> <reasoning>x</reasoning> ```json { } [ ] \\\".png"
        let graph = ActionGraph(steps: [ActionStep(id: "s", tool: "file.select", inputs: [input])])
        let json = String(decoding: try JSONEncoder().encode(graph), as: UTF8.self)
        for text in [json, "```json\n\(json)\n```", "<think>internal reasoning</think>\n```json\n\(json)\n```", "Here is the plan:\n\(json)\nDone."] {
            XCTAssertEqual(try ActionGraphParser.parse(text).steps[0].inputs, [input])
        }
    }

    func testTopLevelArrayAndAmbiguousCandidates() throws {
        let array = #"[{"id":"s","tool":"file.select","inputs":["a.png"]}]"#
        XCTAssertEqual(try ActionGraphParser.parse(array).steps[0].inputs, ["a.png"])
        XCTAssertEqual(try ActionGraphParser.parse("Plan: \(array) End.").steps[0].id, "s")
        XCTAssertThrowsError(try ActionGraphParser.parse("First: \(array) Second: \(array)"))
    }

    func testMalformedOuterPlanCannotBeSalvagedFromNestedArray() {
        let malformed = #"{"steps":[{"id":"s","tool":"file.zip","inputs":42}],"nested":{"steps":[{"id":"other","tool":"file.zip","inputs":[]}]}}"#
        XCTAssertThrowsError(try ActionGraphParser.parse(malformed))
    }
}
