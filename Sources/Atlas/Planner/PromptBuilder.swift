import Foundation

@MainActor
class PromptBuilder {
    func buildPrompt(query: String, context: FinderContext) -> String {
        let tools = ToolRegistry.shared.allCapabilities().map {
            "- \($0.id): \($0.description) (Inputs: \($0.inputFormats.joined(separator: ", ")), Outputs: \($0.outputFormats.joined(separator: ", ")))"
        }.joined(separator: "\n")
        
        let files = context.selectedFiles.isEmpty ?
            "No files selected" :
            context.selectedFiles.map { "- \($0.lastPathComponent)" }.joined(separator: "\n")
        
        let visibleInfo: String
        if context.visibleFiles.isEmpty {
            visibleInfo = "No visible files information"
        } else {
            visibleInfo = context.visibleFiles.prefix(20).map { "- \($0.lastPathComponent)" }.joined(separator: "\n")
        }
        
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
        
        Selected Files:
        \(files)
        
        Visible Files:
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
        1. If multiple files are listed in "Selected Files:", you MUST include ALL selected file names in the "inputs" array of the step: ["file1.png", "file2.png", "file3.png"]. NEVER list only one file if multiple files are selected!
        2. If no files are selected in "Selected Files:", list the target file names from "Visible Files:" or use an empty array [] to operate on all matching files in the folder.
        3. For multi-step operations, use "dependsOn" to reference the step IDs that must complete first.
        4. If the user request is to SELECT or HIGHLIGHT files (e.g. "seleziona le immagini"), use ONLY 'file.select'. DO NOT convert, rename, or modify the files!
        5. If the user asks to COMPRESS photos or images (e.g. "comprimi foto", "comprimi le immagini"), use ONLY 'file.zip' to create a ZIP archive. DO NOT perform lossy image conversions or resizing unless explicitly asked for quality reduction or format change!
        6. FOR ANY CUSTOM REQUEST that does not fit a dedicated tool (e.g. creating directories, searching text, downloading via curl, counting lines/words, running custom scripts), use tool 'shell.run' and put the exact zsh command line in 'format'.
        """
        
        return prompt
    }
    
    /// Compact prompt variant optimized for small context windows (Apple Intelligence, 3B local LLMs)
    func buildCompactPrompt(query: String, context: FinderContext) -> String {
        let tools = ToolRegistry.shared.allCapabilities().map {
            "- \($0.id): \($0.description)"
        }.joined(separator: "\n")
        
        let files: String
        if context.selectedFiles.isEmpty {
            files = "None"
        } else {
            files = context.selectedFiles.prefix(10).map { $0.lastPathComponent }.joined(separator: ", ")
        }
        
        let visible: String
        if context.visibleFiles.isEmpty {
            visible = "None"
        } else {
            visible = context.visibleFiles.prefix(8).map { $0.lastPathComponent }.joined(separator: ", ")
        }
        
        let folderName = context.currentDirectory?.lastPathComponent ?? "Current Directory"
        
        return """
        TOOLS:
        \(tools)
        
        CONTEXT:
        Folder: \(folderName)
        Selected Files: \(files)
        Visible Files: \(visible)
        
        USER REQUEST:
        "\(query)"
        
        RULES:
        1. If files are selected, include ALL selected filenames in 'inputs'.
        2. Set 'format' for target extension (jpg, webp, pdf, mp3, zip, etc.). Automatically fix typos in format (e.g. 'jepeg' -> 'jpg').
        3. Set 'grayscale': true for Black & White.
        4. For SELECT/HIGHLIGHT requests (e.g. "seleziona file X"), use ONLY 'file.select' without converting or modifying files!
        5. For "comprimi foto/immagini" (compress photos), use ONLY 'file.zip'!
        6. For ANY custom/generic request without a specific tool, use tool 'shell.run' and set 'format' to the zsh command line.
        7. For multi-step requests (e.g. convert AND make N copies in a new directory), output a sequence of steps with 'dependsOn'. For zsh shell copy loops, use: mkdir -p copie && for i in $(seq 1 N); do cp "input.jpg" "copie/copia_$i.jpg"; done.
        """
    }
}
