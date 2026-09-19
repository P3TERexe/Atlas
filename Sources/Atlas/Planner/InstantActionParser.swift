import Foundation

/// Parses simple deterministic keywords locally (0ms) without hitting the AI model.
/// Returns an `ActionGraph` if a deterministic match is found, or `nil` to fall back to the LLM.
struct InstantActionParser {
    
    /// Output formats reachable by typing the format name directly (jpeg → jpg).
    private static let imageFormats: [String: String] = [
        "jpg": "jpg", "jpeg": "jpg", "png": "png", "webp": "webp",
        "heic": "heic", "gif": "gif", "tiff": "tiff"
    ]
    
    static func parse(query: String, context: FinderContext) -> ActionGraph? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        
        // Single file extension shorthand (e.g. typing "webp" or "jpg" directly)
        if let targetFormat = imageFormats[lower] {
            return makeGraph(tool: "image.convert", exts: MediaFormats.image, context: context, format: targetFormat)
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

