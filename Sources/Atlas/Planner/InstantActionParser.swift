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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        
        // 1. Image format conversion shorthand: the keyword is the output format
        if let targetFormat = imageFormats[lower] {
            return makeGraph(tool: "image.convert", exts: MediaFormats.image, context: context, format: targetFormat)
        }
        
        // 2. Other exact-match shorthands
        if let rule = exactRules[lower] {
            return makeGraph(tool: rule.tool, exts: rule.exts, context: context,
                             grayscale: rule.grayscale, minInputs: rule.minInputs, format: rule.format)
        }
        
        // 3. Natural Language Shorthands (0ms local resolution)
        if let graph = parseNaturalLanguage(raw: trimmed, lower: lower, context: context) {
            return graph
        }
        
        return nil
    }

    private static func parseNaturalLanguage(raw: String, lower: String, context: FinderContext) -> ActionGraph? {
        // A. Composite: Create folder + Black & White / conversion into folder
        // e.g. "fai una cartella e aggiungi una versione in bianco e nero di tutte le foto la cartella deve chiamarsi caccona galattica"
        if (lower.contains("cartella") || lower.contains("folder")) &&
           (lower.contains("bianco e nero") || lower.contains("grayscale") || lower.contains("bw")) {
            if let folderName = extractFolderName(from: raw) {
                return ActionGraph(steps: [
                    ActionStep(id: "step_1", tool: "file.mkdir", format: folderName),
                    ActionStep(id: "step_2", tool: "image.convert", inputs: [], grayscale: true, dependsOn: ["step_1"]),
                    ActionStep(id: "step_3", tool: "file.move", inputs: [], format: folderName, dependsOn: ["step_2"])
                ])
            }
        }

        // B. Make Directory (file.mkdir)
        // e.g. "crea cartella Progetti", "fai una cartella caccona galattica", "nuova cartella Temp", "mkdir Test"
        if let folderName = matchMakeDirectory(raw: raw) {
            return ActionGraph(steps: [
                ActionStep(id: "step_1", tool: "file.mkdir", format: folderName)
            ])
        }

        // C. Move files into folder (file.move)
        // e.g. "sposta le foto in Cartella", "sposta i file nella cartella Backup", "move files to Archive"
        if let folderName = matchMoveFiles(raw: raw) {
            let inputFiles = resolveInputs(exts: nil, context: context, selectVisible: false)
            return ActionGraph(steps: [
                ActionStep(id: "step_1", tool: "file.move", inputs: inputFiles, format: folderName)
            ])
        }

        // D. Image conversion: "converti le immagini in jpg", "converti le foto in png", "in webp", "trasforma in jpg"
        if let format = matchImageConvertFormat(lower: lower) {
            return makeGraph(tool: "image.convert", exts: MediaFormats.image, context: context, format: format)
        }

        // E. Black & White / Grayscale: "converti in bianco e nero", "foto in bianco e nero", "metti le foto in bianco e nero"
        if matchGrayscale(lower: lower) {
            return makeGraph(tool: "image.convert", exts: MediaFormats.image, context: context, grayscale: true)
        }

        // F. Audio extraction: "estrai audio", "estrai l'audio", "converti in mp3"
        if lower.contains("estrai audio") || lower.contains("estrai l'audio") || lower.contains("extract audio") ||
           lower == "converti in mp3" || lower == "in mp3" {
            return makeGraph(tool: "video.extractAudio", exts: MediaFormats.video, context: context, format: "mp3")
        }

        // G. Video conversion: "converti in mp4", "converti i video in mp4", "video in mp4"
        if lower.contains("in mp4") && (lower.contains("video") || lower.contains("converti") || lower.contains("trasforma")) {
            return makeGraph(tool: "video.convert", exts: MediaFormats.video, context: context, format: "mp4")
        }

        // H. PDF operations: "unisci tutti i pdf", "combina i pdf"
        if lower.contains("unisci") && lower.contains("pdf") || lower.contains("combina") && lower.contains("pdf") {
            return makeGraph(tool: "pdf.merge", exts: MediaFormats.pdf, context: context, minInputs: 2)
        }
        if (lower.contains("comprimi") || lower.contains("ottimizza")) && lower.contains("pdf") {
            return makeGraph(tool: "pdf.compress", exts: MediaFormats.pdf, context: context)
        }

        // I. Zip compression: "comprimi tutto", "comprimi tutti i file"
        if lower == "comprimi tutto" || lower == "comprimi tutti i file" || lower == "zip all" || lower == "zip tutto" {
            return makeGraph(tool: "file.zip", exts: nil, context: context, format: "archive.zip")
        }

        return nil
    }

    private static func matchImageConvertFormat(lower: String) -> String? {
        let pattern = #"^(?:converti|trasforma|porta|esporta|cambia)?\s*(?:tutte\s+)?(?:le\s+|i\s+)?(?:immagini|foto|file)?\s*(?:in|to)\s+([a-zA-Z0-9]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(lower.startIndex..., in: lower)
        guard let match = regex.firstMatch(in: lower, range: range), match.numberOfRanges > 1 else { return nil }
        guard let formatRange = Range(match.range(at: 1), in: lower) else { return nil }
        let rawFormat = String(lower[formatRange]).lowercased()
        return imageFormats[rawFormat]
    }

    private static func matchGrayscale(lower: String) -> Bool {
        let pattern = #"(?:converti|trasforma|metti|rendi|fai|passa)?\s*(?:tutte\s+)?(?:le\s+|i\s+)?(?:immagini|foto|file)?\s*(?:in\s+)?(?:bianco\s+e\s+nero|scala\s+di\s+grigi|black\s+and\s+white|grayscale)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        let range = NSRange(lower.startIndex..., in: lower)
        return regex.firstMatch(in: lower, range: range) != nil
    }

    private static func matchMakeDirectory(raw: String) -> String? {
        let pattern = #"^(?:crea|fai|nuova|genera|mkdir|create|make|new)\s*(?:una\s+|la\s+|a\s+)?(?:cartella|folder|directory)\s*(?:chiamata\s+|con\s+nome\s+|di\s+nome\s+|named\s+|called\s+)?["']?([^"']+)["']?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges > 1 else { return nil }
        guard let nameRange = Range(match.range(at: 1), in: raw) else { return nil }
        let name = String(raw[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidFolderName(name) ? name : nil
    }

    private static func matchMoveFiles(raw: String) -> String? {
        let pattern = #"^(?:sposta|muovi|move)\s*(?:tutti\s+)?(?:i\s+|le\s+)?(?:file|foto|immagini|documenti|pdf)?\s*(?:dentro|nella\s+cartella|in\s+cartella|in|into|to)\s+["']?([^"']+)["']?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges > 1 else { return nil }
        guard let nameRange = Range(match.range(at: 1), in: raw) else { return nil }
        let name = String(raw[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidFolderName(name) ? name : nil
    }

    private static func extractFolderName(from query: String) -> String? {
        // Look for "chiamarsi X", "chiamata X", "cartella X", etc.
        let patterns = [
            #"(?:chiamarsi|chiamata|con\s+nome|di\s+nome|named|called)\s+["']?([^"'\n]+?)["']?(?:\s+nella|\s+in|$)"#,
            #"(?:cartella|folder)\s+["']?([^"'\n]+?)["']?(?:\s+e|\s+con|$)"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(query.startIndex..., in: query)
                if let match = regex.firstMatch(in: query, range: range), match.numberOfRanges > 1,
                   let nameRange = Range(match.range(at: 1), in: query) {
                    let candidate = String(query[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isValidFolderName(candidate) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private static func isValidFolderName(_ name: String) -> Bool {
        return !name.isEmpty && !name.contains("/") && name.count < 100
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

