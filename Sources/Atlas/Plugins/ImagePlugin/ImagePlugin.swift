import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Vision

private struct ImageInput: Sendable {
    let inputURL: URL
    let outputURL: URL
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

final class ConvertImageAction: ActionExecutor {
    private static let readableFormats: Set<String> = MediaFormats.image
    
    private func resolveInputURLs(step: ActionStep, context: FinderContext) -> [URL] {
        guard let currentDirectory = context.currentDirectory else { return [] }
        
        let matchingSelected = context.selectedFiles.filter { url in
            Self.readableFormats.contains(url.pathExtension.lowercased())
        }
        
        // 1. If files are selected in Finder, and step inputs cover a subset or all of them, operate on ALL matching selected files
        if !matchingSelected.isEmpty {
            let selectedNames = Set(matchingSelected.map { $0.lastPathComponent })
            let stepInputNames = Set(step.inputs)
            
            // If LLM returned empty inputs, or inputs that are part of selected files, use ALL selected matching files
            if step.inputs.isEmpty || !stepInputNames.isDisjoint(with: selectedNames) {
                return matchingSelected
            }
        }
        
        // 2. If explicit inputs provided by step, resolve them
        if !step.inputs.isEmpty {
            return step.inputs.compactMap { inputPath in
                let url = currentDirectory.appendingPathComponent(inputPath)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        
        // 3. Otherwise scan current directory for matching readable image files
        guard let contents = try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        
        return contents.filter { url in
            Self.readableFormats.contains(url.pathExtension.lowercased())
        }
    }
    
    func validate(step: ActionStep, context: FinderContext) throws {
        let resolved = resolveInputURLs(step: step, context: context)
        guard !resolved.isEmpty else {
            throw ExecutorError.validationFailed("Nessun file immagine trovato nella cartella o tra i file selezionati.")
        }
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let rawFormat = step.format ?? "png"
        let inputURLs = resolveInputURLs(step: step, context: context)
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
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let inputURLs = resolveInputURLs(step: step, context: context)
        guard !inputURLs.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun file immagine trovato da elaborare.")
        }
        
        // If format is nil but grayscale is requested, maintain input extension
        let isGrayscale = step.grayscale == true
        
        let converted = try await withThrowingTaskGroup(of: URL.self) { group in
            var outputFiles: [URL] = []
            outputFiles.reserveCapacity(inputURLs.count)
            
            for inputURL in inputURLs {
                let formatForInput = step.format ?? inputURL.pathExtension
                let targetExtension = outputExtension(formatForInput)
                let outputURL = self.outputURL(for: inputURL, extensionName: targetExtension, isGrayscale: isGrayscale)
                
                let quality = step.quality
                group.addTask {
                    do {
                        try self.convertImageIO(inputURL: inputURL, outputURL: outputURL, format: formatForInput, grayscale: isGrayscale, quality: quality)
                        return outputURL
                    } catch {
                        try await self.convertCLIFallback(inputURL: inputURL, outputURL: outputURL, format: formatForInput, grayscale: isGrayscale)
                        return outputURL
                    }
                }
            }
            
            for try await output in group {
                outputFiles.append(output)
            }
            return outputFiles
        }
        
        let label = isGrayscale ? "in Bianco e Nero" : "nel formato specificato"
        return ActionResult(
            success: true,
            outputFiles: converted,
            message: "Elaborate \(converted.count) immagini \(label)"
        )
    }
    
    // MARK: - Native ImageIO Engine (Supports Grayscale / Black & White)
    
    private func convertImageIO(inputURL: URL, outputURL: URL, format: String, grayscale: Bool, quality: Int?) throws {
        guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              var cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExecutorError.executionFailed("Impossibile decodificare l'immagine \(inputURL.lastPathComponent)")
        }
        
        // Convert to Grayscale if requested
        if grayscale {
            if let graySpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
               let grayContext = CGContext(data: nil, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                grayContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
                if let grayImage = grayContext.makeImage() {
                    cgImage = grayImage
                }
            }
        }
        
        let cleanFormat = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let utiString: String = switch cleanFormat {
        case "webp": "org.webmproject.webp"
        case "jpg", "jpeg": "public.jpeg"
        case "png": "public.png"
        case "heic": "public.heic"
        case "tiff", "tif": "public.tiff"
        case "gif": "com.compuserve.gif"
        default: UTType(filenameExtension: cleanFormat)?.identifier ?? "public.jpeg"
        }
        
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, utiString as CFString, 1, nil) else {
            throw ExecutorError.executionFailed("Impossibile creare il gestore di scrittura per il formato \(format)")
        }
        
        let options = NSMutableDictionary()
        if let quality = quality {
            let q = Float(max(1, min(100, quality))) / 100.0
            options[kCGImageDestinationLossyCompressionQuality] = q
        }
        
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExecutorError.executionFailed("Scrittura dell'immagine fallita per \(outputURL.lastPathComponent)")
        }
    }
    
    // MARK: - CLI Fallback Engine
    
    private func convertCLIFallback(inputURL: URL, outputURL: URL, format: String, grayscale: Bool) async throws {
        let cleanFormat = format.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let executableURL: URL
        let arguments: [String]
        
        if grayscale || cleanFormat == "webp" {
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/magick") || FileManager.default.fileExists(atPath: "/usr/local/bin/magick") {
                let bin = FileManager.default.fileExists(atPath: "/opt/homebrew/bin/magick") ? "/opt/homebrew/bin/magick" : "/usr/local/bin/magick"
                executableURL = URL(fileURLWithPath: bin)
                var args = [inputURL.path]
                if grayscale {
                    args.append(contentsOf: ["-colorspace", "Gray"])
                }
                args.append(outputURL.path)
                arguments = args
            } else if FileManager.default.fileExists(atPath: "/usr/bin/sips") {
                executableURL = URL(fileURLWithPath: "/usr/bin/sips")
                var args = ["-s", "format", cleanFormat == "jpg" ? "jpeg" : cleanFormat]
                if grayscale {
                    args.append(contentsOf: ["-s", "formatOptions", "gray"])
                }
                args.append(contentsOf: [inputURL.path, "--out", outputURL.path])
                arguments = args
            } else {
                throw ExecutorError.executionFailed("Impossibile convertire l'immagine su questo Mac.")
            }
        } else {
            let mappedSips = cleanFormat == "jpg" ? "jpeg" : cleanFormat
            executableURL = URL(fileURLWithPath: "/usr/bin/sips")
            arguments = ["-s", "format", mappedSips, inputURL.path, "--out", outputURL.path]
        }
        
        let result = try await AsyncProcessRunner.run(executableURL: executableURL, arguments: arguments)
        
        guard result.isSuccess else {
            throw ExecutorError.executionFailed("Conversione CLI fallita per \(inputURL.lastPathComponent): \(result.stderr)")
        }
    }
    
    private func outputExtension(_ rawFormat: String) -> String {
        let cleaned = rawFormat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return cleaned == "jpeg" ? "jpg" : cleaned
    }
    
    private func outputURL(for inputURL: URL, extensionName: String, isGrayscale: Bool) -> URL {
        let suffix = isGrayscale ? "_bw" : ""
        let baseName = inputURL.deletingPathExtension().lastPathComponent + suffix
        let directory = inputURL.deletingLastPathComponent()
        
        var candidate = directory.appendingPathComponent("\(baseName).\(extensionName)")
        
        // Prevent writing over input file or failing if destination file already exists from a previous run
        if candidate.path == inputURL.path || FileManager.default.fileExists(atPath: candidate.path) {
            var counter = 2
            while candidate.path == inputURL.path || FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(baseName)-\(counter).\(extensionName)")
                counter += 1
            }
        }
        
        return candidate
    }
}

// MARK: - Resize Image Action

final class ResizeImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard context.currentDirectory != nil else {
            throw ExecutorError.validationFailed("Cartella corrente non disponibile.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let inputs = step.inputs.compactMap { inputPath in
            let url = currentDirectory.appendingPathComponent(inputPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard !inputs.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun file trovato per il ridimensionamento.")
        }
        
        let width = Int(step.format?.replacingOccurrences(of: "px", with: "") ?? "1024") ?? 1024
        var outputFiles: [URL] = []
        
        for inputURL in inputs {
            let baseName = inputURL.deletingPathExtension().lastPathComponent + "_\(width)px"
            let ext = inputURL.pathExtension
            let outputURL = currentDirectory.appendingPathComponent("\(baseName).\(ext)")
            
            let sips = URL(fileURLWithPath: "/usr/bin/sips")
            let args = ["--resampleWidth", "\(width)", inputURL.path, "--out", outputURL.path]
            let result = try await AsyncProcessRunner.run(executableURL: sips, arguments: args)
            
            if result.isSuccess {
                outputFiles.append(outputURL)
            }
        }
        
        return ActionResult(success: true, outputFiles: outputFiles, message: "Ridimensionate \(outputFiles.count) immagini a \(width)px")
    }
}

// MARK: - Rotate Image Action

final class RotateImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard context.currentDirectory != nil else {
            throw ExecutorError.validationFailed("Cartella corrente non disponibile.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let inputs = step.inputs.compactMap { inputPath in
            let url = currentDirectory.appendingPathComponent(inputPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard !inputs.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun file trovato per la rotazione.")
        }
        
        let degrees = Int(step.format ?? "90") ?? 90
        var outputFiles: [URL] = []
        
        for inputURL in inputs {
            let baseName = inputURL.deletingPathExtension().lastPathComponent + "_r\(degrees)"
            let ext = inputURL.pathExtension
            let outputURL = currentDirectory.appendingPathComponent("\(baseName).\(ext)")
            
            let sips = URL(fileURLWithPath: "/usr/bin/sips")
            let args = ["--rotate", "\(degrees)", inputURL.path, "--out", outputURL.path]
            let result = try await AsyncProcessRunner.run(executableURL: sips, arguments: args)
            
            if result.isSuccess {
                outputFiles.append(outputURL)
            }
        }
        
        return ActionResult(success: true, outputFiles: outputFiles, message: "Ruotate \(outputFiles.count) immagini di \(degrees)°")
    }
}

// MARK: - Thumbnail Image Action

final class ThumbnailImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard context.currentDirectory != nil else {
            throw ExecutorError.validationFailed("Cartella corrente non disponibile.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let inputs = step.inputs.compactMap { inputPath in
            let url = currentDirectory.appendingPathComponent(inputPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard !inputs.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun file trovato per le miniature.")
        }
        
        var outputFiles: [URL] = []
        
        for inputURL in inputs {
            let baseName = inputURL.deletingPathExtension().lastPathComponent + "_thumb"
            let ext = inputURL.pathExtension
            let outputURL = currentDirectory.appendingPathComponent("\(baseName).\(ext)")
            
            let sips = URL(fileURLWithPath: "/usr/bin/sips")
            let args = ["--resampleWidth", "256", inputURL.path, "--out", outputURL.path]
            let result = try await AsyncProcessRunner.run(executableURL: sips, arguments: args)
            
            if result.isSuccess {
                outputFiles.append(outputURL)
            }
        }
        
        return ActionResult(success: true, outputFiles: outputFiles, message: "Create \(outputFiles.count) miniature (256px)")
    }
}

// MARK: - Strip EXIF Action

final class StripExifImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard context.currentDirectory != nil else {
            throw ExecutorError.validationFailed("Cartella corrente non disponibile.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let inputs = step.inputs.compactMap { inputPath in
            let url = currentDirectory.appendingPathComponent(inputPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        guard !inputs.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun file trovato per la pulizia metadati.")
        }
        
        var outputFiles: [URL] = []
        
        for inputURL in inputs {
            let baseName = inputURL.deletingPathExtension().lastPathComponent + "_clean"
            let ext = inputURL.pathExtension
            let outputURL = currentDirectory.appendingPathComponent("\(baseName).\(ext)")
            
            // Native sips re-compression strips EXIF data cleanly without third party tools
            let sips = URL(fileURLWithPath: "/usr/bin/sips")
            let args = ["-s", "format", ext == "png" ? "png" : "jpeg", inputURL.path, "--out", outputURL.path]
            let result = try await AsyncProcessRunner.run(executableURL: sips, arguments: args)
            
            if result.isSuccess {
                outputFiles.append(outputURL)
            }
        }
        
        return ActionResult(success: true, outputFiles: outputFiles, message: "Rimossi metadati EXIF da \(outputFiles.count) immagini")
    }
}

// MARK: - Vision OCR Rename Action

final class OCRRenameImageAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard context.currentDirectory != nil else {
            throw ExecutorError.validationFailed("Cartella corrente non disponibile.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let inputs = step.inputs.compactMap { inputPath -> URL? in
            let url = currentDirectory.appendingPathComponent(inputPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        
        let targetURLs: [URL]
        if !inputs.isEmpty {
            targetURLs = inputs
        } else {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tiff"]
            targetURLs = context.selectedFiles.isEmpty ?
                context.visibleFiles.filter { imageExts.contains($0.pathExtension.lowercased()) } :
                context.selectedFiles.filter { imageExts.contains($0.pathExtension.lowercased()) }
        }
        
        guard !targetURLs.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessuna immagine trovata per il riconoscimento OCR.")
        }
        
        var renamedURLs: [URL] = []
        
        for inputURL in targetURLs {
            guard let text = recognizeText(in: inputURL), !text.isEmpty else { continue }
            let sanitized = sanitizeFilename(text)
            guard !sanitized.isEmpty else { continue }
            
            let ext = inputURL.pathExtension
            let newName = "\(sanitized).\(ext)"
            let targetURL = currentDirectory.appendingPathComponent(newName)
            
            if targetURL.path != inputURL.path && !FileManager.default.fileExists(atPath: targetURL.path) {
                do {
                    try FileManager.default.moveItem(at: inputURL, to: targetURL)
                    renamedURLs.append(targetURL)
                } catch {
                    print("Failed to rename \(inputURL.lastPathComponent): \(error)")
                }
            }
        }
        
        return ActionResult(
            success: true,
            outputFiles: renamedURLs,
            message: "Rinominate \(renamedURLs.count) immagini in base al testo riconosciuto con Apple Vision OCR"
        )
    }
    
    private func recognizeText(in url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        do {
            try requestHandler.perform([request])
            guard let observations = request.results, !observations.isEmpty else { return nil }
            let recognizedStrings = observations.compactMap { $0.topCandidates(1).first?.string }
            return recognizedStrings.prefix(3).joined(separator: "_")
        } catch {
            return nil
        }
    }
    
    private func sanitizeFilename(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let filtered = input.components(separatedBy: allowed.inverted).joined(separator: "")
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
        return String(trimmed.prefix(40))
    }
}


