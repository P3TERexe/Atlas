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

    private func makeFrames(at url: URL, type: UTType, count: Int, privateMetadata: Bool = false) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, count, nil))
        if type == .gif {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary)
        }
        for index in 0..<count {
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            let canvas = try XCTUnwrap(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            canvas.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: index == 0 ? 0 : 1, blue: 0, alpha: 0.5))
            canvas.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
            var properties: [String: Any] = [kCGImagePropertyOrientation as String: 6]
            if type == .gif {
                properties[kCGImagePropertyGIFDictionary as String] = [kCGImagePropertyGIFDelayTime as String: 0.2, kCGImagePropertyGIFUnclampedDelayTime as String: 0.2]
            }
            if privateMetadata {
                properties[kCGImagePropertyExifDictionary as String] = [kCGImagePropertyExifDateTimeOriginal as String: "2020:01:02 03:04:05", kCGImagePropertyExifUserComment as String: "private comment"]
                properties[kCGImagePropertyGPSDictionary as String] = [kCGImagePropertyGPSLatitude as String: 48.5, kCGImagePropertyGPSLatitudeRef as String: "N"]
                properties[kCGImagePropertyIPTCDictionary as String] = [kCGImagePropertyIPTCKeywords as String: ["private keyword"]]
                properties[kCGImagePropertyTIFFDictionary as String] = [kCGImagePropertyTIFFArtist as String: "private artist", kCGImagePropertyTIFFOrientation as String: 6]
            }
            CGImageDestinationAddImage(destination, try XCTUnwrap(canvas.makeImage()), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func rgba(_ image: CGImage) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let canvas = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        canvas.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try XCTUnwrap(canvas.data), count: image.width * image.height * 4)
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

    func testConversionUsesOnlyExplicitImageDespiteLargerSelection() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("a.png")
        let second = dir.appendingPathComponent("b.png")
        try makePNG(at: first, width: 8, height: 4)
        try makePNG(at: second, width: 20, height: 10)
        let original = try Data(contentsOf: second)
        let step = ActionStep(id: "scope", tool: "image.convert", inputs: ["a.png"], format: "tiff")
        let snapshot = context(in: dir, files: [first, second])
        let preview = try XCTUnwrap(ConvertImageAction().shellCommands(step: step, context: snapshot))
        XCTAssertEqual(preview.count, 1)
        XCTAssertTrue(preview[0].contains(first.path))
        XCTAssertFalse(preview[0].contains(second.path))
        let result = try await ConvertImageAction().execute(step: step, context: snapshot)
        XCTAssertEqual(result.outputFiles.map(\.lastPathComponent), ["a.tiff"])
        XCTAssertEqual(pixelDimensions(of: result.outputFiles[0])?.width, 8)
        XCTAssertEqual(try Data(contentsOf: second), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("b.tiff").path))
    }

    func testImageActionsRejectMissingAndWrongTypeExplicitInputs() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let selected = dir.appendingPathComponent("selected.png")
        try makePNG(at: selected, width: 8, height: 4)
        let text = dir.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: text)
        let snapshot = context(in: dir, files: [selected])
        let actions: [any ActionExecutor] = [ConvertImageAction(), ResizeImageAction(), RotateImageAction(), ThumbnailImageAction(), StripExifImageAction(), OCRRenameImageAction()]
        for action in actions {
            for name in ["missing.png", "notes.txt"] {
                let step = ActionStep(id: "invalid", tool: "image.convert", inputs: [name], format: "png")
                XCTAssertThrowsError(try action.validate(step: step, context: snapshot))
                do {
                    _ = try await action.execute(step: step, context: snapshot)
                    XCTFail("Explicit invalid image must not fall back to the selected image")
                } catch {}
            }
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), ["selected.png", "notes.txt"])
    }

    func testImplicitImageSelectionDoesNotFallBackAfterFiltering() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("visible.png")
        try makePNG(at: image, width: 8, height: 4)
        let text = dir.appendingPathComponent("selected.txt")
        try Data("selected non-image".utf8).write(to: text)
        let snapshot = FinderContext(currentDirectory: dir, selectedFiles: [text], visibleFiles: [image], installedTools: [], timestamp: Date())
        let step = ActionStep(id: "selection", tool: "image.convert", inputs: [], format: "png")
        XCTAssertThrowsError(try ConvertImageAction().validate(step: step, context: snapshot))
        XCTAssertNil(ConvertImageAction().shellCommands(step: step, context: snapshot))
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

    func testRepeatedResizePreservesFirstOutput() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("grande.png")
        try makePNG(at: input, width: 64, height: 32)
        let step = ActionStep(id: "resize", tool: "image.resize", inputs: [input.lastPathComponent], format: "16")
        let action = ResizeImageAction()
        let first = try await action.execute(step: step, context: context(in: dir))
        let firstURL = try XCTUnwrap(first.outputFiles.first)
        let firstBytes = try Data(contentsOf: firstURL)
        let second = try await action.execute(step: step, context: context(in: dir))
        let secondURL = try XCTUnwrap(second.outputFiles.first)
        XCTAssertEqual(secondURL.lastPathComponent, "grande_16px-2.png")
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try XCTUnwrap(pixelDimensions(of: secondURL)).width, 16)

        var transaction = AtlasTransaction(steps: [step])
        transaction.incorporate(second)
        transaction.status = .success
        _ = try transaction.rollback()
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
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

    func testStripExifPreservesTIFFFramesOrientationAndColorWhileRemovingPrivateMetadata() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("scatto.tiff")
        try makeFrames(at: input, type: .tiff, count: 2, privateMetadata: true)
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [String: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNotNil(originalProperties[kCGImagePropertyExifDictionary as String])
        let result = try await StripExifImageAction().execute(step: ActionStep(id: "strip", tool: "image.stripExif", inputs: [input.lastPathComponent]), context: context(in: dir))
        let outputURL = try XCTUnwrap(result.outputFiles.first)
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(output) as String?, UTType.tiff.identifier)
        XCTAssertEqual(CGImageSourceGetCount(output), 2)
        for frame in 0..<2 {
            let before = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(original, frame, nil) as? [String: Any])
            let after = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, frame, nil) as? [String: Any])
            XCTAssertEqual(after[kCGImagePropertyOrientation as String] as? Int, 6)
            XCTAssertEqual(after[kCGImagePropertyProfileName as String] as? String, before[kCGImagePropertyProfileName as String] as? String)
            XCTAssertNil(after[kCGImagePropertyGPSDictionary as String])
            XCTAssertNil(after[kCGImagePropertyIPTCDictionary as String])
            let exif = after[kCGImagePropertyExifDictionary as String] as? [String: Any]
            XCTAssertNil(exif?[kCGImagePropertyExifUserComment as String])
            XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal as String])
            let tiff = after[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist as String])
            XCTAssertEqual(try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(output, frame, nil))), try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(original, frame, nil))))
        }
    }

    func testGIFStripAndConversionPreserveAnimation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("animazione.gif")
        try makeFrames(at: input, type: .gif, count: 2)
        for action in [StripExifImageAction() as any ActionExecutor, ConvertImageAction() as any ActionExecutor] {
            let result = try await action.execute(step: ActionStep(id: "frames", tool: "image.convert", inputs: [input.lastPathComponent], format: "gif"), context: context(in: dir))
            let output = try XCTUnwrap(CGImageSourceCreateWithURL(XCTUnwrap(result.outputFiles.first) as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(output) as String?, UTType.gif.identifier)
            XCTAssertEqual(CGImageSourceGetCount(output), 2)
            let global = try XCTUnwrap(CGImageSourceCopyProperties(output, nil) as? [String: Any])
            XCTAssertEqual((global[kCGImagePropertyGIFDictionary as String] as? [String: Any])?[kCGImagePropertyGIFLoopCount as String] as? Int, 3)
            for frame in 0..<2 {
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(output, frame, nil) as? [String: Any])
                let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
                XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime as String] as? Double), 0.2, accuracy: 0.01)
            }
            XCTAssertNotEqual(try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(output, 0, nil))), try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(output, 1, nil))))
        }
    }

    func testMultiFrameConversionToJPEGRefusesWithoutPublishing() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("pagine.tiff")
        try makeFrames(at: input, type: .tiff, count: 2)
        let bytes = try Data(contentsOf: input)
        do {
            _ = try await ConvertImageAction().execute(step: ActionStep(id: "single", tool: "image.convert", inputs: [input.lastPathComponent], format: "jpg"), context: context(in: dir))
            XCTFail("Multi-frame conversion must not silently flatten")
        } catch let error as ActionExecutionError {
            XCTAssertTrue(error.underlying is ExecutorError)
            XCTAssertTrue(error.partialResult.outputFiles.isEmpty)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [input.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    func testGrayscalePreservesAlphaAndOrientation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("alpha.tiff")
        try makeFrames(at: input, type: .tiff, count: 1)
        let result = try await ConvertImageAction().execute(step: ActionStep(id: "gray", tool: "image.convert", inputs: [input.lastPathComponent], format: "tiff", grayscale: true), context: context(in: dir))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(XCTUnwrap(result.outputFiles.first) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation as String] as? Int, 6)
        let pixels = try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        XCTAssertEqual(pixels[0], pixels[1])
        XCTAssertEqual(pixels[1], pixels[2])
        XCTAssertEqual(Double(pixels[3]), 128, accuracy: 1)
    }

    func testTIFFConversionRetainsEveryPage() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("pagine.tiff")
        try makeFrames(at: input, type: .tiff, count: 2)
        let original = try XCTUnwrap(CGImageSourceCreateWithURL(input as CFURL, nil))
        let result = try await ConvertImageAction().execute(step: ActionStep(id: "pages", tool: "image.convert", inputs: [input.lastPathComponent], format: "tiff"), context: context(in: dir))
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(XCTUnwrap(result.outputFiles.first) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(output) as String?, UTType.tiff.identifier)
        XCTAssertEqual(CGImageSourceGetCount(output), 2)
        for index in 0..<2 {
            XCTAssertEqual(try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(output, index, nil))), try rgba(XCTUnwrap(CGImageSourceCreateImageAtIndex(original, index, nil))))
        }
    }

    func testStripExifUsesActualTypeDespiteMisleadingSourceExtension() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("wrong.jpg")
        try makeFrames(at: input, type: .tiff, count: 2)
        let result = try await StripExifImageAction().execute(step: ActionStep(id: "type", tool: "image.stripExif", inputs: [input.lastPathComponent]), context: context(in: dir))
        let url = try XCTUnwrap(result.outputFiles.first)
        XCTAssertEqual(UTType(filenameExtension: url.pathExtension), .tiff)
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(output) as String?, UTType.tiff.identifier)
        XCTAssertEqual(CGImageSourceGetCount(output), 2)
    }

    func testVideoRejectsUnsupportedOutputBeforeCreatingFiles() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("clip.mp4")
        try Data("input placeholder; must fail before decode".utf8).write(to: input)
        let step = ActionStep(id: "format", tool: "video.convert", inputs: [input.lastPathComponent], format: "avi")
        let action = ConvertVideoAction()
        XCTAssertThrowsError(try action.validate(step: step, context: context(in: dir)))
        XCTAssertNil(action.shellCommands(step: step, context: context(in: dir)))
        do {
            _ = try await action.execute(step: step, context: context(in: dir))
            XCTFail("Unsupported output must not become mp4")
        } catch let error as ActionExecutionError {
            guard case ExecutorError.validationFailed = error.underlying else {
                return XCTFail("Expected format validation error, got \(error.underlying)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [input.lastPathComponent])
    }

    // MARK: - Regressioni: nessuna perdita silenziosa / fallback WebP

    /// Bug: un file corrotto su cui sips fallisce veniva scartato in silenzio
    /// restituendo comunque success=true e messaggio di successo.
    func testResizeSecondFailureJournalsFirstOutputForUndo() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("buona.png")
        let corrupt = dir.appendingPathComponent("corrotta.png")
        try makePNG(at: good, width: 4, height: 4)
        let goodBytes = try Data(contentsOf: good)
        let corruptBytes = Data("questo non è un png".utf8)
        try corruptBytes.write(to: corrupt)
        let step = ActionStep(id: "s1", tool: "image.resize", inputs: [good.lastPathComponent, corrupt.lastPathComponent], format: "8")
        do {
            _ = try await ResizeImageAction().execute(step: step, context: context(in: dir))
            XCTFail("Un batch con un file corrotto non deve restituire successo")
        } catch let error as ActionExecutionError {
            XCTAssertTrue(error.underlying is ExecutorError)
            let output = dir.appendingPathComponent("buona_8px.png")
            XCTAssertTrue(error.partialResult.outputFiles.contains(output))
            XCTAssertEqual(try XCTUnwrap(pixelDimensions(of: output)).width, 8)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("corrotta_8px.png").path))
            var transaction = AtlasTransaction(steps: [step])
            transaction.incorporate(error.partialResult)
            transaction.status = .failed
            XCTAssertTrue(transaction.canRollback)
            _ = try transaction.rollback()
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), Set([good.lastPathComponent, corrupt.lastPathComponent]))
            XCTAssertEqual(try Data(contentsOf: good), goodBytes)
            XCTAssertEqual(try Data(contentsOf: corrupt), corruptBytes)
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
        } catch let error as ActionExecutionError {
            XCTAssertTrue(error.underlying is ExecutorError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sporca_clean.jpg").path))
        } catch {
            XCTFail("Era atteso executionFailed, ricevuto: \(error)")
        }
    }

    func testVideoConversionPreservesAspectRatioWhenFFmpegAvailable() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let ffmpeg = BinaryLocator.locate("ffmpeg") else {
            let input = dir.appendingPathComponent("input.mp4")
            try Data().write(to: input)
            do {
                _ = try await ConvertVideoAction().execute(step: ActionStep(id: "video", tool: "video.convert", inputs: [input.lastPathComponent], format: "mov"), context: context(in: dir))
                XCTFail("Missing ffmpeg must fail explicitly")
            } catch let error as ActionExecutionError {
                XCTAssertTrue(error.underlying.localizedDescription.contains("ffmpeg"))
            }
            throw XCTSkip("ffmpeg assente: errore dipendenza verificato; conversione runtime non provata.")
        }
        guard let ffprobe = BinaryLocator.locate("ffprobe") else { throw XCTSkip("ffprobe assente: verifica runtime codec/durata/aspect ratio non disponibile.") }
        let input = dir.appendingPathComponent("clip ' portrait.mp4")
        let create = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: ffmpeg), arguments: ["-f", "lavfi", "-i", "color=c=red:s=240x320:r=24", "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", input.path])
        XCTAssertTrue(create.isSuccess, create.stderr)
        let step = ActionStep(id: "video", tool: "video.convert", inputs: [input.lastPathComponent], format: "mov", quality: 30)
        let result = try await ConvertVideoAction().execute(step: step, context: context(in: dir))
        let output = try XCTUnwrap(result.outputFiles.first)
        let probe = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: ffprobe), arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height:format=duration", "-of", "json", output.path])
        XCTAssertTrue(probe.isSuccess, probe.stderr)
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(probe.stdout.utf8)) as? [String: Any])
        let stream = try XCTUnwrap((info["streams"] as? [[String: Any]])?.first)
        XCTAssertEqual(stream["codec_name"] as? String, "h264")
        let width = try XCTUnwrap(stream["width"] as? Int)
        let height = try XCTUnwrap(stream["height"] as? Int)
        XCTAssertEqual(Double(width) / Double(height), 0.75, accuracy: 0.01)
        XCTAssertLessThanOrEqual(width, 640)
        XCTAssertLessThanOrEqual(height, 480)
        XCTAssertEqual(width % 2, 0)
        XCTAssertEqual(height % 2, 0)
        let duration = try XCTUnwrap((info["format"] as? [String: Any])?["duration"] as? String)
        XCTAssertEqual(try XCTUnwrap(Double(duration)), 1, accuracy: 0.1)
        // Exercise the displayed command with the same apostrophe-containing paths.
        let preview = try XCTUnwrap(ConvertVideoAction().shellCommands(step: step, context: context(in: dir))?.first)
        let previewRun = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-c", preview])
        XCTAssertTrue(previewRun.isSuccess, previewRun.stderr)
        let previewOutput = dir.appendingPathComponent("clip ' portrait-2.mov")
        let previewProbe = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: ffprobe), arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=codec_name,width,height:format=duration", "-of", "json", previewOutput.path])
        XCTAssertTrue(previewProbe.isSuccess, previewProbe.stderr)
        XCTAssertEqual(previewProbe.stdout, probe.stdout)
    }

    // MARK: - Vision OCR rename

    @MainActor
    func testOcrRenameHelperRestoresBytesAndOriginalName() throws {
        let dir = try makeTempDir()
        let previousRoot = BackupStore.rootOverride
        BackupStore.rootOverride = dir.appendingPathComponent("backups", isDirectory: true)
        defer {
            BackupStore.rootOverride = previousRoot
            try? FileManager.default.removeItem(at: dir)
        }
        let input = dir.appendingPathComponent("nota.png")
        let target = dir.appendingPathComponent("ATLAS.png")
        try makePNG(at: input, width: 4, height: 4)
        let bytes = try Data(contentsOf: input)
        let result = try OCRRenameImageAction.rename(inputURL: input, targetURL: target)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.backupURLs[input])), bytes)
        var transaction = AtlasTransaction(steps: [])
        transaction.incorporate(result)
        transaction.status = .success
        transaction = try JSONDecoder().decode(AtlasTransaction.self, from: JSONEncoder().encode(transaction))
        _ = try transaction.rollback()
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let noOp = try OCRRenameImageAction.rename(inputURL: input, targetURL: input)
        XCTAssertTrue(noOp.outputFiles.isEmpty)
        XCTAssertTrue(noOp.backupURLs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
    }

    @MainActor
    func testOcrRenameDoesNotCrashAndKeepsFile() async throws {
        let dir = try makeTempDir()
        let previousRoot = BackupStore.rootOverride
        BackupStore.rootOverride = dir.appendingPathComponent("backups", isDirectory: true)
        defer { BackupStore.rootOverride = previousRoot }
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
        let output = result.outputFiles.first ?? input
        XCTAssertEqual(try Data(contentsOf: output), pngData)
        var transaction = AtlasTransaction(steps: [step])
        transaction.incorporate(result)
        transaction.status = .success
        _ = try transaction.rollback()
        XCTAssertEqual(try Data(contentsOf: input), pngData)
    }
}
