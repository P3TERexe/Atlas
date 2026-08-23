import XCTest
@testable import Atlas

@MainActor
final class PlanValidatorTests: XCTestCase {

    // MARK: - Fixtures

    private func context(selected: [URL] = [], visible: [URL] = []) -> FinderContext {
        FinderContext(
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedFiles: selected,
            visibleFiles: visible,
            installedTools: [],
            timestamp: Date()
        )
    }

    private func expectCase(
        _ expression: @autoclosure () throws -> Void,
        _ pattern: (PlanValidationError) -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try expression()
            XCTFail("La validazione doveva fallire: \(message)", file: file, line: line)
        } catch let error as PlanValidationError {
            XCTAssertTrue(pattern(error), "Errore inatteso \(error): \(message)", file: file, line: line)
        } catch {
            XCTFail("Errore di tipo inatteso \(error): \(message)", file: file, line: line)
        }
    }

    // MARK: - Happy paths

    func testValidConvertPlanPasses() throws {
        let ctx = context(visible: [URL(fileURLWithPath: "/tmp/foto.png")])
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "webp"),
        ])

        XCTAssertNoThrow(try PlanValidator.validate(graph: graph, query: "converti in webp", context: ctx), "Un piano coerente con query e contesto deve passare")
    }

    func testPureSelectionPlanPasses() throws {
        let ctx = context(visible: [URL(fileURLWithPath: "/tmp/foto.jpg")])
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "file.select", inputs: [], format: "jpg"),
        ])

        // La selezione pura è valida e salta i controlli di formato
        XCTAssertNoThrow(try PlanValidator.validate(graph: graph, query: "seleziona le foto", context: ctx))
    }

    // MARK: - Rami d'errore

    func testEmptyPlanIsRejected() {
        expectCase(
            try PlanValidator.validate(graph: ActionGraph(steps: []), query: "qualunque cosa", context: context()),
            { if case .emptyPlan = $0 { return true }; return false },
            "un piano senza step deve produrre emptyPlan"
        )
    }

    func testUnknownToolIsRejected() {
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "nope.quantumTransmute"),
        ])

        expectCase(
            try PlanValidator.validate(graph: graph, query: "fai la magia", context: context()),
            { if case .toolNotFound(let tool) = $0 { return tool == "nope.quantumTransmute" }; return false },
            "un tool non registrato deve produrre toolNotFound"
        )
    }

    func testSelectionQueryWithModificationStepIsRejected() {
        let ctx = context(visible: [URL(fileURLWithPath: "/tmp/doc.pdf")])
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "image.convert", inputs: ["doc.pdf"], format: "pdf"),
        ])

        expectCase(
            try PlanValidator.validate(graph: graph, query: "seleziona i pdf", context: ctx),
            { if case .intentMismatch = $0 { return true }; return false },
            "'seleziona' senza verbi di modifica accetta solo file.select"
        )
    }

    func testPhotoCompressWithoutQualityRequiresZip() {
        let ctx = context(visible: [URL(fileURLWithPath: "/tmp/foto.png")])
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "png"),
        ])

        expectCase(
            try PlanValidator.validate(graph: graph, query: "comprimi le foto", context: ctx),
            { if case .intentMismatch = $0 { return true }; return false },
            "'comprimi foto' senza qualità/formato deve richiedere file.zip"
        )
    }

    func testFormatKeywordMissingFromStepsIsRejectedIncludingTypos() {
        let ctx = context(visible: [URL(fileURLWithPath: "/tmp/foto.png")])
        let wrongFormat = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "png"),
        ])

        expectCase(
            try PlanValidator.validate(graph: wrongFormat, query: "converti in jepeg", context: ctx),
            { if case .intentMismatch(let reason) = $0 { return reason.contains("jpg") }; return false },
            "il typo 'jepeg' va normalizzato a 'jpg' e segnalato come formato mancante"
        )

        expectCase(
            try PlanValidator.validate(graph: wrongFormat, query: "converti in heic", context: ctx),
            { if case .intentMismatch = $0 { return true }; return false },
            "formato richiesto assente dagli step → intentMismatch"
        )
    }

    func testBlackAndWhiteWithoutGrayscaleFlagIsRejected() {
        let ctx = context(visible: [URL(fileURLWithPath: "/tmp/foto.png")])
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "image.convert", inputs: ["foto.png"], format: "png"),
        ])

        expectCase(
            try PlanValidator.validate(graph: graph, query: "rendi bianco e nero", context: ctx),
            { if case .grayscaleMissing = $0 { return true }; return false },
            "richiesta B&N senza grayscale: true deve produrre grayscaleMissing"
        )
    }

    func testConvertWithoutMatchingImageFilesIsRejected() {
        let ctx = context(visible: [URL(fileURLWithPath: "/tmp/note.txt")])
        let graph = ActionGraph(steps: [
            ActionStep(id: "s1", tool: "image.convert", inputs: [], format: "webp"),
        ])

        expectCase(
            try PlanValidator.validate(graph: graph, query: "converti in webp", context: ctx),
            { if case .noMatchingFiles(let tool, _) = $0 { return tool == "image.convert" }; return false },
            "image.convert senza immagini nel contesto deve produrre noMatchingFiles"
        )
    }
}
