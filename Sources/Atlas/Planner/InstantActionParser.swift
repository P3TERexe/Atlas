import Foundation

/// Parses simple deterministic keywords locally (0ms) without hitting the AI model.
/// Returns an `ActionGraph` if a deterministic match is found, or `nil` to fall back to the LLM.
struct InstantActionParser {
    
    /// Output formats reachable by typing the format name directly (jpeg → jpg).
    private static let imageFormats: [String: String] = [
        "jpg": "jpg", "jpeg": "jpg", "png": "png", "webp": "webp",
        "heic": "heic", "gif": "gif", "tiff": "tiff"
    ]
    
    private struct Rule {
        let tool: String
        let exts: Set<String>?
        let grayscale: Bool
        let minInputs: Int
        let format: String?
        
        init(tool: String, exts: Set<String>?, grayscale: Bool = false, minInputs: Int = 1, format: String? = nil) {
            self.tool = tool
            self.exts = exts
            self.grayscale = grayscale
            self.minInputs = minInputs
            self.format = format
        }
    }
    
    /// Exact keyword → rule table.
    private static let exactRules: [String: Rule] = [
        // ZIP shorthand: qualifiers are deliberately left to the model.
        "comprimi foto": Rule(tool: "file.zip", exts: MediaFormats.image, format: "archive.zip"),
        "comprimi immagini": Rule(tool: "file.zip", exts: MediaFormats.image, format: "archive.zip"),
        "comprimi le foto": Rule(tool: "file.zip", exts: MediaFormats.image, format: "archive.zip"),
        "comprimi le immagini": Rule(tool: "file.zip", exts: MediaFormats.image, format: "archive.zip"),
        "zip": Rule(tool: "file.zip", exts: nil, format: "archive.zip"),
        "comprimi": Rule(tool: "file.zip", exts: nil, format: "archive.zip"),
        "zip em up": Rule(tool: "file.zip", exts: nil, format: "archive.zip"),
        "zip these": Rule(tool: "file.zip", exts: nil, format: "archive.zip"),
        "comprimi i file": Rule(tool: "file.zip", exts: nil, format: "archive.zip"),
        // Audio extraction
        "mp3": Rule(tool: "video.extractAudio", exts: MediaFormats.video, format: "mp3"),
        "m4a": Rule(tool: "video.extractAudio", exts: MediaFormats.video, format: "m4a"),
        // Video conversion
        "mp4": Rule(tool: "video.convert", exts: MediaFormats.video, format: "mp4"),
        "mov": Rule(tool: "video.convert", exts: MediaFormats.video, format: "mov"),
        // Grayscale / Black & White
        "bw": Rule(tool: "image.convert", exts: MediaFormats.image, grayscale: true),
        "bianco e nero": Rule(tool: "image.convert", exts: MediaFormats.image, grayscale: true),
        "grayscale": Rule(tool: "image.convert", exts: MediaFormats.image, grayscale: true),
        "grigio": Rule(tool: "image.convert", exts: MediaFormats.image, grayscale: true),
        // PDF merge (needs at least 2 files)
        "unisci pdf": Rule(tool: "pdf.merge", exts: MediaFormats.pdf, minInputs: 2),
        "merge pdf": Rule(tool: "pdf.merge", exts: MediaFormats.pdf, minInputs: 2),
        "unisci i pdf": Rule(tool: "pdf.merge", exts: MediaFormats.pdf, minInputs: 2),
        // PDF compress
        "comprimi pdf": Rule(tool: "pdf.compress", exts: MediaFormats.pdf),
        "compress pdf": Rule(tool: "pdf.compress", exts: MediaFormats.pdf),
        "ottimizza pdf": Rule(tool: "pdf.compress", exts: MediaFormats.pdf),
        // Vision OCR Rename
        "ocr": Rule(tool: "image.ocrRename", exts: MediaFormats.image),
        "ocr rename": Rule(tool: "image.ocrRename", exts: MediaFormats.image),
        "rinomina ocr": Rule(tool: "image.ocrRename", exts: MediaFormats.image),
        "rinomina con testo": Rule(tool: "image.ocrRename", exts: MediaFormats.image),
        "rinomina per contenuto": Rule(tool: "image.ocrRename", exts: MediaFormats.image),
        // Images To PDF (Complex pipeline)
        "immagini in pdf": Rule(tool: "pdf.fromImages", exts: MediaFormats.image, format: "combined.pdf"),
        "immagini in unico pdf": Rule(tool: "pdf.fromImages", exts: MediaFormats.image, format: "combined.pdf"),
        "converti immagini in pdf": Rule(tool: "pdf.fromImages", exts: MediaFormats.image, format: "combined.pdf"),
        "unisci immagini in pdf": Rule(tool: "pdf.fromImages", exts: MediaFormats.image, format: "combined.pdf"),
        "foto in pdf": Rule(tool: "pdf.fromImages", exts: MediaFormats.image, format: "combined.pdf"),
        "images to pdf": Rule(tool: "pdf.fromImages", exts: MediaFormats.image, format: "combined.pdf"),
        // File selection shorthands
        "seleziona le foto": Rule(tool: "file.select", exts: MediaFormats.image),
        "seleziona foto": Rule(tool: "file.select", exts: MediaFormats.image),
        "seleziona tutte le foto": Rule(tool: "file.select", exts: MediaFormats.image),
        "seleziona le immagini": Rule(tool: "file.select", exts: MediaFormats.image),
        "seleziona immagini": Rule(tool: "file.select", exts: MediaFormats.image),
        "seleziona tutte le immagini": Rule(tool: "file.select", exts: MediaFormats.image),
        "seleziona i file": Rule(tool: "file.select", exts: nil),
        "seleziona tutti i file": Rule(tool: "file.select", exts: nil),
        "seleziona i pdf": Rule(tool: "file.select", exts: MediaFormats.pdf),
        "seleziona tutti i pdf": Rule(tool: "file.select", exts: MediaFormats.pdf),
        "seleziona i video": Rule(tool: "file.select", exts: MediaFormats.video),
        "seleziona tutti i video": Rule(tool: "file.select", exts: MediaFormats.video),
        "select photos": Rule(tool: "file.select", exts: MediaFormats.image),
        "select all photos": Rule(tool: "file.select", exts: MediaFormats.image),
        "select images": Rule(tool: "file.select", exts: MediaFormats.image),
        "select all images": Rule(tool: "file.select", exts: MediaFormats.image),
    ]
    
    static func parse(query: String, context: FinderContext) -> ActionGraph? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        
        // 1. Image format conversion shorthand: the keyword is the output format
        if let targetFormat = imageFormats[trimmed] {
            return makeGraph(tool: "image.convert", exts: MediaFormats.image, context: context, format: targetFormat)
        }
        
        // 2. Other exact-match shorthands
        if let rule = exactRules[trimmed] {
            return makeGraph(tool: rule.tool, exts: rule.exts, context: context,
                             grayscale: rule.grayscale, minInputs: rule.minInputs, format: rule.format)
        }
        
        return nil
    }
    
    
    private static func makeGraph(tool: String, exts: Set<String>?, context: FinderContext,
                                  grayscale: Bool = false, minInputs: Int = 1, format: String? = nil) -> ActionGraph? {
        let inputFiles = resolveInputs(exts: exts, context: context, selectVisible: tool == "file.select")
        guard inputFiles.count >= minInputs else { return nil }
        
        return ActionGraph(steps: [ActionStep(
            id: "step_1",
            tool: tool,
            inputs: inputFiles,
            format: format,
            grayscale: grayscale
        )])
    }
    
    private static func resolveInputs(exts: Set<String>?, context: FinderContext, selectVisible: Bool) -> [String] {
        let urls = selectVisible || context.selectedFiles.isEmpty ? context.visibleFiles : context.selectedFiles
        let currentDirPath = context.currentDirectory?.standardized.path
        let currentDirResolved = context.currentDirectory?.resolvingSymlinksInPath().standardized.path
        let candidates = urls.map { url -> String in
            let parentPath = url.deletingLastPathComponent().standardized.path
            let parentResolved = url.deletingLastPathComponent().resolvingSymlinksInPath().standardized.path
            if let currentDirPath, parentPath == currentDirPath || parentResolved == currentDirResolved {
                return url.lastPathComponent
            }
            return url.path
        }
        
        guard let exts else { return candidates }
        return candidates.filter { name in
            exts.contains((name as NSString).pathExtension.lowercased())
        }
    }
}
