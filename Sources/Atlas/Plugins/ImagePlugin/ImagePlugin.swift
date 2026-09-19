import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Vision


private func validateImageOutput(at url: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
        throw ExecutorError.executionFailed("Immagine prodotta non leggibile: \(url.lastPathComponent)")
    }
}

class ImagePlugin: AtlasPlugin {
    let id = "image"
    
    var capabilities: [ToolCapability] {
        let supportedFormats = Array(MediaFormats.image).sorted()
        
        return [
            ToolCapability(
                id: "image.convert",
                description: "Converts images between different formats (png, jpg, webp, heic, tiff, gif) or converts to black and white / grayscale (set grayscale: true)",
                inputFormats: supportedFormats,
                outputFormats: supportedFormats,
                executor: ConvertImageAction()
            ),
            ToolCapability(
                id: "image.resize",
                description: "Resizes images to specified pixel width or height (e.g. set format: '1024' or '1080')",
                inputFormats: supportedFormats,
                outputFormats: supportedFormats,
                executor: ResizeImageAction()
            ),
            ToolCapability(
                id: "image.rotate",
                description: "Rotates images clockwise by specified degrees (e.g. set format: '90', '180', '270')",
                inputFormats: supportedFormats,
                outputFormats: supportedFormats,
                executor: RotateImageAction()
            ),
            ToolCapability(
                id: "image.thumbnail",
                description: "Creates thumbnail image copies (max 256px width)",
                inputFormats: supportedFormats,
                outputFormats: supportedFormats,
                executor: ThumbnailImageAction()
            ),
            ToolCapability(
                id: "image.stripExif",
                description: "Strips EXIF metadata and private tags from images",
                inputFormats: supportedFormats,
                outputFormats: supportedFormats,
                executor: StripExifImageAction()
            ),
            ToolCapability(
                id: "image.ocrRename",
                description: "Recognizes text inside images/screenshots using native Apple Vision OCR and auto-renames files based on their text content",
                inputFormats: supportedFormats,
                outputFormats: supportedFormats,
                executor: OCRRenameImageAction()
            )
        ]
    }
}

private actor ConversionJournal {
    private(set) var converted: [URL] = []
    private var stagedTemps: Set<URL> = []
    private var completedCount: Int = 0
    let totalCount: Int

    init(totalCount: Int) {
        self.totalCount = totalCount
    }

    func stage(temp: URL) {
        stagedTemps.insert(temp)
    }

    func commit(temp: URL, destination: URL) {
        stagedTemps.remove(temp)
        converted.append(destination)
        completedCount += 1
    }

    func rollbackTemps() {
        for temp in stagedTemps {
            try? FileManager.default.removeItem(at: temp)
        }
        stagedTemps.removeAll()
    }

    func currentProgress() -> Int {
        completedCount
    }
}

final class ConvertImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let rawFormat = step.format ?? "png"
        guard let inputURLs = try? InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image) else { return nil }
        let ext = outputExtension(rawFormat)
        
        return inputURLs.map { inputURL in
            let outputURL = outputURL(for: inputURL, extensionName: ext, isGrayscale: step.grayscale == true)
            if step.grayscale == true {
                return "magick \(inputURL.path) -colorspace Gray \(outputURL.path)"
            } else if rawFormat.lowercased() == "webp" {
                return "magick \(inputURL.path) \(outputURL.path)"
            } else {
                return "sips -s format \(rawFormat) \(inputURL.path) --out \(outputURL.path)"
            }
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let inputURLs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
        let isGrayscale = step.grayscale == true
        let total = inputURLs.count
        let journal = ConversionJournal(totalCount: total)

        let maxConcurrent = min(total, max(2, ProcessInfo.processInfo.activeProcessorCount))

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = inputURLs.makeIterator()

                for _ in 0..<maxConcurrent {
                    if let nextURL = iterator.next() {
                        group.addTask {
                            try await self.processSingleImage(
                                inputURL: nextURL,
                                step: step,
                                isGrayscale: isGrayscale,
                                journal: journal,
                                progress: progress
                            )
                        }
                    }
                }

                while let _ = try await group.next() {
                    if let nextURL = iterator.next() {
                        group.addTask {
                            try await self.processSingleImage(
                                inputURL: nextURL,
                                step: step,
                                isGrayscale: isGrayscale,
                                journal: journal,
                                progress: progress
                            )
                        }
                    }
                }
            }
        } catch {
            await journal.rollbackTemps()
            let partial = await journal.converted
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: partial, message: nil))
        }

        let converted = await journal.converted
        let label = isGrayscale ? "in Bianco e Nero" : "nel formato specificato"
        return ActionResult(success: true, outputFiles: converted, message: "Elaborate \(converted.count) immagini \(label)")
    }

    private func processSingleImage(
        inputURL: URL,
        step: ActionStep,
        isGrayscale: Bool,
        journal: ConversionJournal,
        progress: ItemProgressCallback?
    ) async throws {
        try Task.checkCancellation()
        let format = step.format ?? inputURL.pathExtension
        let type = try Self.destinationType(format)
        let source = try ImageEncoding.source(at: inputURL)
        let count = CGImageSourceGetCount(source)
        guard count == 1 || ["public.tiff", "com.compuserve.gif", "public.png", "org.webmproject.webp"].contains(type) else {
            throw ExecutorError.executionFailed("\(inputURL.lastPathComponent) contiene \(count) frame; il formato \(format) non li può conservare. Nessuna conversione eseguita.")
        }
        let native = ImageEncoding.canWrite(type)
        guard native || count == 1 else {
            throw ExecutorError.executionFailed("ImageIO non può scrivere \(format) conservando tutti i frame.")
        }
        let output = outputURL(for: inputURL, extensionName: outputExtension(format), isGrayscale: isGrayscale)
        var temporary = output.deletingLastPathComponent().appendingPathComponent(".atlas-output-\(UUID().uuidString)")
        if !output.pathExtension.isEmpty {
            temporary.appendPathExtension(output.pathExtension)
        }
        await journal.stage(temp: temporary)

        if native {
            try convertImageIO(source: source, outputURL: temporary, type: type, grayscale: isGrayscale, quality: step.quality)
        } else {
            try await convertCLIFallback(inputURL: inputURL, outputURL: temporary, format: format, grayscale: isGrayscale)
        }
        try ImageEncoding.validate(at: temporary, type: type, count: count)

        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        await journal.commit(temp: temporary, destination: output)

        let current = await journal.currentProgress()
        let total = journal.totalCount
        progress?(current, total, "Elaborazione \(current)/\(total): \(inputURL.lastPathComponent)")
    }
    
    // MARK: - Native ImageIO Engine (Supports Grayscale / Black & White)
    
    private static func destinationType(_ format: String) throws -> String {
        let clean = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let type = UTType(filenameExtension: clean), type.conforms(to: .image) else {
            throw ExecutorError.validationFailed("Formato immagine non supportato: \(format)")
        }
        return type.identifier
    }

    private func convertImageIO(source: CGImageSource, outputURL: URL, type: String, grayscale: Bool, quality: Int?) throws {
        let count = CGImageSourceGetCount(source)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, type as CFString, count, nil) else {
            throw ExecutorError.executionFailed("ImageIO non può scrivere il formato \(type)")
        }
        if let properties = CGImageSourceCopyProperties(source, nil) {
            CGImageDestinationSetProperties(destination, properties)
        }
        for index in 0..<count {
            try Task.checkCancellation()
            guard var image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw ExecutorError.executionFailed("Frame \(index + 1) non leggibile: \(outputURL.lastPathComponent)")
            }
            var properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
            if grayscale {
                guard let graySpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
                      let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw ExecutorError.executionFailed("Impossibile conservare la trasparenza nella conversione in scala di grigi.")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                guard let gray = context.makeImage() else {
                    throw ExecutorError.executionFailed("Conversione in scala di grigi fallita.")
                }
                image = gray
                properties.removeValue(forKey: kCGImagePropertyProfileName as String)
                properties.removeValue(forKey: kCGImagePropertyColorModel as String)
            }
            if let quality {
                properties[kCGImageDestinationLossyCompressionQuality as String] = Double(max(1, min(100, quality))) / 100
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ExecutorError.executionFailed("Scrittura dell'immagine fallita per \(outputURL.lastPathComponent)")
        }
    }
    
    // MARK: - CLI Fallback Engine
    
    private func convertCLIFallback(inputURL: URL, outputURL: URL, format: String, grayscale: Bool) async throws {
        let plan = Self.cliFallbackCommand(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            cleanFormat: format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            grayscale: grayscale
        )

        // WebP senza ImageMagick è una garanzia di fallimento: sips non può
        // codificare WebP. Errore esplicito invece di un tentativo destinato
        // a fallire con stderr oscurо.
        if let reason = plan.failureReason {
            throw ExecutorError.executionFailed(reason)
        }

        let result = try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: plan.executable),
            arguments: plan.arguments
        )

        guard result.isSuccess else {
            throw ExecutorError.executionFailed("Conversione CLI fallita per \(inputURL.lastPathComponent): \(result.stderr)")
        }
    }

    /// Puro e iniettabile nei test: decide il comando CLI di fallback o il
    /// motivo per cui il formato non è convertibile.
    static func cliFallbackCommand(
        inputPath: String,
        outputPath: String,
        cleanFormat: String,
        grayscale: Bool,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (executable: String, arguments: [String], failureReason: String?) {
        let magickPaths = ["/opt/homebrew/bin/magick", "/usr/local/bin/magick"]

        if grayscale || cleanFormat == "webp" {
            if let magick = magickPaths.first(where: exists) {
                var args = [inputPath]
                if grayscale {
                    args.append(contentsOf: ["-colorspace", "Gray"])
                }
                args.append(outputPath)
                return (magick, args, nil)
            }
            // sips NON codifica WebP: errore esplicito, mai tentativo destinato al fallimento.
            if cleanFormat == "webp" {
                return ("", [], "La conversione in WebP richiede ImageMagick (non installato su questo Mac).")
            }
            if exists("/usr/bin/sips") {
                var args = ["-s", "format", cleanFormat == "jpg" ? "jpeg" : cleanFormat]
                if grayscale {
                    args.append(contentsOf: ["-s", "formatOptions", "gray"])
                }
                args.append(contentsOf: [inputPath, "--out", outputPath])
                return ("/usr/bin/sips", args, nil)
            }
            return ("", [], "Impossibile convertire l'immagine su questo Mac.")
        }

        let mappedSips = cleanFormat == "jpg" ? "jpeg" : cleanFormat
        return ("/usr/bin/sips", ["-s", "format", mappedSips, inputPath, "--out", outputPath], nil)
    }
    
    private func outputExtension(_ rawFormat: String) -> String {
        let cleaned = rawFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned == "jpeg" ? "jpg" : cleaned
    }
    
    private func outputURL(for inputURL: URL, extensionName: String, isGrayscale: Bool) -> URL {
        let suffix = isGrayscale ? "_bw" : ""
        return FileResolver.uniqueURL(
            in: inputURL.deletingLastPathComponent(),
            baseName: inputURL.deletingPathExtension().lastPathComponent + suffix,
            extensionName: extensionName
        )
    }
}

private enum ImageEncoding {
    static func source(at url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ExecutorError.executionFailed("Immagine non leggibile: \(url.lastPathComponent)")
        }
        return source
    }

    static func canWrite(_ type: String) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as NSArray).contains(type)
    }

    static func validate(at url: URL, type: String, count: Int) throws {
        let source = try source(at: url)
        guard CGImageSourceGetType(source) as String? == type, CGImageSourceGetCount(source) == count else {
            throw ExecutorError.executionFailed("Il formato o il numero di frame prodotti non corrisponde all'originale: \(url.lastPathComponent)")
        }
        for index in 0..<count {
            guard CGImageSourceCreateImageAtIndex(source, index, nil) != nil else {
                throw ExecutorError.executionFailed("Frame \(index + 1) prodotto non leggibile: \(url.lastPathComponent)")
            }
        }
    }
}

// MARK: - Resize Image Action

final class ResizeImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        let inputs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
        let width = Int(step.format?.replacingOccurrences(of: "px", with: "") ?? "1024") ?? 1024
        var outputFiles: [URL] = []
        do {
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, inputURL.lastPathComponent)
                let baseName = inputURL.deletingPathExtension().lastPathComponent + "_\(width)px"
                let output = FileResolver.uniqueURL(in: currentDirectory, baseName: baseName, extensionName: inputURL.pathExtension)
                try await StagedOutput.write(to: output, journal: &outputFiles) { temporary in
                    let args = ["--resampleWidth", "\(width)", inputURL.path, "--out", temporary.path]
                    let result = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/sips"), arguments: args)
                    guard result.isSuccess else {
                        throw ExecutorError.executionFailed("Elaborazione fallita per \(inputURL.lastPathComponent): \(result.stderr)")
                    }
                    try validateImageOutput(at: temporary)
                }
            }
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
        return ActionResult(success: true, outputFiles: outputFiles, message: "Ridimensionate \(outputFiles.count) immagini a \(width)px")
    }
}

// MARK: - Rotate Image Action

final class RotateImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        let inputs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
        let degrees = Int(step.format ?? "90") ?? 90
        var outputFiles: [URL] = []
        do {
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, inputURL.lastPathComponent)
                let baseName = inputURL.deletingPathExtension().lastPathComponent + "_r\(degrees)"
                let output = FileResolver.uniqueURL(in: currentDirectory, baseName: baseName, extensionName: inputURL.pathExtension)
                try await StagedOutput.write(to: output, journal: &outputFiles) { temporary in
                    let args = ["--rotate", "\(degrees)", inputURL.path, "--out", temporary.path]
                    let result = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/sips"), arguments: args)
                    guard result.isSuccess else {
                        throw ExecutorError.executionFailed("Elaborazione fallita per \(inputURL.lastPathComponent): \(result.stderr)")
                    }
                    try validateImageOutput(at: temporary)
                }
            }
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
        return ActionResult(success: true, outputFiles: outputFiles, message: "Ruotate \(outputFiles.count) immagini di \(degrees)°")
    }
}

// MARK: - Thumbnail Image Action

final class ThumbnailImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        let inputs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
        var outputFiles: [URL] = []
        do {
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, inputURL.lastPathComponent)
                let baseName = inputURL.deletingPathExtension().lastPathComponent + "_thumb"
                let output = FileResolver.uniqueURL(in: currentDirectory, baseName: baseName, extensionName: inputURL.pathExtension)
                try await StagedOutput.write(to: output, journal: &outputFiles) { temporary in
                    let args = ["--resampleWidth", "256", inputURL.path, "--out", temporary.path]
                    let result = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/sips"), arguments: args)
                    guard result.isSuccess else {
                        throw ExecutorError.executionFailed("Elaborazione fallita per \(inputURL.lastPathComponent): \(result.stderr)")
                    }
                    try validateImageOutput(at: temporary)
                }
            }
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
        return ActionResult(success: true, outputFiles: outputFiles, message: "Create \(outputFiles.count) miniature (256px)")
    }
}

// MARK: - Strip EXIF Action

final class StripExifImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        let inputs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
        var outputFiles: [URL] = []
        do {
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, inputURL.lastPathComponent)
                let source = try ImageEncoding.source(at: inputURL)
                guard let sourceType = CGImageSourceGetType(source) else {
                    throw ExecutorError.executionFailed("Tipo immagine non riconosciuto: \(inputURL.lastPathComponent)")
                }
                let type = sourceType as String
                guard ImageEncoding.canWrite(type), let extensionName = UTType(type)?.preferredFilenameExtension else {
                    throw ExecutorError.executionFailed("ImageIO non può rimuovere i metadati conservando il formato \(type).")
                }
                let sourceExtension = inputURL.pathExtension
                let matchingExtension = UTType(filenameExtension: sourceExtension)?.identifier == type ? sourceExtension : extensionName
                let baseName = inputURL.deletingPathExtension().lastPathComponent + "_clean"
                let output = FileResolver.uniqueURL(in: currentDirectory, baseName: baseName, extensionName: matchingExtension)
                try await StagedOutput.write(to: output, journal: &outputFiles) { temporary in
                    let count = CGImageSourceGetCount(source)
                    guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, sourceType, count, nil) else {
                        throw ExecutorError.executionFailed("ImageIO non può scrivere il formato \(type).")
                    }
                    CGImageDestinationSetProperties(destination, Self.displayProperties(CGImageSourceCopyProperties(source, nil)) as CFDictionary)
                    for frame in 0..<count {
                        try Task.checkCancellation()
                        guard let image = CGImageSourceCreateImageAtIndex(source, frame, nil) else {
                            throw ExecutorError.executionFailed("Frame \(frame + 1) non leggibile in \(inputURL.lastPathComponent)")
                        }
                        // Decode pixels instead of copying source metadata (including XMP/private tags).
                        let properties = Self.displayProperties(CGImageSourceCopyPropertiesAtIndex(source, frame, nil))
                        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
                    }
                    guard CGImageDestinationFinalize(destination) else {
                        throw ExecutorError.executionFailed("Rimozione metadati fallita per \(inputURL.lastPathComponent)")
                    }
                    try ImageEncoding.validate(at: temporary, type: type, count: count)
                }
            }
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
        return ActionResult(success: true, outputFiles: outputFiles, message: "Rimossi metadati EXIF da \(outputFiles.count) immagini")
    }

    /// Allow only rendering properties. Unknown dictionaries and descriptive/private tags are not copied.
    private static func displayProperties(_ raw: CFDictionary?) -> [String: Any] {
        guard let properties = raw as? [String: Any] else { return [:] }
        let keys = [kCGImagePropertyOrientation, kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight, kCGImagePropertyProfileName]
        var clean: [String: Any] = [:]
        for key in keys { clean[key as String] = properties[key as String] }
        let dictionaries: [String: Set<String>] = [
            kCGImagePropertyTIFFDictionary as String: ["Orientation", "XResolution", "YResolution", "ResolutionUnit", "WhitePoint", "PrimaryChromaticities"],
            kCGImagePropertyPNGDictionary as String: ["Gamma", "Chromaticities", "sRGBIntent", "XPixelsPerMeter", "YPixelsPerMeter", "LoopCount", "DelayTime", "UnclampedDelayTime"],
            kCGImagePropertyGIFDictionary as String: ["LoopCount", "DelayTime", "UnclampedDelayTime", "ImageColorMap", "HasGlobalColorMap"],
            "{HEICS}": ["LoopCount", "DelayTime", "UnclampedDelayTime"],
            "{WebP}": ["LoopCount", "DelayTime", "UnclampedDelayTime"]
        ]
        for (key, allowed) in dictionaries {
            if let values = properties[key] as? [String: Any] {
                let retained = values.filter { allowed.contains($0.key) }
                if !retained.isEmpty { clean[key] = retained }
            }
        }
        return clean
    }
}

// MARK: - Vision OCR Rename Action

final class OCRRenameImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let targetURLs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
        
        var renamedURLs: [URL] = []
        var backups: [URL: URL] = [:]
        do {
            for (index, inputURL) in targetURLs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, targetURLs.count, inputURL.lastPathComponent)
                guard let text = try recognizeText(in: inputURL), !text.isEmpty else { continue }
                let sanitized = sanitizeFilename(text)
                guard !sanitized.isEmpty else { continue }
                let proposed = currentDirectory.appendingPathComponent("\(sanitized).\(inputURL.pathExtension)")
                guard proposed.standardizedFileURL != inputURL.standardizedFileURL else { continue }
                let target = FileResolver.uniqueURL(in: currentDirectory, baseName: sanitized, extensionName: inputURL.pathExtension)
                let result = try Self.rename(inputURL: inputURL, targetURL: target)
                renamedURLs.append(contentsOf: result.outputFiles)
                backups.merge(result.backupURLs) { first, _ in first }
            }
        } catch {
            let underlying: Error
            if let failure = error as? ActionExecutionError {
                renamedURLs.append(contentsOf: failure.partialResult.outputFiles)
                backups.merge(failure.partialResult.backupURLs) { first, _ in first }
                underlying = failure.underlying
            } else {
                underlying = error
            }
            throw ActionExecutionError(underlying: underlying, partialResult: ActionResult(success: false, outputFiles: renamedURLs, message: nil, backupURLs: backups))
        }
        return ActionResult(success: true, outputFiles: renamedURLs, message: "Rinominate \(renamedURLs.count) immagini in base al testo riconosciuto con Apple Vision OCR", backupURLs: backups)
    }

    /// Applies an already determined OCR target without relying on Vision recognition.
    static func rename(inputURL: URL, targetURL: URL) throws -> ActionResult {
        guard inputURL.standardizedFileURL != targetURL.standardizedFileURL else {
            return ActionResult(success: true, outputFiles: [], message: nil)
        }
        var outputs: [URL] = []
        var backups: [URL: URL] = [:]
        do {
            try Task.checkCancellation()
            let backupDirectory = try BackupStore.newBackupDirectory()
            let backup = backupDirectory.appendingPathComponent(UUID().uuidString)
            outputs.append(backup)
            try FileManager.default.copyItem(at: inputURL, to: backup)
            backups[inputURL] = backup
            outputs.removeLast()
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: inputURL, to: targetURL)
            outputs.append(targetURL)
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputs, message: nil, backupURLs: backups))
        }
        return ActionResult(success: true, outputFiles: outputs, message: nil, backupURLs: backups)
    }
    
    private func recognizeText(in url: URL) throws -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExecutorError.executionFailed("Impossibile decodificare l'immagine \(url.lastPathComponent)")
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        try requestHandler.perform([request])
        try Task.checkCancellation()
        guard let observations = request.results, !observations.isEmpty else { return nil }
        let recognizedStrings = observations.compactMap { $0.topCandidates(1).first?.string }
        return recognizedStrings.prefix(3).joined(separator: "_")
    }
    
    private func sanitizeFilename(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let filtered = input.components(separatedBy: allowed.inverted).joined(separator: "")
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return String(trimmed.prefix(40))
    }
}


