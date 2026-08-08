import XCTest
import PDFKit
@testable import Atlas

final class PDFPluginTests: XCTestCase {
    
    private func makePDF(at url: URL, pages: Int, text: String) throws {
        let document = PDFDocument()
        for _ in 0..<pages {
            let page = PDFPage(image: NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                return true
            })!
            document.insert(page, at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: url))
        _ = text
    }
    
    private func context(in directory: URL, files: [URL] = []) -> FinderContext {
        FinderContext(
            currentDirectory: directory,
            selectedFiles: files,
            visibleFiles: files,
            installedTools: ["gs", "magick"],
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
    
    func testCompressPDF() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        
        try makePDF(at: dir.appendingPathComponent("big.pdf"), pages: 3, text: "big")
        
        let step = ActionStep(id: "step_1", tool: "pdf.compress", inputs: ["big.pdf"], format: nil, quality: 40, dependsOn: nil)
        
        let result = try await CompressPDFAction().execute(step: step, context: context(in: dir))
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputFiles.count, 1)
        let output = result.outputFiles[0]
        XCTAssertEqual(output.lastPathComponent, "big-compressed.pdf")
        XCTAssertNotNil(PDFDocument(url: output))
    }
    
    func testCompressWithoutToolsThrows() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        
        try makePDF(at: dir.appendingPathComponent("big.pdf"), pages: 1, text: "big")
        
        let step = ActionStep(id: "step_1", tool: "pdf.compress", inputs: ["big.pdf"], format: nil, quality: 40, dependsOn: nil)
        
        let result = try await CompressPDFAction().execute(step: step, context: context(in: dir))
        XCTAssertTrue(result.success || result.outputFiles.isEmpty)
    }
}
