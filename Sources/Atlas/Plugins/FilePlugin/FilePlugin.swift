import Foundation
import AppKit

// MARK: - Plugin

class FilePlugin: AtlasPlugin {
    let id = "file"
    
    var capabilities: [ToolCapability] {
        [
            ToolCapability(
                id: "file.rename",
                description: "Batch-renames files using a template containing '#' as the sequence number placeholder, e.g. 'vacanza_#.jpg' or 'IMG_#'. If the template has no extension, the original one is kept.",
                inputFormats: [],
                outputFormats: [],
                executor: RenameFilesAction()
            ),
            ToolCapability(
                id: "file.zip",
                description: "Compresses multiple files or directories into a single ZIP archive. Set 'format' to the archive name (default: 'archive.zip').",
                inputFormats: [],
                outputFormats: ["zip"],
                executor: ZipFilesAction()
            ),
            ToolCapability(
                id: "file.compress",
                description: "Compresses each file or directory into its own ZIP archive named '<name>.zip'.",
                inputFormats: [],
                outputFormats: ["zip"],
                executor: CompressFilesAction()
            ),
            ToolCapability(
                id: "file.select",
                description: "Selects and highlights target file(s) or files matching a format/extension in the frontmost Finder window. Set 'inputs' to file names or 'format' to extension (e.g. 'jpg').",
                inputFormats: [],
                outputFormats: [],
                executor: SelectFilesAction()
            ),
            ToolCapability(
                id: "file.trash",
                description: "Safely moves file(s) or directory(ies) to the macOS Trash Bin (recoverable via Cestino). Set 'inputs' to target file names.",
                inputFormats: [],
                outputFormats: [],
                executor: TrashFilesAction()
            ),
            ToolCapability(
                id: "file.copy",
                description: "Creates N identical copies of the given file(s) inside a destination folder (default 'copie'). Set 'format' to the copy count (e.g. '7') or 'N;folderName' (e.g. '7;backup') to choose the folder.",
                inputFormats: [],
                outputFormats: [],
                executor: CopyFilesAction()
            ),
        ]
    }
}

// MARK: - Shared input resolution

enum FileResolver {
    static func resolveInputURLs(step: ActionStep, context: FinderContext, isDirectoryOnly: Bool = false, allowDirectories: Bool = false) -> [URL] {
        guard let currentDirectory = context.currentDirectory else { return [] }
        
        let matchingSelected = context.selectedFiles.filter { url in
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists else { return false }
            if isDirectoryOnly { return isDir.boolValue }
            return allowDirectories ? true : !isDir.boolValue
        }
        
        if !matchingSelected.isEmpty {
            let selectedNames = Set(matchingSelected.map { $0.lastPathComponent })
            let stepInputNames = Set(step.inputs)
            if step.inputs.isEmpty || !stepInputNames.isDisjoint(with: selectedNames) {
                return matchingSelected
            }
        }
        
        let files: [URL]
        if !step.inputs.isEmpty {
            files = step.inputs.compactMap { inputPath in
                let url = currentDirectory.appendingPathComponent(inputPath)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } else {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return []
            }
            files = contents
        }
        
        var isDir: ObjCBool = false
        return files.filter { url in
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDirectoryOnly { return isDir.boolValue }
            return allowDirectories ? true : !isDir.boolValue
        }
    }
    
    static func validateNonEmpty(step: ActionStep, context: FinderContext, allowDirectories: Bool = false) throws {
        guard !resolveInputURLs(step: step, context: context, allowDirectories: allowDirectories).isEmpty else {
            throw ExecutorError.validationFailed("Nessun elemento trovato nella cartella o tra gli elementi selezionati.")
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

// MARK: - Batch Rename

final class RenameFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try FileResolver.validateNonEmpty(step: step, context: context)
        
        guard let template = step.format?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty else {
            throw ExecutorError.validationFailed("Specifica un template con '#' come segnaposto del numero, es. 'vacanza_#.jpg'.")
        }
        guard template.contains("#") else {
            throw ExecutorError.validationFailed("Il template deve contenere '#' come segnaposto del numero, es. 'vacanza_#.jpg'.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let files = FileResolver.resolveInputURLs(step: step, context: context)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard let rawTemplate = step.format?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTemplate.isEmpty else {
            throw ExecutorError.validationFailed("Specifica un template con '#' come segnaposto del numero, es. 'vacanza_#.jpg'.")
        }
        let template = rawTemplate
        
        var templateExt: String?
        var templateBase = template
        if let dotIndex = template.lastIndex(of: "."), dotIndex > template.startIndex {
            templateBase = String(template[..<dotIndex])
            templateExt = String(template[template.index(after: dotIndex)...])
        }
        
        var renamedFiles: [URL] = []
        var backupURLs: [URL: URL] = [:]
        
        let backupDir = try BackupStore.newBackupDirectory()
        
        for (index, file) in files.enumerated() {
            let numberString = String(index + 1)
            let newBaseName = templateBase.replacingOccurrences(of: "#", with: numberString)
            let ext = templateExt ?? file.pathExtension
            
            let newFileName = ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"
            let targetURL = directory.appendingPathComponent(newFileName)
            
            // 1. Back up the SOURCE keyed by its original path so the rollback
            //    restores it (rename-undo = recreate source; the moved file is
            //    tracked as a created output and deleted by the rollback).
            let backupURL = backupDir.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: backupURL)
            if file.path != targetURL.path {
                backupURLs[file] = backupURL
            }
            
            // 2. If an existing file would be overwritten, back THAT up too:
            //    after rollback deletes the renamed output, the original target
            //    is restored from this backup (no data loss).
            if file.path != targetURL.path, FileManager.default.fileExists(atPath: targetURL.path) {
                let targetBackup = backupDir.appendingPathComponent("overwritten_" + targetURL.lastPathComponent)
                try FileManager.default.copyItem(at: targetURL, to: targetBackup)
                backupURLs[targetURL] = targetBackup
                try FileManager.default.removeItem(at: targetURL)
            }
            
            if file.path != targetURL.path {
                try FileManager.default.moveItem(at: file, to: targetURL)
            }
            renamedFiles.append(targetURL)
        }
        
        return ActionResult(
            success: true,
            outputFiles: renamedFiles,
            message: "Rinominati \(renamedFiles.count) file con il template '\(template)'",
            backupURLs: backupURLs
        )
    }
}

// MARK: - Zip (single archive)

final class ZipFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try FileResolver.validateNonEmpty(step: step, context: context, allowDirectories: true)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let files = FileResolver.resolveInputURLs(step: step, context: context, allowDirectories: true)
        guard let directory = context.currentDirectory, !files.isEmpty else { return nil }
        let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".zip", with: "") ?? "archive"
        let archiveURL = FileResolver.uniqueURL(in: directory, baseName: rawName, extensionName: "zip")
        // La stringa è solo anteprima, ma deve restare un comando zsh valido:
        // spazi/apici/metacaratteri nei nomi file vanno quotati.
        let quotedFiles = files.map { Self.shellQuote($0.lastPathComponent) }.joined(separator: " ")
        return ["cd \(Self.shellQuote(directory.path)) && zip -r \(Self.shellQuote(archiveURL.lastPathComponent)) \(quotedFiles)"]
    }

    /// Quoting per shell POSIX: singoli apici con escape del carattere '.
    /// Visibile per il testing (internal).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let files = FileResolver.resolveInputURLs(step: step, context: context, allowDirectories: true)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard !files.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun elemento da comprimere.")
        }
        
        let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".zip", with: "") ?? "archive"
        let archiveURL = FileResolver.uniqueURL(in: directory, baseName: rawName, extensionName: "zip")
        let relativePaths = files.map { $0.lastPathComponent }
        
        let result = try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-r", archiveURL.path] + relativePaths,
            currentDirectoryURL: directory
        )
        
        guard result.isSuccess, FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ExecutorError.executionFailed("Creazione dell'archivio ZIP fallita: \(result.stderr)")
        }
        
        return ActionResult(
            success: true,
            outputFiles: [archiveURL],
            message: "Creato \(archiveURL.lastPathComponent) con \(files.count) elementi"
        )
    }
}

// MARK: - Compress (per-item archives)

final class CompressFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try FileResolver.validateNonEmpty(step: step, context: context, allowDirectories: true)
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let files = FileResolver.resolveInputURLs(step: step, context: context, allowDirectories: true)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard !files.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun elemento da comprimere.")
        }
        
        var outputFiles: [URL] = []
        
        for file in files {
            let baseName = file.deletingPathExtension().lastPathComponent
            let archiveURL = FileResolver.uniqueURL(in: directory, baseName: baseName, extensionName: "zip")
            let fileRelPath = file.lastPathComponent
            
            let result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
                arguments: ["-r", "-q", archiveURL.path, fileRelPath],
                currentDirectoryURL: directory
            )
            
            guard result.isSuccess, FileManager.default.fileExists(atPath: archiveURL.path) else {
                throw ExecutorError.executionFailed("Compressione fallita per \(file.lastPathComponent): \(result.stderr)")
            }
            outputFiles.append(archiveURL)
        }
        
        return ActionResult(
            success: true,
            outputFiles: outputFiles,
            message: "Creati \(outputFiles.count) archivi ZIP"
        )
    }
}

// MARK: - Select Files in Finder

/// Seleziona file nel Finder in modo sicuro anche con liste molto grandi
/// (migliaia di elementi): l'API `activateFileViewerSelecting` va in crash
/// quando l'array di URL è enorme, quindi per le liste grandi si usa
/// AppleScript (comando `select`), che regge migliaia di voci.
enum FinderSelector {
    /// Soglia oltre la quale si usa AppleScript invece dell'API nativa.
    private static let scriptThreshold = 100
    
    static func select(urls: [URL]) async {
        guard !urls.isEmpty else {
            print("[Atlas][Select] ⚠️ 0 URL ricevuti — nessuna selezione")
            return
        }
        print("[Atlas][Select] ▶ select start urls=\(urls.count) first=\(urls.first?.path ?? "?")")
        
        let groups = Dictionary(grouping: urls, by: { $0.deletingLastPathComponent() })
        for (_, group) in groups {
            let sorted = group.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if sorted.count > scriptThreshold {
                print("[Atlas][Select] → AppleScript path (files=\(sorted.count) > \(scriptThreshold))")
                await selectViaScript(files: sorted)
            } else {
                print("[Atlas][Select] → native activateFileViewerSelecting (files=\(sorted.count) ≤ \(scriptThreshold))")
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting(sorted)
                }
            }
        }
    }
    
    private static func selectViaScript(files: [URL]) async {
        guard let directory = files.first?.deletingLastPathComponent() else { return }
        let script = buildSelectScript(directory: directory, files: files)
        let started = Date()
        do {
            let result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: [],
                stdin: Data(script.utf8),
                timeout: 120
            )
            let elapsed = Date().timeIntervalSince(started)
            print("[Atlas][Select] osascript exit=\(result.exitCode) time=\(String(format: "%.1f", elapsed))s stdout=\(result.stdout.count)B stderr=\(result.stderr.prefix(300))")
        } catch {
            print("[Atlas][Select] ❌ osascript error: \(error.localizedDescription) after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
    }
    
    static func buildSelectScript(directory: URL, files: [URL]) -> String {
        let paths = files
            .map { appleScriptLiteral($0.path) }
            .joined(separator: ", ")
        // Nota: gli alias si risolvono FUORI dal blocco `tell application "Finder"`,
        // perché dentro il tell la coercizione `POSIX file ... as alias` fallisce.
        return """
        set theTarget to POSIX file \(appleScriptLiteral(directory.path)) as alias
        set theItems to {}
        repeat with thePath in {\(paths)}
            try
                set end of theItems to (POSIX file thePath as alias)
            end try
        end repeat
        tell application "Finder"
            activate
            if (count of Finder windows) > 0 then
                set target of front window to theTarget
            else
                set theWindow to make new Finder window
                set target of theWindow to theTarget
            end if
            if (count of theItems) > 0 then
                select theItems
            end if
        end tell
        """
    }
    
    static func appleScriptLiteral(_ string: String) -> String {
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

final class SelectFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.validationFailed("Cartella corrente non disponibile.")
        }
        let targetFiles = resolveTargetFiles(step: step, directory: currentDirectory)
        guard !targetFiles.isEmpty else {
            throw ExecutorError.validationFailed("Nessun file trovato da selezionare nella cartella corrente.")
        }
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        guard let currentDirectory = context.currentDirectory else { return nil }
        let targetFiles = resolveTargetFiles(step: step, directory: currentDirectory)
        guard !targetFiles.isEmpty else { return nil }
        return ["open -R \(targetFiles.map { "'\($0.path)'" }.joined(separator: " "))"]
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let targetFiles = resolveTargetFiles(step: step, directory: currentDirectory)
        print("[Atlas][Select] execute dir=\(currentDirectory.path) targetFiles=\(targetFiles.count) inputs=\(step.inputs.count) format=\(step.format ?? "nil")")
        guard !targetFiles.isEmpty else {
            print("[Atlas][Select] ⚠️ 0 file risolti — selezione vuota")
            return ActionResult(success: true, outputFiles: [], message: "Nessun file trovato da selezionare.")
        }
        
        // La selezione non crea file: outputFiles vuoto per evitare migliaia di
        // righe in OutputFilesView e l'API nativa che crasha con liste enormi.
        await FinderSelector.select(urls: targetFiles)
        
        return ActionResult(
            success: true,
            outputFiles: [],
            message: "Selezionati \(targetFiles.count) file nel Finder"
        )
    }
    
    private func resolveTargetFiles(step: ActionStep, directory: URL) -> [URL] {
        let formatFilter = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        
        let initialURLs: [URL]
        if !step.inputs.isEmpty {
            initialURLs = step.inputs.compactMap { inputPath in
                let url = directory.appendingPathComponent(inputPath)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } else {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                return []
            }
            initialURLs = contents
        }
        
        // Filter by format extension if format is specified (e.g. 'webp', 'jpg', 'pdf')
        if let targetExt = formatFilter, !targetExt.isEmpty {
            let cleanExt = targetExt.replacingOccurrences(of: ".", with: "")
            return initialURLs.filter { $0.pathExtension.lowercased() == cleanExt }
        }
        
        return initialURLs
    }
}

// MARK: - Copy Files Action (N copies into a folder)

final class CopyFilesAction: ActionExecutor {
    private static let maxCopies = 100
    
    func validate(step: ActionStep, context: FinderContext) throws {
        let files = FileResolver.resolveInputURLs(step: step, context: context)
        guard !files.isEmpty else {
            throw ExecutorError.validationFailed("Nessun file trovato da copiare.")
        }
        guard let count = Self.parseCopyCount(from: step.format), count > 0, count <= Self.maxCopies else {
            throw ExecutorError.validationFailed("Specifica il numero di copie nel campo 'format' (es. '7' o '7;backup').")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let files = FileResolver.resolveInputURLs(step: step, context: context)
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard let copyCount = Self.parseCopyCount(from: step.format), copyCount > 0, copyCount <= Self.maxCopies else {
            throw ExecutorError.executionFailed("Numero di copie non valido nel campo 'format'.")
        }
        guard !files.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun file da copiare.")
        }
        
        let folderName = Self.folderName(from: step.format) ?? "copie"
        let targetFolder = currentDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        
        var created: [URL] = []
        let totalCopies = files.count * copyCount
        var completed = 0
        
        for file in files {
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            for copyIndex in 1...copyCount {
                completed += 1
                progress?(completed, totalCopies, "Copia \(copyIndex)/\(copyCount) di \(file.lastPathComponent)")
                let targetURL = FileResolver.uniqueURL(in: targetFolder, baseName: "\(base)_copia_\(copyIndex)", extensionName: ext)
                try FileManager.default.copyItem(at: file, to: targetURL)
                created.append(targetURL)
            }
        }
        
        return ActionResult(
            success: true,
            outputFiles: created,
            message: "Create \(created.count) copie di \(files.count) file nella cartella '\(folderName)'"
        )
    }
    
    private static func parseCopyCount(from format: String?) -> Int? {
        guard let format else { return nil }
        let first = format.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return first.flatMap { Int($0) }
    }
    
    private static func folderName(from format: String?) -> String? {
        guard let format else { return nil }
        let parts = format.split(separator: ";", maxSplits: 1)
        guard parts.count > 1 else { return nil }
        let name = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

// MARK: - Safe Trash Files Action

final class TrashFilesAction: ActionExecutor {    func validate(step: ActionStep, context: FinderContext) throws {
        try FileResolver.validateNonEmpty(step: step, context: context, allowDirectories: true)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let files = FileResolver.resolveInputURLs(step: step, context: context, allowDirectories: true)
        guard !files.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun elemento da spostare nel Cestino.")
        }
        
        var trashedCount = 0
        var backupURLs: [URL: URL] = [:]
        
        for (index, file) in files.enumerated() {
            progress?(index + 1, files.count, "Spostamento nel Cestino: \(file.lastPathComponent)")
            var resultingURL: NSURL?
            do {
                try FileManager.default.trashItem(at: file, resultingItemURL: &resultingURL)
                trashedCount += 1
                if let newTrashURL = resultingURL as URL? {
                    backupURLs[file] = newTrashURL
                }
            } catch {
                throw ExecutorError.executionFailed("Impossibile spostare '\(file.lastPathComponent)' nel Cestino: \(error.localizedDescription)")
            }
        }
        
        return ActionResult(
            success: true,
            outputFiles: [],
            message: "Spostati \(trashedCount) elementi nel Cestino di macOS",
            backupURLs: backupURLs
        )
    }
}

