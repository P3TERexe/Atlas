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
                description: "Compresses a PDF to reduce its size using Ghostscript while preserving pages and searchable text. Set 'quality' from 1 to 100 (default 60).",
                inputFormats: ["pdf"],
                outputFormats: ["pdf"],
                executor: CompressPDFAction()
            ),
        ]
    }
}

// MARK: - Merge

final class MergePDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        let inputs = try InputResolver.resolve(step: step, context: context, extensions: ["pdf"])
        guard inputs.count >= 2 else {
            throw ExecutorError.validationFailed("Servono almeno 2 file PDF da unire.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        var outputFiles: [URL] = []
        do {
            let inputs = try InputResolver.resolve(step: step, context: context, extensions: ["pdf"])
            guard let directory = context.currentDirectory else {
                throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
            }

            let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "merged"
            let baseName = (rawName as NSString).deletingPathExtension
            let outputURL = FileResolver.uniqueURL(in: directory, baseName: baseName, extensionName: "pdf")
            let outputDocument = PDFDocument()

            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, "Unione: \(inputURL.lastPathComponent)")
                let document = try readablePDF(at: inputURL, inputIndex: index + 1)
                for pageIndex in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex), page.pageRef != nil else {
                        throw ExecutorError.executionFailed("Pagina \(pageIndex + 1) non leggibile in \(inputURL.lastPathComponent) (input \(index + 1)).")
                    }
                    outputDocument.insert(page, at: outputDocument.pageCount)
                }
            }

            try await StagedOutput.write(to: outputURL, journal: &outputFiles) { temporaryURL in
                guard outputDocument.write(to: temporaryURL) else {
                    throw ExecutorError.executionFailed("Scrittura del PDF unito fallita.")
                }
            }
            return ActionResult(
                success: true,
                outputFiles: outputFiles,
                message: "Uniti \(inputs.count) PDF in \(outputURL.lastPathComponent) (\(outputDocument.pageCount) pagine)"
            )
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
    }
}

// MARK: - Split

final class SplitPDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: ["pdf"])
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        var outputFiles: [URL] = []
        do {
            let inputs = try InputResolver.resolve(step: step, context: context, extensions: ["pdf"])
            guard let directory = context.currentDirectory else {
                throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
            }
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, "Divisione: \(inputURL.lastPathComponent)")
                let document = try readablePDF(at: inputURL, inputIndex: index + 1)
                let rawPrefix = step.format?.trimmingCharacters(in: .whitespacesAndNewlines) ?? inputURL.deletingPathExtension().lastPathComponent
                let prefix = (rawPrefix as NSString).deletingPathExtension
                for pageIndex in 0..<document.pageCount {
                    try Task.checkCancellation()
                    guard let page = document.page(at: pageIndex), page.pageRef != nil else {
                        throw ExecutorError.executionFailed("Pagina \(pageIndex + 1) non leggibile in \(inputURL.lastPathComponent) (input \(index + 1)).")
                    }
                    let pageDocument = PDFDocument()
                    pageDocument.insert(page, at: 0)
                    let outputURL = FileResolver.uniqueURL(in: directory, baseName: "\(prefix)-page-\(pageIndex + 1)", extensionName: "pdf")
                    try await StagedOutput.write(to: outputURL, journal: &outputFiles) { temporaryURL in
                        guard pageDocument.write(to: temporaryURL) else {
                            throw ExecutorError.executionFailed("Scrittura pagina \(pageIndex + 1) fallita.")
                        }
                    }
                }
            }
            return ActionResult(success: true, outputFiles: outputFiles, message: "Divisi in \(outputFiles.count) pagine PDF")
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
    }
}

// MARK: - Compress

final class CompressPDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: ["pdf"])
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        guard let inputs = try? InputResolver.resolve(step: step, context: context, extensions: ["pdf"]) else { return nil }
        guard !inputs.isEmpty, let directory = context.currentDirectory else { return nil }
        
        let quality = step.quality ?? 60
        let setting = Self.pdfSetting(for: quality)
        
        return inputs.map { inputURL in
            let outputURL = FileResolver.uniqueURL(in: directory, baseName: inputURL.deletingPathExtension().lastPathComponent + "-compressed", extensionName: "pdf")
            return ([BinaryLocator.locate("gs") ?? "gs"] + Self.arguments(input: inputURL, output: outputURL, setting: setting)).map(ZipFilesAction.shellQuote).joined(separator: " ")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        var outputFiles: [URL] = []
        do {
            let inputs = try InputResolver.resolve(step: step, context: context, extensions: ["pdf"])
            guard let directory = context.currentDirectory else {
                throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
            }
            guard let gs = BinaryLocator.locate("gs") else {
                throw ExecutorError.executionFailed("Compressione PDF richiede Ghostscript. Installa Ghostscript (brew install ghostscript).")
            }
            let setting = Self.pdfSetting(for: step.quality ?? 60)
            var unchangedCount = 0
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, "Compressione: \(inputURL.lastPathComponent)")
                let source = try readablePDF(at: inputURL, inputIndex: index + 1)
                let outputURL = FileResolver.uniqueURL(in: directory, baseName: inputURL.deletingPathExtension().lastPathComponent + "-compressed", extensionName: "pdf")
                let temporaryURL = directory.appendingPathComponent(".atlas-output-\(UUID().uuidString).pdf")
                outputFiles.append(temporaryURL)
                let result = try await AsyncProcessRunner.run(
                    executableURL: URL(fileURLWithPath: gs),
                    arguments: Self.arguments(input: inputURL, output: temporaryURL, setting: setting)
                )
                guard result.isSuccess else {
                    throw ExecutorError.executionFailed("Ghostscript fallito per \(inputURL.lastPathComponent) (input \(index + 1), codice \(result.exitCode)): \(result.stderr)")
                }
                let compressed = try readablePDF(at: temporaryURL, inputIndex: index + 1)
                guard compressed.pageCount == source.pageCount else {
                    throw ExecutorError.executionFailed("Compressione di \(inputURL.lastPathComponent): numero di pagine alterato (input \(index + 1)).")
                }
                for pageIndex in 0..<source.pageCount {
                    try Task.checkCancellation()
                    let originalText = Self.searchableText(source.page(at: pageIndex)?.string)
                    let compressedText = Self.searchableText(compressed.page(at: pageIndex)?.string)
                    guard originalText == compressedText else {
                        throw ExecutorError.executionFailed("Compressione di \(inputURL.lastPathComponent): testo alterato a pagina \(pageIndex + 1) (input \(index + 1)).")
                    }
                }
                let originalSize = try inputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                let compressedSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard let originalSize, let compressedSize else {
                    throw ExecutorError.executionFailed("Impossibile verificare la dimensione di \(inputURL.lastPathComponent).")
                }
                try Task.checkCancellation()
                if compressedSize >= originalSize {
                    try FileManager.default.removeItem(at: temporaryURL)
                    outputFiles.removeAll { $0 == temporaryURL }
                    unchangedCount += 1
                } else {
                    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
                    outputFiles.removeAll { $0 == temporaryURL }
                    outputFiles.append(outputURL)
                }
            }
            let noReduction = "Nessuna riduzione ottenuta; originale conservato"
            let message = outputFiles.isEmpty ? noReduction : "Compressi \(outputFiles.count) PDF (livello \(setting))" + (unchangedCount > 0 ? ". \(noReduction) per \(unchangedCount) PDF." : "")
            return ActionResult(success: true, outputFiles: outputFiles, message: message)
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
    }
    
    // MARK: Helpers
    
    private static func pdfSetting(for quality: Int) -> String {
        if quality < 35 { return "screen" }
        if quality <= 70 { return "ebook" }
        return "printer"
    }
    
    private static func arguments(input: URL, output: URL, setting: String) -> [String] {
        ["-sDEVICE=pdfwrite", "-dCompatibilityLevel=1.4", "-dPDFSETTINGS=/\(setting)",
         "-dNOPAUSE", "-dQUIET", "-dBATCH", "-sOutputFile=\(output.path)", input.path]
    }

    private static func searchableText(_ text: String?) -> String {
        (text ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Images To PDF Action

final class ImagesToPDFAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        var outputFiles: [URL] = []
        do {
            let inputs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)
            guard let directory = context.currentDirectory else {
                throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
            }
            let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "combined"
            let baseName = (rawName as NSString).deletingPathExtension
            let outputURL = FileResolver.uniqueURL(in: directory, baseName: baseName, extensionName: "pdf")
            let pdfDocument = PDFDocument()
            var pagesAdded = 0
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, "Generazione pagina \(index + 1)/\(inputs.count): \(inputURL.lastPathComponent)")
                guard let image = NSImage(contentsOf: inputURL), image.isValid,
                      let pdfPage = PDFPage(image: image) else {
                    throw ExecutorError.executionFailed("Immagine non leggibile: \(inputURL.lastPathComponent) (input/pagina \(index + 1)).")
                }
                pdfDocument.insert(pdfPage, at: pdfDocument.pageCount)
                pagesAdded += 1
            }
            try await StagedOutput.write(to: outputURL, journal: &outputFiles) { temporaryURL in
                guard pagesAdded > 0, pdfDocument.write(to: temporaryURL) else {
                    throw ExecutorError.executionFailed("Creazione del PDF dalle immagini fallita.")
                }
            }
            return ActionResult(success: true, outputFiles: outputFiles, message: "Create \(pagesAdded) pagine in \(outputURL.lastPathComponent) a partire da \(inputs.count) immagini")
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
    }
    
}

/// Reject empty, locked, or partially unreadable documents before publishing output.
private func readablePDF(at url: URL, inputIndex: Int) throws -> PDFDocument {
    guard let document = PDFDocument(url: url) else {
        throw ExecutorError.executionFailed("PDF non leggibile: \(url.lastPathComponent) (input \(inputIndex), pagina 1).")
    }
    guard !document.isLocked else {
        throw ExecutorError.executionFailed("PDF bloccato: \(url.lastPathComponent) (input \(inputIndex), pagina 1).")
    }
    guard document.pageCount > 0 else {
        throw ExecutorError.executionFailed("PDF senza pagine leggibili: \(url.lastPathComponent) (input \(inputIndex), pagina 1).")
    }
    for pageIndex in 0..<document.pageCount {
        try Task.checkCancellation()
        guard let page = document.page(at: pageIndex), page.pageRef != nil else {
            throw ExecutorError.executionFailed("Pagina \(pageIndex + 1) non leggibile in \(url.lastPathComponent) (input \(inputIndex)).")
        }
    }
    return document
}
