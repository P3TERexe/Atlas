import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit
@testable import Atlas

final class ImagePluginTests: XCTestCase {

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Scrive un PNG solido di dimensione arbitraria senza dipendere da file di risorsa.
    private func makePNG(at url: URL, width: Int, height: Int) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "Scrittura PNG di fixture fallita")
    }

    private func pixelDimensions(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    private func context(in directory: URL, files: [URL] = []) -> FinderContext {
        FinderContext(
            currentDirectory: directory,
            selectedFiles: files,
            visibleFiles: files,
            installedTools: [],
            timestamp: Date()
        )
    }

    // MARK: - image.convert

    func testConvertPngToWebpNative() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("foto.png")
        try makePNG(at: input, width: 4, height: 4)

        let step = ActionStep(id: "i1", tool: "image.convert", inputs: ["foto.png"], format: "webp")
        let result = try await ConvertImageAction().execute(step: step, context: context(in: dir, files: [input]))

        XCTAssertTrue(result.success, "La conversione webp deve riuscire con il motore nativo ImageIO")
        let output = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(output.lastPathComponent, "foto.webp", "L'output mantiene il nome e cambia estensione")
        let dimensions = try XCTUnwrap(pixelDimensions(of: output), "L'output deve essere decodificabile come immagine")
        XCTAssertEqual(dimensions.width, 4, "Le dimensioni del pixel restano invariate dopo la conversione")
    }

    // MARK: - sips-based actions

    func testResizeSetsExpectedWidth() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("grande.png")
        try makePNG(at: input, width: 64, height: 32)

        let step = ActionStep(id: "i2", tool: "image.resize", inputs: ["grande.png"], format: "16")
        let result = try await ResizeImageAction().execute(step: step, context: context(in: dir))

        let output = try XCTUnwrap(result.outputFiles.first, "Il ridimensionamento deve produrre un output")
        XCTAssertEqual(output.lastPathComponent, "grande_16px.png", "L'output del resize è suffissato con la larghezza")
        let dimensions = try XCTUnwrap(pixelDimensions(of: output))
        XCTAssertEqual(dimensions.width, 16, "sips --resampleWidth porta la larghezza al valore richiesto")
    }

    func testRotateSwapsDimensions() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("orizzontale.png")
        try makePNG(at: input, width: 40, height: 20)

        let step = ActionStep(id: "i3", tool: "image.rotate", inputs: ["orizzontale.png"], format: "90")
        let result = try await RotateImageAction().execute(step: step, context: context(in: dir))

        let output = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(output.lastPathComponent, "orizzontale_r90.png", "L'output della rotazione è suffissato con i gradi")
        let dimensions = try XCTUnwrap(pixelDimensions(of: output))
        XCTAssertEqual(dimensions.width, 20, "Ruotando di 90° la larghezza diventa l'altezza originale")
        XCTAssertEqual(dimensions.height, 40, "Ruotando di 90° l'altezza diventa la larghezza originale")
    }

    func testThumbnailCapsAt256px() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("enorme.png")
        try makePNG(at: input, width: 300, height: 200)

        let step = ActionStep(id: "i4", tool: "image.thumbnail", inputs: ["enorme.png"])
        let result = try await ThumbnailImageAction().execute(step: step, context: context(in: dir))

        let output = try XCTUnwrap(result.outputFiles.first)
        let dimensions = try XCTUnwrap(pixelDimensions(of: output))
        XCTAssertLessThanOrEqual(dimensions.width, 256, "La miniatura non supera 256px di larghezza")
    }

    func testStripExifProducesOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("scatto.png")
        try makePNG(at: input, width: 10, height: 10)

        let step = ActionStep(id: "i5", tool: "image.stripExif", inputs: ["scatto.png"])
        let result = try await StripExifImageAction().execute(step: step, context: context(in: dir))

        XCTAssertTrue(result.success)
        let output = try XCTUnwrap(result.outputFiles.first, "La pulizia metadati deve produrre una copia pulita")
        XCTAssertNotEqual(output.path, input.path, "L'output è un nuovo file, mai l'input stesso")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "La copia pulita deve esistere su disco")
    }

    // MARK: - Regressioni: nessuna perdita silenziosa / fallback WebP

    /// Bug: un file corrotto su cui sips fallisce veniva scartato in silenzio
    /// restituendo comunque success=true e messaggio di successo.
    func testResizeWithCorruptImageThrowsInsteadOfSilentDrop() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("buona.png")
        try makePNG(at: good, width: 4, height: 4)
        try Data("questo non è un png".utf8).write(to: dir.appendingPathComponent("corrotta.png"))
        let step = ActionStep(id: "s1", tool: "image.resize", inputs: ["buona.png", "corrotta.png"], format: "8")

        do {
            _ = try await ResizeImageAction().execute(step: step, context: context(in: dir))
            XCTFail("Un batch con un file corrotto non deve restituire successo")
        } catch let error as ExecutorError {
            guard case .executionFailed(let message) = error else {
                return XCTFail("Era atteso executionFailed, ricevuto: \(error)")
            }
            XCTAssertTrue(message.contains("1 di 2"), "Il messaggio deve riportare il rapporto successo/falliti: \(message)")
            XCTAssertTrue(message.contains("corrotta.png"), "Il messaggio deve elencare i file falliti: \(message)")
        } catch {
            XCTFail("Era atteso ExecutorError, ricevuto: \(error)")
        }
    }
    func testStripExifWithCorruptImageThrowsInsteadOfSilentDrop() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let corrupt = dir.appendingPathComponent("sporca.jpg")
        try Data([0xFF, 0xD8, 0x00]).write(to: corrupt) // header JPEG troncato

        let step = ActionStep(id: "s1", tool: "image.stripExif", inputs: ["sporca.jpg"], format: nil)

        do {
            _ = try await StripExifImageAction().execute(step: step, context: context(in: dir))
            XCTFail("Un file JPEG troncato non deve produrre successo silenzioso")
        } catch let error as ExecutorError {
            guard case .executionFailed = error else {
                return XCTFail("Era atteso executionFailed, ricevuto: \(error)")
            }
        } catch {
            XCTFail("Era atteso executionFailed, ricevuto: \(error)")
        }
    }

    /// Bug: senza ImageMagick il fallback CLI delegava WebP a sips, che non
    /// può codificarlo → tentativo destinato al fallimento.
    func testWebpFallbackWithoutMagickFailsExplicitly() {
        // Solo sips disponibile: WebP deve produrre un motivo d'errore esplicito…
        let plan = ConvertImageAction.cliFallbackCommand(
            inputPath: "/tmp/a.png", outputPath: "/tmp/a.webp",
            cleanFormat: "webp", grayscale: false,
            exists: { $0 == "/usr/bin/sips" }
        )
        XCTAssertNotNil(plan.failureReason, "WebP senza magick non deve mai produrre un comando sips")
        XCTAssertTrue(plan.failureReason?.contains("ImageMagick") == true, "L'errore deve citare ImageMagick: \(plan.failureReason ?? "nil")")

        // …mentre con magick installato il comando esiste e non fallisce.
        let okPlan = ConvertImageAction.cliFallbackCommand(
            inputPath: "/tmp/a.png", outputPath: "/tmp/a.webp",
            cleanFormat: "webp", grayscale: false,
            exists: { $0 == "/opt/homebrew/bin/magick" }
        )
        XCTAssertNil(okPlan.failureReason)
        XCTAssertEqual(okPlan.executable, "/opt/homebrew/bin/magick")

    // Grayscale verso jpeg resta servito da sips (sì può fare).
        let grayPlan = ConvertImageAction.cliFallbackCommand(
            inputPath: "/tmp/a.png", outputPath: "/tmp/a_bw.jpg",
            cleanFormat: "jpg", grayscale: true,
            exists: { $0 == "/usr/bin/sips" }
        )
        XCTAssertNil(grayPlan.failureReason)
        XCTAssertEqual(grayPlan.executable, "/usr/bin/sips")
    }

    // MARK: - Vision OCR rename

    func testOcrRenameDoesNotCrashAndKeepsFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("nota.png")

        // Immagine con testo ben leggibile disegnato via CoreGraphics/AppKit.
        let size = NSSize(width: 320, height: 120)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            ("ATLAS" as NSString).draw(
                in: rect.insetBy(dx: 20, dy: 30),
                withAttributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.black]
            )
            return true
        }
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let pngData = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try pngData.write(to: input)

        let step = ActionStep(id: "i6", tool: "image.ocrRename", inputs: ["nota.png"])
        let result = try await OCRRenameImageAction().execute(step: step, context: context(in: dir))

        XCTAssertTrue(result.success, "L'esecuzione OCR non deve lanciare errori")
        // Il riconoscimento è potenzialmente nondeterministico: accettiamo che il file
        // sia rinominato oppure lasciato al suo nome originale, ma deve esistere ancora.
        let originalStillThere = FileManager.default.fileExists(atPath: input.path)
        let renamedExists = result.outputFiles.contains { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertTrue(originalStillThere || renamedExists, "Dopo l'OCR il file deve esistere con nome originale o rinominato")
    }
}
