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
        "seleziona le immagini": Rule(tool: "file.select", exts: MediaFormats.image),
        "seleziona immagini": Rule(tool: "file.select", exts: MediaFormats.image),
        "select photos": Rule(tool: "file.select", exts: MediaFormats.image),
        "select images": Rule(tool: "file.select", exts: MediaFormats.image),
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
        
        // 3. ZIP archive shorthand (including photo/compress prefixes)
        if isCompressRequest(trimmed) {
            return makeGraph(tool: "file.zip", exts: nil, context: context, format: "archive.zip")
        }
        
        return nil
    }
    
    private static func isCompressRequest(_ trimmed: String) -> Bool {
        trimmed == "zip" || trimmed == "comprimi" || trimmed == "zip em up" || trimmed == "zip these"
            || trimmed.hasPrefix("comprimi foto") || trimmed.hasPrefix("comprimi immagini")
            || trimmed.hasPrefix("comprimi le foto") || trimmed.hasPrefix("comprimi le immagini")
            || trimmed.hasPrefix("comprimi i file")
    }
    
    private static func makeGraph(tool: String, exts: Set<String>?, context: FinderContext,
                                  grayscale: Bool = false, minInputs: Int = 1, format: String? = nil) -> ActionGraph? {
        let inputFiles = resolveInputs(exts: exts, context: context)
        guard inputFiles.count >= minInputs else { return nil }
        
        return ActionGraph(steps: [ActionStep(
            id: "step_1",
            tool: tool,
            inputs: inputFiles,
            format: format,
            grayscale: grayscale
        )])
    }
    
    private static func resolveInputs(exts: Set<String>?, context: FinderContext) -> [String] {
        let selectedNames = context.selectedFiles.map { $0.lastPathComponent }
        let candidates = selectedNames.isEmpty ? context.visibleFiles.map { $0.lastPathComponent } : selectedNames
        
        guard let exts else { return candidates }
        return candidates.filter { name in
            exts.contains((name as NSString).pathExtension.lowercased())
        }
    }
}
