import XCTest
import PDFKit
import AppKit
import CoreText
@testable import Atlas

final class PDFPluginTests: XCTestCase {
    
    private func makePDF(at url: URL, pages: Int, text: String) throws {
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let graphics = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        for _ in 0..<pages {
            graphics.beginPDFPage(nil)
            graphics.textPosition = CGPoint(x: 20, y: 100)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]
            ))
            CTLineDraw(line, graphics)
            graphics.endPDFPage()
        }
        graphics.closePDF()
    }
    
    private func context(in directory: URL, files: [URL] = []) -> FinderContext {
        FinderContext(
            currentDirectory: directory,
            selectedFiles: files,
            visibleFiles: files,
            installedTools: ["gs"],
            timestamp: Date()
        )
    }
    
    func testMergeTwoPDFs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        
        try makePDF(at: dir.appendingPathComponent("a.pdf"), pages: 2, text: "a")
        try makePDF(at: dir.appendingPathComponent("b.pdf"), pages: 3, text: "b")
        
        let step = ActionStep(id: "step_1", tool: "pdf.merge", inputs: ["a.pdf", "b.pdf"], format: nil, quality: nil, dependsOn: nil)
        
        let result = try await MergePDFAction().execute(step: step, context: context(in: dir))
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputFiles.count, 1)
        let output = result.outputFiles[0]
        XCTAssertEqual(output.lastPathComponent, "merged.pdf")
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 5)
    }
    
    func testMergeRejectsSingleInput() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        
        try! makePDF(at: dir.appendingPathComponent("a.pdf"), pages: 1, text: "a")
        
        let step = ActionStep(id: "step_1", tool: "pdf.merge", inputs: ["a.pdf"], format: nil, quality: nil, dependsOn: nil)
        
        XCTAssertThrowsError(try MergePDFAction().validate(step: step, context: context(in: dir)))
    }
    
    func testSplitPDF() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        
        try makePDF(at: dir.appendingPathComponent("doc.pdf"), pages: 3, text: "doc")
        
        let step = ActionStep(id: "step_1", tool: "pdf.split", inputs: ["doc.pdf"], format: nil, quality: nil, dependsOn: nil)
        
        let result = try await SplitPDFAction().execute(step: step, context: context(in: dir))
        
        XCTAssertEqual(result.outputFiles.count, 3)
        let names = result.outputFiles.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["doc-page-1.pdf", "doc-page-2.pdf", "doc-page-3.pdf"])
        for url in result.outputFiles {
            XCTAssertEqual(PDFDocument(url: url)?.pageCount, 1)
        }
    }
    
    func testCompressionPreservesPagesAndTextOrDiscardsUnreducedOutput() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("text.pdf")
        try makePDF(at: input, pages: 3, text: "Searchable Atlas text")
        let originalBytes = try Data(contentsOf: input)
        let original = try XCTUnwrap(PDFDocument(url: input))
        XCTAssertTrue(original.string?.contains("Searchable Atlas text") == true)
        let step = ActionStep(id: "compress", tool: "pdf.compress", inputs: [input.path], quality: 40)
        guard BinaryLocator.locate("gs") != nil else {
            do {
                _ = try await CompressPDFAction().execute(step: step, context: context(in: dir))
                XCTFail("Ghostscript must be required; no rasterizing fallback")
            } catch let error as ActionExecutionError {
                XCTAssertTrue(error.underlying.localizedDescription.contains("Ghostscript"))
                XCTAssertTrue(error.partialResult.outputFiles.isEmpty)
            }
            XCTAssertEqual(try Data(contentsOf: input), originalBytes)
            return
        }
        let result = try await CompressPDFAction().execute(step: step, context: context(in: dir))
        XCTAssertTrue(result.success)
        XCTAssertEqual(try Data(contentsOf: input), originalBytes)
        if let output = result.outputFiles.first {
            XCTAssertEqual(result.outputFiles.count, 1)
            let compressed = try XCTUnwrap(PDFDocument(url: output))
            XCTAssertFalse(compressed.isLocked)
            XCTAssertEqual(compressed.pageCount, original.pageCount)
            for page in 0..<original.pageCount {
                XCTAssertEqual(compressed.page(at: page)?.string?.split(whereSeparator: \.isWhitespace),
                               original.page(at: page)?.string?.split(whereSeparator: \.isWhitespace))
            }
            XCTAssertLessThan(try Data(contentsOf: output).count, originalBytes.count)
        } else {
            XCTAssertEqual(result.message, "Nessuna riduzione ottenuta; originale conservato")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["text.pdf"])
        }
    }
    
    func testExplicitSplitDoesNotExpandPDFSelection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.pdf")
        let second = dir.appendingPathComponent("b.pdf")
        try makePDF(at: first, pages: 2, text: "a")
        try makePDF(at: second, pages: 3, text: "b")
        let original = try Data(contentsOf: second)
        let step = ActionStep(id: "scope", tool: "pdf.split", inputs: ["a.pdf"])
        let result = try await SplitPDFAction().execute(step: step, context: context(in: dir, files: [first, second]))
        XCTAssertEqual(result.outputFiles.map(\.lastPathComponent), ["a-page-1.pdf", "a-page-2.pdf"])
        XCTAssertEqual(result.outputFiles.compactMap { PDFDocument(url: $0)?.pageCount }, [1, 1])
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b-page-1.pdf").path))
    }

    func testPDFInputsRejectMissingAndWrongTypeInsteadOfSelectionFallback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let selected = dir.appendingPathComponent("selected.pdf")
        try makePDF(at: selected, pages: 2, text: "selected")
        let text = dir.appendingPathComponent("notes.txt")
        try Data("text".utf8).write(to: text)
        let snapshot = context(in: dir, files: [selected])
        for name in ["missing.pdf", "notes.txt"] {
            let step = ActionStep(id: "invalid", tool: "pdf.split", inputs: [name])
            XCTAssertThrowsError(try SplitPDFAction().validate(step: step, context: snapshot))
            XCTAssertNil(CompressPDFAction().shellCommands(step: step, context: snapshot))
            do {
                _ = try await SplitPDFAction().execute(step: step, context: snapshot)
                XCTFail("Explicit invalid PDF must not fall back to selection")
            } catch {}
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["selected.pdf", "notes.txt"])
    }

    func testImagesToPDFUsesExplicitImageRatherThanEntireSelection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let bytes = try XCTUnwrap(image.tiffRepresentation)
        let first = dir.appendingPathComponent("first.tiff")
        let second = dir.appendingPathComponent("second.tiff")
        try bytes.write(to: first)
        try bytes.write(to: second)
        let step = ActionStep(id: "images", tool: "pdf.fromImages", inputs: ["first.tiff"])
        let result = try await ImagesToPDFAction().execute(step: step, context: context(in: dir, files: [first, second]))
        let output = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
        let invalid = ActionStep(id: "wrong-type", tool: "pdf.fromImages", inputs: [output.path])
        XCTAssertThrowsError(try ImagesToPDFAction().validate(step: invalid, context: context(in: dir, files: [first])))
    }

    func testSplitFailureRetainsCompletedPagesForRollback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let valid = dir.appendingPathComponent("valid.pdf")
        let corrupt = dir.appendingPathComponent("corrupt.pdf")
        try makePDF(at: valid, pages: 2, text: "valid")
        try Data("not a PDF".utf8).write(to: corrupt)
        let originalBytes = try Data(contentsOf: valid)
        let previousOutput = dir.appendingPathComponent("valid-page-1.pdf")
        let previousBytes = Data("preexisting output".utf8)
        try previousBytes.write(to: previousOutput)
        let step = ActionStep(id: "split", tool: "pdf.split", inputs: ["valid.pdf", "corrupt.pdf"], format: nil, quality: nil, dependsOn: nil)

        do {
            _ = try await SplitPDFAction().execute(step: step, context: context(in: dir))
            XCTFail("The corrupt second input must fail the batch")
        } catch let error as ActionExecutionError {
            let completed = error.partialResult.outputFiles
            XCTAssertEqual(completed.map(\.lastPathComponent), ["valid-page-1-2.pdf", "valid-page-2.pdf"])
            for output in completed {
                XCTAssertEqual(PDFDocument(url: output)?.pageCount, 1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrupt-page-1.pdf").path))
            XCTAssertEqual(try Data(contentsOf: previousOutput), previousBytes)

            var transaction = AtlasTransaction(steps: [step])
            transaction.incorporate(error.partialResult)
            transaction.status = .failed
            XCTAssertTrue(transaction.canRollback)
            let rollback = try transaction.rollback()
            XCTAssertEqual(rollback.deletedFilesCount, 2)
            for output in completed {
                XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            }
            XCTAssertEqual(try Data(contentsOf: valid), originalBytes)
            XCTAssertEqual(try Data(contentsOf: previousOutput), previousBytes)
            XCTAssertEqual(try Data(contentsOf: corrupt), Data("not a PDF".utf8))
        }
    }

    func testMergeRejectsCorruptSecondInputWithoutPublishingIncompletePDF() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("valid.pdf")
        try makePDF(at: first, pages: 2, text: "Preserved")
        let bytes = try Data(contentsOf: first)
        try Data("invalid PDF".utf8).write(to: dir.appendingPathComponent("corrupt.pdf"))
        let step = ActionStep(id: "merge", tool: "pdf.merge", inputs: ["valid.pdf", "corrupt.pdf"])
        do {
            _ = try await MergePDFAction().execute(step: step, context: context(in: dir))
            XCTFail("Corrupt input must not be skipped")
        } catch let error as ActionExecutionError {
            XCTAssertTrue(error.underlying.localizedDescription.contains("corrupt.pdf"))
            XCTAssertTrue(error.underlying.localizedDescription.contains("input 2"))
            XCTAssertTrue(error.partialResult.outputFiles.isEmpty)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["valid.pdf", "corrupt.pdf"])
        XCTAssertEqual(try Data(contentsOf: first), bytes)
    }

    func testLockedPDFCannotMergeOrSplitAsEmptySuccess() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.pdf")
        let locked = dir.appendingPathComponent("locked.pdf")
        try makePDF(at: plain, pages: 2, text: "Private")
        let document = try XCTUnwrap(PDFDocument(url: plain))
        XCTAssertTrue(document.write(to: locked, withOptions: [.userPasswordOption: "user-secret", .ownerPasswordOption: "owner-secret"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: locked)).isLocked)
        let lockedBytes = try Data(contentsOf: locked)
        let actions: [(String, any ActionExecutor, [String])] = [
            ("pdf.merge", MergePDFAction(), ["plain.pdf", "locked.pdf"]),
            ("pdf.split", SplitPDFAction(), ["locked.pdf"])
        ]
        for (tool, action, inputs) in actions {
            do {
                _ = try await action.execute(step: ActionStep(id: tool, tool: tool, inputs: inputs), context: context(in: dir))
                XCTFail("Locked input must fail \(tool)")
            } catch let error as ActionExecutionError {
                XCTAssertTrue(error.underlying.localizedDescription.contains("locked.pdf"))
                XCTAssertTrue(error.partialResult.outputFiles.isEmpty)
            }
        }
        XCTAssertEqual(try Data(contentsOf: locked), lockedBytes)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["plain.pdf", "locked.pdf"])
    }

    func testImagesToPDFRejectsCorruptSecondImage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        try XCTUnwrap(image.tiffRepresentation).write(to: dir.appendingPathComponent("valid.tiff"))
        try Data("invalid image".utf8).write(to: dir.appendingPathComponent("corrupt.tiff"))
        let step = ActionStep(id: "images", tool: "pdf.fromImages", inputs: ["valid.tiff", "corrupt.tiff"])
        do {
            _ = try await ImagesToPDFAction().execute(step: step, context: context(in: dir))
            XCTFail("Unreadable image must not be skipped")
        } catch let error as ActionExecutionError {
            XCTAssertTrue(error.underlying.localizedDescription.contains("corrupt.tiff"))
            XCTAssertTrue(error.partialResult.outputFiles.isEmpty)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["valid.tiff", "corrupt.tiff"])
    }
}
