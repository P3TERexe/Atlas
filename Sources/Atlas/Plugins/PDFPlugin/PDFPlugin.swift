import Foundation
import PDFKit
import AppKit

// MARK: - Plugin

class PDFPlugin: AtlasPlugin {
    let id = "pdf"
    
    var capabilities: [ToolCapability] {
        [
            ToolCapability(
                id: "pdf.merge",
                description: "Merges multiple PDF files into a single one. Set 'format' to the output filename (default: merged.pdf).",
                inputFormats: ["pdf"],
                outputFormats: ["pdf"],
                executor: MergePDFAction()
            ),
            ToolCapability(
                id: "pdf.fromImages",
                description: "Combines multiple image files (png, jpg, webp, heic, tiff) into a single multi-page PDF document. Set 'format' to output filename (default: combined.pdf).",
                inputFormats: Array(MediaFormats.image).sorted(),
                outputFormats: ["pdf"],
                executor: ImagesToPDFAction()
            ),
            ToolCapability(
                id: "pdf.split",
                description: "Splits a PDF into single-page PDF files. Set 'format' to the output filename prefix (default: input name).",
                inputFormats: ["pdf"],
                outputFormats: ["pdf"],
                executor: SplitPDFAction()
            ),
            ToolCapability(
                id: "pdf.compress",
                description: "Compresses a PDF to reduce its size using Ghostscript (fallback ImageMagick). Set 'quality' from 1 to 100 (default 60).",
                inputFormats: ["pdf"],
                outputFormats: ["pdf"],
                executor: CompressPDFAction()
            ),
        ]
    }
}

// MARK: - Shared input resolution

enum PDFResolver {
    static func resolveInputURLs(step: ActionStep, context: FinderContext) -> [URL] {
        guard let currentDirectory = context.currentDirectory else { return [] }
        
        let matchingSelected = context.selectedFiles.filter { url in
            url.pathExtension.lowercased() == "pdf"
        }
        
        if !matchingSelected.isEmpty {
            let selectedNames = Set(matchingSelected.map { $0.lastPathComponent })
            let stepInputNames = Set(step.inputs)
            if step.inputs.isEmpty || !stepInputNames.isDisjoint(with: selectedNames) {
                return matchingSelected
            }
        }
        
        if !step.inputs.isEmpty {
            return step.inputs.compactMap { inputPath in
                let url = currentDirectory.appendingPathComponent(inputPath)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        
        return contents.filter { url in
            url.pathExtension.lowercased() == "pdf"
        }
    }
    
    static func validateNonEmpty(step: ActionStep, context: FinderContext) throws {
        guard !resolveInputURLs(step: step, context: context).isEmpty else {
            throw ExecutorError.validationFailed("Nessun file PDF trovato nella cartella o tra i file selezionati.")
        }
    }
    
    static func uniqueURL(in directory: URL, baseName: String, extensionName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName + "." + extensionName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(baseName + "-\(counter)." + extensionName)
            counter += 1
        }
        return candidate
    }
}

// MARK: - Merge

final class MergePDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        let inputs = PDFResolver.resolveInputURLs(step: step, context: context)
        guard inputs.count >= 2 else {
            throw ExecutorError.validationFailed("Servono almeno 2 file PDF da unire.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let inputs = PDFResolver.resolveInputURLs(step: step, context: context)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "merged"
        let baseName = (rawName as NSString).deletingPathExtension
        let outputURL = PDFResolver.uniqueURL(in: directory, baseName: baseName, extensionName: "pdf")
        
        let outputDocument = PDFDocument()
        
        for inputURL in inputs {
            guard let document = PDFDocument(url: inputURL) else {
                throw ExecutorError.executionFailed("Impossibile aprire \(inputURL.lastPathComponent)")
            }
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                outputDocument.insert(page, at: outputDocument.pageCount)
            }
        }
        
        guard outputDocument.write(to: outputURL) else {
            throw ExecutorError.executionFailed("Scrittura del PDF unito fallita.")
        }
        
        return ActionResult(
            success: true,
            outputFiles: [outputURL],
            message: "Uniti \(inputs.count) PDF in \(outputURL.lastPathComponent) (\(outputDocument.pageCount) pagine)"
        )
    }
}

// MARK: - Split

final class SplitPDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try PDFResolver.validateNonEmpty(step: step, context: context)
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let inputs = PDFResolver.resolveInputURLs(step: step, context: context)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        var outputFiles: [URL] = []
        
        for inputURL in inputs {
            guard let document = PDFDocument(url: inputURL) else {
                throw ExecutorError.executionFailed("Impossibile aprire \(inputURL.lastPathComponent)")
            }
            
            let rawPrefix = step.format?.trimmingCharacters(in: .whitespacesAndNewlines) ?? inputURL.deletingPathExtension().lastPathComponent
            let prefix = (rawPrefix as NSString).deletingPathExtension
            
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                
                let pageDocument = PDFDocument()
                pageDocument.insert(page, at: 0)
                
                let outputURL = PDFResolver.uniqueURL(in: directory, baseName: "\(prefix)-page-\(pageIndex + 1)", extensionName: "pdf")
                guard pageDocument.write(to: outputURL) else {
                    throw ExecutorError.executionFailed("Scrittura pagina \(pageIndex + 1) fallita.")
                }
                outputFiles.append(outputURL)
            }
        }
        
        return ActionResult(
            success: true,
            outputFiles: outputFiles,
            message: "Divisi in \(outputFiles.count) pagine PDF"
        )
    }
}

// MARK: - Compress

final class CompressPDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try PDFResolver.validateNonEmpty(step: step, context: context)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let inputs = PDFResolver.resolveInputURLs(step: step, context: context)
        guard !inputs.isEmpty, let directory = context.currentDirectory else { return nil }
        
        let quality = step.quality ?? 60
        let setting = Self.pdfSetting(for: quality)
        
        return inputs.map { inputURL in
            let outputURL = PDFResolver.uniqueURL(in: directory, baseName: inputURL.deletingPathExtension().lastPathComponent + "-compressed", extensionName: "pdf")
            return "gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/\(setting) -dNOPAUSE -dQUIET -dBATCH -sOutputFile=\(outputURL.path) \(inputURL.path)"
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let inputs = PDFResolver.resolveInputURLs(step: step, context: context)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let quality = step.quality ?? 60
        let setting = Self.pdfSetting(for: quality)
        
        var outputFiles: [URL] = []
        var compressedAny = false
        
        for inputURL in inputs {
            let outputURL = PDFResolver.uniqueURL(in: directory, baseName: inputURL.deletingPathExtension().lastPathComponent + "-compressed", extensionName: "pdf")
            
            if let gs = Self.ghostscriptBinary() {
                let status = try await run(binary: gs, arguments: [
                    "-sDEVICE=pdfwrite",
                    "-dCompatibilityLevel=1.4",
                    "-dPDFSETTINGS=/\(setting)",
                    "-dNOPAUSE",
                    "-dQUIET",
                    "-dBATCH",
                    "-sOutputFile=\(outputURL.path)",
                    inputURL.path
                ])
                if status == 0 && FileManager.default.fileExists(atPath: outputURL.path) {
                    outputFiles.append(outputURL)
                    compressedAny = true
                    continue
                }
            }
            
            if let magick = Self.imageMagickBinary() {
                let density = setting == "screen" ? "96" : setting == "ebook" ? "150" : "200"
                let magickQuality = setting == "screen" ? "50" : setting == "ebook" ? "70" : "90"
                let status = try await run(binary: magick, arguments: [
                    "-density", density,
                    "-compress", "JPEG",
                    "-quality", magickQuality,
                    inputURL.path,
                    outputURL.path
                ])
                if status == 0 && FileManager.default.fileExists(atPath: outputURL.path) {
                    outputFiles.append(outputURL)
                    compressedAny = true
                    continue
                }
            }
            
            throw ExecutorError.executionFailed(
                "Nessuno strumento di compressione disponibile. Installa Ghostscript (brew install ghostscript) o ImageMagick (brew install imagemagick)."
            )
        }
        
        return ActionResult(
            success: compressedAny,
            outputFiles: outputFiles,
            message: compressedAny ? "Compressi \(outputFiles.count) PDF (livello \(setting))" : "Nessun PDF compresso."
        )
    }
    
    // MARK: Helpers
    
    private static func pdfSetting(for quality: Int) -> String {
        if quality < 35 { return "screen" }
        if quality <= 70 { return "ebook" }
        return "printer"
    }
    
    private static func ghostscriptBinary() -> String? {
        for path in ["/opt/homebrew/bin/gs", "/usr/local/bin/gs", "/usr/bin/gs"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private static func imageMagickBinary() -> String? {
        for path in ["/opt/homebrew/bin/magick", "/usr/local/bin/magick"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private func run(binary: String, arguments: [String]) async throws -> Int32 {
        let result = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: binary), arguments: arguments)
        return result.exitCode
    }
}

// MARK: - Images To PDF Action

final class ImagesToPDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        let inputs = resolveImageURLs(step: step, context: context)
        guard !inputs.isEmpty else {
            throw ExecutorError.validationFailed("Nessuna immagine trovata da unire in PDF.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let inputs = resolveImageURLs(step: step, context: context)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "combined"
        let baseName = (rawName as NSString).deletingPathExtension
        let outputURL = PDFResolver.uniqueURL(in: directory, baseName: baseName, extensionName: "pdf")
        
        let pdfDocument = PDFDocument()
        var pagesAdded = 0
        
        for inputURL in inputs {
            guard let image = NSImage(contentsOf: inputURL),
                  let pdfPage = PDFPage(image: image) else { continue }
            pdfDocument.insert(pdfPage, at: pdfDocument.pageCount)
            pagesAdded += 1
        }
        
        guard pagesAdded > 0, pdfDocument.write(to: outputURL) else {
            throw ExecutorError.executionFailed("Creazione del PDF dalle immagini fallita.")
        }
        
        return ActionResult(
            success: true,
            outputFiles: [outputURL],
            message: "Create \(pagesAdded) pagine in \(outputURL.lastPathComponent) a partire da \(inputs.count) immagini"
        )
    }
    
    private func resolveImageURLs(step: ActionStep, context: FinderContext) -> [URL] {
        guard let currentDirectory = context.currentDirectory else { return [] }
        let imageExts = MediaFormats.image
        
        let matchingSelected = context.selectedFiles.filter { url in
            imageExts.contains(url.pathExtension.lowercased())
        }
        
        if !matchingSelected.isEmpty {
            return matchingSelected
        }
        
        if !step.inputs.isEmpty {
            return step.inputs.compactMap { inputPath in
                let url = currentDirectory.appendingPathComponent(inputPath)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        
        return context.visibleFiles.filter { url in
            imageExts.contains(url.pathExtension.lowercased())
        }
    }
}
