import Foundation

enum PlanValidationError: Error, LocalizedError {
    case emptyPlan
    case toolNotFound(String)
    case formatMismatch(expected: String, found: String?)
    case grayscaleMissing
    case noMatchingFiles(tool: String, expectedType: String)
    case intentMismatch(String)

    var errorDescription: String? {
        switch self {
        case .emptyPlan:
            return "L'AI ha generato un piano vuoto (0 step)."
        case .toolNotFound(let tool):
            return "Il piano generato richiede un tool non esistente: '\(tool)'."
        case .formatMismatch(let expected, let found):
            return "Richiesta per formato '\(expected)', ma l'AI ha impostato '\(found ?? "nessuno")'."
        case .grayscaleMissing:
            return "Richiesta conversione in Bianco e Nero, ma il flag 'grayscale' non è stato impostato."
        case .noMatchingFiles(let tool, let expectedType):
            return "Il comando '\(tool)' richiede file \(expectedType), ma non ne sono stati trovati nel contesto."
        case .intentMismatch(let reason):
            return "Verifica piano fallita: \(reason)"
        }
    }
}

struct PlanValidator {
    
    /// Validates that the generated ActionGraph matches the user's intent and context.
    @MainActor
    static func validate(graph: ActionGraph, query: String, context: FinderContext) throws {
        guard !graph.steps.isEmpty else {
            throw PlanValidationError.emptyPlan
        }
        
        let lowerQuery = query.lowercased()
        
        // 1. Validate that all tools exist
        for step in graph.steps {
            guard ToolRegistry.shared.capability(for: step.tool) != nil else {
                throw PlanValidationError.toolNotFound(step.tool)
            }
        }
        
        // 2. Pure selection guardrail: if user ONLY asked to select/highlight files, enforce file.select ONLY
        let selectionVerbs = ["seleziona", "select", "evidenzia", "mostra nel finder", "highlight"]
        let modificationVerbs = ["converti", "trasforma", "ridimensiona", "comprimi", "unisci", "rinomina", "estrai", "modifica", "cambia"]
        
        let isSelectionRequest = selectionVerbs.contains { lowerQuery.contains($0) }
        let hasModificationRequest = modificationVerbs.contains { lowerQuery.contains($0) }
        
        if isSelectionRequest && !hasModificationRequest {
            let invalidTools = graph.steps.filter { $0.tool != "file.select" }
            if !invalidTools.isEmpty {
                throw PlanValidationError.intentMismatch("L'utente ha chiesto solo di SELEZIONARE file. Usa esclusivamente 'file.select' senza convertire o modificare i file.")
            }
            // Pure selection validated successfully — skip format checks
            return
        }
        
        // 2b. Photo/Image Compression Guardrail: "comprimi foto/immagini" MUST produce ZIP unless quality/resampling is requested
        let isPhotoCompressQuery = lowerQuery.contains("comprimi") && (lowerQuery.contains("foto") || lowerQuery.contains("immagini"))
        let hasQualityOrFormatRequest = ["qualità", "qualita", "ridimensiona", "resize", "risoluzione", "webp", "jpg", "png", "heic"].contains { lowerQuery.contains($0) }
        
        if isPhotoCompressQuery && !hasQualityOrFormatRequest {
            let hasZipTool = graph.steps.contains { $0.tool == "file.zip" || $0.tool == "file.compress" }
            if !hasZipTool {
                throw PlanValidationError.intentMismatch("La richiesta di compressione foto senza indicazione di qualità/formato deve creare un archivio ZIP. Usa 'file.zip' e non convertire o ridimensionare le immagini.")
            }
        }
        
        // 3. Validate format intent (e.g. "webp", "jpg", "png", "mp3", "pdf", "zip") for conversion/modification tasks
        let formatKeywords = ["webp", "jpg", "jpeg", "png", "heic", "tiff", "gif", "mp3", "m4a", "pdf", "zip"]
        for kw in formatKeywords {
            if lowerQuery.contains(kw) {
                let foundMatch = graph.steps.contains { step in
                    if let f = step.format?.lowercased() {
                        if kw == "jpeg" && (f == "jpg" || f == "jpeg") { return true }
                        if kw == "jpg" && (f == "jpg" || f == "jpeg") { return true }
                        return f == kw
                    }
                    if kw == "pdf" && step.tool.hasPrefix("pdf") { return true }
                    if kw == "zip" && step.tool.hasPrefix("file") { return true }
                    return false
                }
                if !foundMatch {
                    let actualFormat = graph.steps.compactMap { $0.format }.first
                    throw PlanValidationError.formatMismatch(expected: kw, found: actualFormat)
                }
            }
        }
        
        // 4. Validate grayscale / B&W intent
        if lowerQuery.contains("bianco e nero") || lowerQuery.contains("b&w") || lowerQuery.contains("grayscale") || lowerQuery.contains("grigio") {
            let hasGrayscale = graph.steps.contains { $0.grayscale == true }
            if !hasGrayscale {
                throw PlanValidationError.grayscaleMissing
            }
        }
        
        // 5. Validate input files availability for target tool
        for step in graph.steps {
            if step.tool == "image.convert" {
                let hasImages = hasMatchingFiles(in: context, exts: MediaFormats.image, stepInputs: step.inputs)
                if !hasImages {
                    throw PlanValidationError.noMatchingFiles(tool: step.tool, expectedType: "immagine (png, jpg, webp, heic...)")
                }
            } else if step.tool.hasPrefix("pdf.") {
                let hasPDFs = hasMatchingFiles(in: context, exts: MediaFormats.pdf, stepInputs: step.inputs)
                if !hasPDFs {
                    throw PlanValidationError.noMatchingFiles(tool: step.tool, expectedType: "PDF")
                }
            } else if step.tool.hasPrefix("video.") {
                let hasVideos = hasMatchingFiles(in: context, exts: MediaFormats.video, stepInputs: step.inputs)
                if !hasVideos {
                    throw PlanValidationError.noMatchingFiles(tool: step.tool, expectedType: "video (mp4, mov...)")
                }
            }
        }
    }
    
    private static func hasMatchingFiles(in context: FinderContext, exts: Set<String>, stepInputs: [String]) -> Bool {
        if !stepInputs.isEmpty {
            for input in stepInputs {
                let ext = (input as NSString).pathExtension.lowercased()
                if exts.contains(ext) { return true }
            }
        }
        for url in context.selectedFiles {
            if exts.contains(url.pathExtension.lowercased()) { return true }
        }
        for url in context.visibleFiles {
            if exts.contains(url.pathExtension.lowercased()) { return true }
        }
        return false
    }
}
