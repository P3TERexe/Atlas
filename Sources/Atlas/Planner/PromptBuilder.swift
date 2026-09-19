import Foundation

@MainActor
class PromptBuilder {
    func buildPrompt(query: String, context: FinderContext) -> String {
        let tools = ToolRegistry.shared.allCapabilities().map {
            "- \($0.id): \($0.description) (Inputs: \($0.inputFormats.joined(separator: ", ")), Outputs: \($0.outputFormats.joined(separator: ", ")))"
        }.joined(separator: "\n")
        
        let files = candidateList(context.selectedFiles, context: context)
        let visibleInfo = candidateList(context.visibleFiles, context: context)
        
        let activeRules = RulesStore.shared.activeRules(for: query, currentFolder: context.currentDirectory?.path)
        let rulesBlock = activeRules.isEmpty ? "" : """
        
        USER PREFERENCE RULES (ENFORCE THESE SETTINGS):
        \(activeRules.map { "- When trigger '\($0.trigger)': \($0.instruction)" }.joined(separator: "\n"))
        """
        
        let prompt = """
        You are a filesystem assistant. Translate the user's request into a structured action plan.
        
        AVAILABLE TOOLS:
        \(tools)
        \(rulesBlock)
        
        CURRENT CONTEXT:
        Current Directory: \(context.currentDirectory?.path ?? "Unknown")
        
        Selected Files (count: \(context.selectedFiles.count)):
        \(files)
        
        Visible Files (count: \(context.visibleFiles.count)):
        \(visibleInfo)
        
        Installed CLI tools: \(context.installedTools.joined(separator: ", "))
        
        USER REQUEST:
        "\(query)"
        
        Produce a raw JSON object with a top-level "steps" array. Example:
        {
          "steps": [
            {
              "id": "step_1",
              "tool": "file.mkdir",
              "inputs": [],
              "format": "Cartella"
            },
            {
              "id": "step_2",
              "tool": "image.convert",
              "inputs": [],
              "grayscale": true,
              "dependsOn": ["step_1"]
            },
            {
              "id": "step_3",
              "tool": "file.move",
              "inputs": [],
              "format": "Cartella",
              "dependsOn": ["step_2"]
            }
          ]
        }
        
        CRITICAL RULES FOR FILE SELECTION & EFFICIENCY:
        1. When operating on all files of a type in the current folder (e.g. "tutte le foto", "tutte le immagini", "all files", "converti le foto in bianco e nero"), ALWAYS set 'inputs': [] (empty array)! The execution engine automatically resolves all matching files in the directory. DO NOT manually enumerate every filename in 'inputs' when the user says "tutte", "all", or when no specific filenames were given.
        2. Only specify individual filenames in 'inputs' if the user explicitly named specific files (e.g. "foto1.jpg e foto2.png").
        3. To create a new folder/directory, use tool 'file.mkdir' with 'format' set to the folder name (e.g. "caccona galattica").
        4. To move files into a folder, use tool 'file.move' with 'format' set to the destination folder name and 'dependsOn' referencing previous steps (e.g. conversion step).
        5. Set 'grayscale': true for Black & White / Grayscale image conversion.
        6. For multi-step operations, use "dependsOn" to reference the step IDs that must complete first.
        7. If the user request is to SELECT or HIGHLIGHT files (e.g. "seleziona le immagini"), use ONLY 'file.select'. DO NOT convert, rename, or modify the files!
        8. If the user asks to COMPRESS photos or images (e.g. "comprimi foto", "comprimi le immagini"), use ONLY 'file.zip' to create a ZIP archive. DO NOT perform lossy image conversions or resizing unless explicitly asked for quality reduction or format change!
        9. NEVER use shell.run for creating directories (use 'file.mkdir') or copying/moving files (use 'file.copy' or 'file.move').
        """
        
        return prompt
    }
    
    /// Compact prompt variant optimized for small context windows (Apple Intelligence, 3B local LLMs)
    func buildCompactPrompt(query: String, context: FinderContext) -> String {
        let tools = ToolRegistry.shared.allCapabilities().map {
            "- \($0.id): \($0.description)"
        }.joined(separator: "\n")
        
        let files = candidateList(context.selectedFiles, context: context)
        let visible = candidateList(context.visibleFiles, context: context)
        
        let folderName = context.currentDirectory?.lastPathComponent ?? "Current Directory"
        
        return """
        TOOLS:
        \(tools)
        
        CONTEXT:
        Folder: \(folderName)
        Selected Files (count: \(context.selectedFiles.count)): \(files)
        Visible Files (count: \(context.visibleFiles.count)): \(visible)
        
        USER REQUEST:
        "\(query)"
        
        RULES:
        1. For batch requests on all matching files (e.g. "tutte le foto", "tutti i file", "all images"), use 'inputs': [] (empty array)! The engine will automatically match files. Only write specific filenames if explicitly requested by name.
        2. To create a directory, use 'file.mkdir' with 'format' = directory name.
        3. To move files into a directory, use 'file.move' with 'format' = directory name and 'dependsOn' for predecessor steps.
        4. Set 'format' for target extension (jpg, webp, pdf, mp3, zip, etc.).
        5. Set 'grayscale': true for Black & White.
        6. For SELECT/HIGHLIGHT requests (e.g. "seleziona file X"), use ONLY 'file.select' without converting or modifying files!
        7. For exact "comprimi foto/immagini" requests use 'file.zip'; quality, resizing or format qualifiers require the requested image operation instead.
        8. For multi-step requests, output a sequence of steps with 'dependsOn'.
        
        Output ONLY a JSON object: {"steps": [{"id": "step_1", "tool": "...", "inputs": []}]}
        """
    }

    private func candidateList(_ urls: [URL], context: FinderContext) -> String {
        let limited = urls.prefix(40)
        let names = limited.map { url in
            url.deletingLastPathComponent().standardizedFileURL == context.currentDirectory?.standardizedFileURL
                ? url.lastPathComponent : url.path
        }
        let data = try! JSONEncoder().encode(names)
        return String(decoding: data, as: UTF8.self)
    }
}
