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
        
        let backupDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtlasBackups")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        
        for (index, file) in files.enumerated() {
            let numberString = String(index + 1)
            let newBaseName = templateBase.replacingOccurrences(of: "#", with: numberString)
            let ext = templateExt ?? file.pathExtension
            
            let newFileName = ext.isEmpty ? newBaseName : "\(newBaseName).\(ext)"
            let targetURL = directory.appendingPathComponent(newFileName)
            
            let backupURL = backupDir.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: backupURL)
            backupURLs[targetURL] = backupURL
            
            if file.path != targetURL.path {
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
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
        return ["cd \(directory.path) && zip -r \(archiveURL.lastPathComponent) \(files.map { $0.lastPathComponent }.joined(separator: " "))"]
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
        guard !targetFiles.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun file trovato da selezionare.")
        }
        
        // Select & highlight files in Finder
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting(targetFiles)
        }
        
        return ActionResult(
            success: true,
            outputFiles: targetFiles,
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

// MARK: - Safe Trash Files Action

final class TrashFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
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

