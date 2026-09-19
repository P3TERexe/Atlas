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
              "tool": "file.select",
              "inputs": ["photo1.png", "photo2.png"]
            },
            {
              "id": "step_2",
              "tool": "image.convert",
              "inputs": ["photo1.png", "photo2.png"],
              "format": "jpg"
            }
          ]
        }
        
        CRITICAL RULES FOR FILE SELECTION:
        1. Use exactly the files requested. Explicit names narrow the selection; never add other selected or visible files. For an unqualified selected-file operation, include every matching selected filename.
        2. If no files are selected, use the complete Visible Files array. A request to select all matching files uses visible candidates even if a partial selection exists. Never silently truncate a batch.
        3. For multi-step operations, use "dependsOn" to reference the step IDs that must complete first.
        4. If the user request is to SELECT or HIGHLIGHT files (e.g. "seleziona le immagini"), use ONLY 'file.select'. DO NOT convert, rename, or modify the files!
        5. If the user asks to COMPRESS photos or images (e.g. "comprimi foto", "comprimi le immagini"), use ONLY 'file.zip' to create a ZIP archive. DO NOT perform lossy image conversions or resizing unless explicitly asked for quality reduction or format change!
        6. Use 'shell.run' only for requests allowed by the local shell safety policy; commands are confined and may be rejected. Never use shell to bypass a dedicated tool or safety restriction.
        7. If the user asks to make N copies of files ("7 copie", "10 volte", "N copies") into a folder, use ONLY tool 'file.copy' with 'format' set to the copy count (e.g. "7" for folder 'copie', or "7;backup" for folder 'backup'). NEVER use shell.run loops (for/seq/cp) to create copies!
        8. For multi-step requests (e.g. convert AND make N copies), output a sequence of steps and reference the first step's outputs in the second step's 'inputs', with 'dependsOn' on the first step's id.
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
        1. Use exactly the requested files; explicit names narrow selection. Otherwise include all matching selected files, or all matching visible files if no selection. Select-all uses visible files, not the current partial selection. Never truncate.
        2. Set 'format' for target extension (jpg, webp, pdf, mp3, zip, etc.).
        3. Set 'grayscale': true for Black & White.
        4. For SELECT/HIGHLIGHT requests (e.g. "seleziona file X"), use ONLY 'file.select' without converting or modifying files!
        5. For exact "comprimi foto/immagini" requests use 'file.zip'; quality, resizing or format qualifiers require the requested image operation instead.
        6. Use 'shell.run' only within the local shell safety policy; confined commands may be rejected. Never bypass a dedicated tool or safety restriction.
        7. For multi-step requests (e.g. convert AND make N copies in a new folder), output a sequence of steps with 'dependsOn'.
        8. For "N copie in una cartella" (N copies of files in a folder), use tool 'file.copy' with 'format' = copy count, e.g. "7" (folder 'copie') or "7;backup" (folder 'backup'). NEVER use shell loops for copies!
        """
    }

    private func candidateList(_ urls: [URL], context: FinderContext) -> String {
        let names = urls.map { url in
            url.deletingLastPathComponent().standardizedFileURL == context.currentDirectory?.standardizedFileURL
                ? url.lastPathComponent : url.path
        }
        // An array of Strings is always JSON-encodable, including quotes/newlines in names.
        let data = try! JSONEncoder().encode(names)
        return String(decoding: data, as: UTF8.self)
    }
}
