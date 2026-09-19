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
            ToolCapability(
                id: "file.mkdir",
                description: "Creates a new folder or directory in the current location. Set 'format' to the folder name (e.g. 'caccona galattica' or 'Progetti').",
                inputFormats: [],
                outputFormats: [],
                executor: MakeDirectoryAction()
            ),
            ToolCapability(
                id: "file.move",
                description: "Moves files into a destination folder. Set 'format' to the destination folder name (e.g. 'caccona galattica') and 'inputs' to files (or empty for predecessor/matching files).",
                inputFormats: [],
                outputFormats: [],
                executor: MoveFilesAction()
            ),
        ]
    }
}

// MARK: - Shared input resolution

enum FileResolver {
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
        _ = try InputResolver.resolve(step: step, context: context)
        
        guard let template = step.format?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty else {
            throw ExecutorError.validationFailed("Specifica un template con '#' come segnaposto del numero, es. 'vacanza_#.jpg'.")
        }
        guard template.contains("#") else {
            throw ExecutorError.validationFailed("Il template deve contenere '#' come segnaposto del numero, es. 'vacanza_#.jpg'.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let files = try InputResolver.resolve(step: step, context: context)
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
        
        let mappings = files.enumerated().map { index, file in
            let base = templateBase.replacingOccurrences(of: "#", with: String(index + 1))
            let ext = templateExt ?? file.pathExtension
            return (source: file, target: directory.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)"))
        }
        return try await Self.rename(mappings, progress: progress)
    }

    /// Targets are resolved before any mutation so overlapping names cannot consume a later source.
    static func rename(_ mappings: [(source: URL, target: URL)], progress: ItemProgressCallback? = nil) async throws -> ActionResult {
        var outputs: [URL] = []
        var backups: [URL: URL] = [:]
        do {
            var targets = Set<URL>()
            var sources = Set<URL>()
            for mapping in mappings {
                guard targets.insert(mapping.target.standardizedFileURL).inserted,
                      sources.insert(mapping.source.standardizedFileURL).inserted else {
                    throw ExecutorError.validationFailed("La rinomina contiene sorgenti o destinazioni duplicate.")
                }
            }
            let changes = mappings.filter { $0.source.standardizedFileURL != $0.target.standardizedFileURL }
            guard !changes.isEmpty else {
                return ActionResult(success: true, outputFiles: [], message: "Nessun nome da modificare.")
            }
            let fm = FileManager.default
            try Task.checkCancellation()
            let backupDir = try BackupStore.newBackupDirectory()
            let changedSources = Set(changes.map { $0.source.standardizedFileURL })
            let externalTargets = Set(changes.map(\.target).filter {
                !changedSources.contains($0.standardizedFileURL) && fm.fileExists(atPath: $0.path)
            })
            for original in changes.map(\.source) + Array(externalTargets) where backups[original] == nil {
                try Task.checkCancellation()
                let backup = backupDir.appendingPathComponent(UUID().uuidString)
                outputs.append(backup)
                try fm.copyItem(at: original, to: backup)
                backups[original] = backup
                outputs.removeAll { $0 == backup }
            }
            var staged: [(temporary: URL, target: URL)] = []
            for (index, mapping) in changes.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, changes.count, "Rinomina: \(mapping.source.lastPathComponent)")
                try Task.checkCancellation()
                let temporary = mapping.source.deletingLastPathComponent().appendingPathComponent(".atlas-rename-\(UUID().uuidString)")
                try fm.moveItem(at: mapping.source, to: temporary)
                outputs.append(temporary)
                staged.append((temporary, mapping.target))
            }
            for item in staged {
                try Task.checkCancellation()
                if externalTargets.contains(item.target), fm.fileExists(atPath: item.target.path) {
                    _ = try fm.replaceItemAt(item.target, withItemAt: item.temporary)
                } else {
                    // moveItem refuses a destination that appeared after preflight.
                    try fm.moveItem(at: item.temporary, to: item.target)
                }
                outputs.removeAll { $0 == item.temporary }
                outputs.append(item.target)
            }
            return ActionResult(success: true, outputFiles: outputs, message: "Rinominati \(changes.count) file", backupURLs: backups)
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputs, message: nil, backupURLs: backups))
        }
    }
}

// MARK: - Zip (single archive)

final class ZipFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        let files = try InputResolver.resolve(step: step, context: context, allowDirectories: true)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.validationFailed("Cartella corrente non disponibile.")
        }
        _ = try Self.sourcePlan(files: files, directory: directory)
    }

    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        guard let files = try? InputResolver.resolve(step: step, context: context, allowDirectories: true),
              let directory = context.currentDirectory,
              let plan = try? Self.sourcePlan(files: files, directory: directory) else { return nil }
        let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".zip", with: "") ?? "archive"
        let archiveURL = FileResolver.uniqueURL(in: directory, baseName: rawName, extensionName: "zip")
        return Self.preview(plan: plan, archiveURL: archiveURL)
    }

    /// Quoting per shell POSIX: singoli apici con escape del carattere '.
    /// Visibile per il testing (internal).
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    struct SourcePlan {
        let directory: URL
        let localPaths: [String]
        let externalFiles: [URL]
        let stagingDirectory: URL
    }

    static func sourcePlan(files: [URL], directory: URL) throws -> SourcePlan {
        let root = directory.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var localPaths: [String] = []
        var externalFiles: [URL] = []
        for file in files {
            let path = file.standardizedFileURL.path
            if path.hasPrefix(prefix) {
                localPaths.append("./" + String(path.dropFirst(prefix.count)))
            } else if path == root {
                // An archive created in this directory must not recursively include itself.
                throw ExecutorError.validationFailed("Non è possibile archiviare la cartella corrente al suo interno.")
            } else {
                externalFiles.append(file)
            }
        }
        if !externalFiles.isEmpty {
            var basenames = Set<String>()
            for file in files {
                guard basenames.insert(file.lastPathComponent).inserted else {
                    throw ExecutorError.validationFailed("Nomi duplicati negli input ZIP: \(file.lastPathComponent)")
                }
            }
            for file in externalFiles {
                let member = "./" + file.lastPathComponent
                guard !localPaths.contains(where: { $0 == member || $0.hasPrefix(member + "/") || member.hasPrefix($0 + "/") }) else {
                    throw ExecutorError.validationFailed("Percorsi sovrapposti negli input ZIP: \(file.lastPathComponent)")
                }
            }
        }
        return SourcePlan(
            directory: directory,
            localPaths: localPaths,
            externalFiles: externalFiles,
            stagingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    static func arguments(archiveURL: URL, paths: [String]) -> [String] {
        ["-r", archiveURL.path] + paths
    }

    private static func groups(for plan: SourcePlan) -> [(directory: URL, paths: [String])] {
        var groups: [(directory: URL, paths: [String])] = []
        if !plan.localPaths.isEmpty { groups.append((plan.directory, plan.localPaths)) }
        if !plan.externalFiles.isEmpty {
            groups.append((plan.stagingDirectory, plan.externalFiles.map { "./" + $0.lastPathComponent }))
        }
        return groups
    }

    static func preview(plan: SourcePlan, archiveURL: URL) -> [String] {
        var commands: [String] = []
        if !plan.externalFiles.isEmpty {
            commands.append("/bin/mkdir \(shellQuote(plan.stagingDirectory.path))")
            commands += plan.externalFiles.map {
                "/bin/cp -R \(shellQuote($0.path)) \(shellQuote(plan.stagingDirectory.appendingPathComponent($0.lastPathComponent).path))"
            }
        }
        commands += groups(for: plan).map {
            "(cd \(shellQuote($0.directory.path)) && /usr/bin/zip " + arguments(archiveURL: archiveURL, paths: $0.paths).map(shellQuote).joined(separator: " ") + ")"
        }
        if !plan.externalFiles.isEmpty {
            commands.append("/bin/rm -rf \(shellQuote(plan.stagingDirectory.path))")
        }
        return commands
    }

    static func createArchive(plan: SourcePlan, archiveURL: URL) async throws {
        let fm = FileManager.default
        var ownsStaging = false
        defer {
            if ownsStaging { try? fm.removeItem(at: plan.stagingDirectory) }
        }
        if !plan.externalFiles.isEmpty {
            try Task.checkCancellation()
            try fm.createDirectory(at: plan.stagingDirectory, withIntermediateDirectories: false)
            ownsStaging = true
            for file in plan.externalFiles {
                try Task.checkCancellation()
                try fm.copyItem(at: file, to: plan.stagingDirectory.appendingPathComponent(file.lastPathComponent))
            }
        }
        for group in groups(for: plan) {
            try Task.checkCancellation()
            let result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
                arguments: arguments(archiveURL: archiveURL, paths: group.paths),
                currentDirectoryURL: group.directory
            )
            guard result.isSuccess, fm.fileExists(atPath: archiveURL.path) else {
                throw ExecutorError.executionFailed("Creazione dell'archivio ZIP fallita: \(result.stderr)")
            }
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let files = try InputResolver.resolve(step: step, context: context, allowDirectories: true)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard !files.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun elemento da comprimere.")
        }
        
        let rawName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ".zip", with: "") ?? "archive"
        let archiveURL = FileResolver.uniqueURL(in: directory, baseName: rawName, extensionName: "zip")
        let plan = try Self.sourcePlan(files: files, directory: directory)
        
        var outputs: [URL] = []
        do {
            try await StagedOutput.write(to: archiveURL, journal: &outputs) { temporary in
                try await Self.createArchive(plan: plan, archiveURL: temporary)
            }
            return ActionResult(success: true, outputFiles: outputs, message: "Creato \(archiveURL.lastPathComponent) con \(files.count) elementi")
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputs, message: nil))
        }
    }
}

// MARK: - Compress (per-item archives)

final class CompressFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try ZipFilesAction().validate(step: step, context: context)
    }

    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        guard let files = try? InputResolver.resolve(step: step, context: context, allowDirectories: true),
              let directory = context.currentDirectory,
              (try? ZipFilesAction.sourcePlan(files: files, directory: directory)) != nil else { return nil }
        var reserved = Set<URL>()
        var commands: [String] = []
        for file in files {
            guard let plan = try? ZipFilesAction.sourcePlan(files: [file], directory: directory) else { return nil }
            let baseName = file.deletingPathExtension().lastPathComponent
            var archiveURL = FileResolver.uniqueURL(in: directory, baseName: baseName, extensionName: "zip")
            var suffix = 2
            while reserved.contains(archiveURL) || FileManager.default.fileExists(atPath: archiveURL.path) {
                archiveURL = directory.appendingPathComponent("\(baseName)-\(suffix).zip")
                suffix += 1
            }
            reserved.insert(archiveURL)
            commands += ZipFilesAction.preview(plan: plan, archiveURL: archiveURL)
        }
        return commands
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let files = try InputResolver.resolve(step: step, context: context, allowDirectories: true)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard !files.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun elemento da comprimere.")
        }
        // Reject ambiguous external basenames before creating any per-item archive.
        _ = try ZipFilesAction.sourcePlan(files: files, directory: directory)
        
        var outputFiles: [URL] = []
        
        do {
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, files.count, "Compressione: \(file.lastPathComponent)")
                let baseName = file.deletingPathExtension().lastPathComponent
                let archiveURL = FileResolver.uniqueURL(in: directory, baseName: baseName, extensionName: "zip")
                let plan = try ZipFilesAction.sourcePlan(files: [file], directory: directory)
                try await StagedOutput.write(to: archiveURL, journal: &outputFiles) { temporary in
                    try await ZipFilesAction.createArchive(plan: plan, archiveURL: temporary)
                }
            }
            return ActionResult(success: true, outputFiles: outputFiles, message: "Creati \(outputFiles.count) archivi ZIP")
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
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
        _ = try resolveTargetFiles(step: step, context: context)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        guard let targetFiles = try? resolveTargetFiles(step: step, context: context) else { return nil }
        return ["open -R \(targetFiles.map { "'\($0.path)'" }.joined(separator: " "))"]
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let targetFiles = try resolveTargetFiles(step: step, context: context)
        print("[Atlas][Select] execute dir=\(currentDirectory.path) targetFiles=\(targetFiles.count) inputs=\(step.inputs.count) format=\(step.format ?? "nil")")
        guard !targetFiles.isEmpty else {
            print("[Atlas][Select] ⚠️ 0 file risolti — selezione vuota")
            return ActionResult(success: true, outputFiles: [], message: "Nessun file trovato da selezionare.")
        }
        
        // La selezione non crea file: outputFiles vuoto per evitare migliaia di
        // righe in OutputFilesView e l'API nativa che crasha con liste enormi.
        try Task.checkCancellation()
        await FinderSelector.select(urls: targetFiles)
        
        return ActionResult(
            success: true,
            outputFiles: [],
            message: "Selezionati \(targetFiles.count) file nel Finder"
        )
    }
    
    private func resolveTargetFiles(step: ActionStep, context: FinderContext) throws -> [URL] {
        let format = step.format?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: ".", with: "")
        let extensions: Set<String>? = format.flatMap { $0.isEmpty ? nil : Set([$0]) }
        return try InputResolver.resolve(step: step, context: context, extensions: extensions, allowDirectories: extensions == nil)
    }
}

// MARK: - Copy Files Action (N copies into a folder)

final class CopyFilesAction: ActionExecutor {
    private static let maxCopies = 100
    
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context)
        guard let count = Self.parseCopyCount(from: step.format), count > 0, count <= Self.maxCopies else {
            throw ExecutorError.validationFailed("Specifica il numero di copie nel campo 'format' (es. '7' o '7;backup').")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let files = try InputResolver.resolve(step: step, context: context)
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
        var created: [URL] = []
        var stagedFiles: [URL] = []
        do {
            if FileManager.default.fileExists(atPath: targetFolder.path) {
                try await Self.copy(files, count: copyCount, into: targetFolder, journal: &created, progress: progress)
            } else {
                // Publish the whole newly-created directory tree only after every copy succeeds.
                var newRoot = targetFolder
                var subfolders: [String] = []
                while !FileManager.default.fileExists(atPath: newRoot.deletingLastPathComponent().path) {
                    subfolders.insert(newRoot.lastPathComponent, at: 0)
                    newRoot = newRoot.deletingLastPathComponent()
                }
                try await StagedOutput.write(to: newRoot, journal: &created) { temporary in
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                    let workingFolder = subfolders.reduce(temporary) { $0.appendingPathComponent($1, isDirectory: true) }
                    if !subfolders.isEmpty {
                        try FileManager.default.createDirectory(at: workingFolder, withIntermediateDirectories: true)
                    }
                    try await Self.copy(files, count: copyCount, into: workingFolder, journal: &stagedFiles, progress: progress)
                }
                created.append(contentsOf: stagedFiles.map { targetFolder.appendingPathComponent($0.lastPathComponent) })
            }
            return ActionResult(success: true, outputFiles: created, message: "Create \(files.count * copyCount) copie di \(files.count) file nella cartella '\(folderName)'")
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: created + stagedFiles, message: nil))
        }
    }

    private static func copy(_ files: [URL], count: Int, into folder: URL, journal: inout [URL], progress: ItemProgressCallback?) async throws {
        var completed = 0
        for file in files {
            try Task.checkCancellation()
            let base = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension
            for copyIndex in 1...count {
                try Task.checkCancellation()
                completed += 1
                progress?(completed, files.count * count, "Copia \(copyIndex)/\(count) di \(file.lastPathComponent)")
                let target = FileResolver.uniqueURL(in: folder, baseName: "\(base)_copia_\(copyIndex)", extensionName: ext)
                try await StagedOutput.write(to: target, journal: &journal) { temporary in
                    try FileManager.default.copyItem(at: file, to: temporary)
                }
            }
        }
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
        _ = try InputResolver.resolve(step: step, context: context, allowDirectories: true)
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let files = try InputResolver.resolve(step: step, context: context, allowDirectories: true)
        guard !files.isEmpty else {
            return ActionResult(success: true, outputFiles: [], message: "Nessun elemento da spostare nel Cestino.")
        }
        
        var trashedCount = 0
        var backupURLs: [URL: URL] = [:]
        var outputs: [URL] = []
        do {
            try Task.checkCancellation()
            let backupDir = try BackupStore.newBackupDirectory()
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, files.count, "Spostamento nel Cestino: \(file.lastPathComponent)")
                try Task.checkCancellation()
                let backup = backupDir.appendingPathComponent(UUID().uuidString)
                outputs.append(backup)
                try FileManager.default.copyItem(at: file, to: backup)
                backupURLs[file] = backup
                outputs.removeAll { $0 == backup }
                try Task.checkCancellation()
                var resultingURL: NSURL?
                do {
                    try FileManager.default.trashItem(at: file, resultingItemURL: &resultingURL)
                } catch {
                    if let trashURL = resultingURL as URL? { outputs.append(trashURL) }
                    throw error
                }
                if let trashURL = resultingURL as URL? { outputs.append(trashURL) }
                trashedCount += 1
            }
            return ActionResult(success: true, outputFiles: outputs, message: "Spostati \(trashedCount) elementi nel Cestino di macOS", backupURLs: backupURLs)
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputs, message: nil, backupURLs: backupURLs))
        }
    }
}

// MARK: - Make Directory Action

final class MakeDirectoryAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard let folderName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty else {
            throw ExecutorError.validationFailed("Specifica il nome della cartella da creare nel campo 'format'.")
        }
        guard !folderName.contains("/") else {
            throw ExecutorError.validationFailed("Il nome della cartella non può contenere barre '/'.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard let folderName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty else {
            throw ExecutorError.validationFailed("Nome cartella mancante.")
        }
        let targetFolder = currentDirectory.appendingPathComponent(folderName, isDirectory: true)
        var created = false
        if !FileManager.default.fileExists(atPath: targetFolder.path) {
            try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
            created = true
        }
        return ActionResult(
            success: true,
            outputFiles: [targetFolder],
            message: created ? "Creata cartella '\(folderName)'" : "Cartella '\(folderName)' già esistente",
            undoSupported: created
        )
    }
}

// MARK: - Move Files Action

final class MoveFilesAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard let folderName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty else {
            throw ExecutorError.validationFailed("Specifica il nome della cartella di destinazione nel campo 'format'.")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard let folderName = step.format?.trimmingCharacters(in: .whitespacesAndNewlines), !folderName.isEmpty else {
            throw ExecutorError.validationFailed("Nome cartella di destinazione mancante.")
        }
        let targetFolder = currentDirectory.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: targetFolder.path) {
            try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        }
        
        let files = try InputResolver.resolve(step: step, context: context, allowDirectories: true)
        var movedFiles: [URL] = []
        var backupURLs: [URL: URL] = [:]
        
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            progress?(index + 1, files.count, "Spostamento \(index + 1)/\(files.count): \(file.lastPathComponent)")
            if file.path == targetFolder.path { continue }
            if file.deletingLastPathComponent().path == targetFolder.path { continue }
            
            let uniqueDestination = FileResolver.uniqueURL(
                in: targetFolder,
                baseName: file.deletingPathExtension().lastPathComponent,
                extensionName: file.pathExtension
            )
            
            try FileManager.default.moveItem(at: file, to: uniqueDestination)
            movedFiles.append(uniqueDestination)
            backupURLs[uniqueDestination] = file
        }
        
        return ActionResult(
            success: true,
            outputFiles: movedFiles,
            message: "Spostati \(movedFiles.count) elementi nella cartella '\(folderName)'",
            backupURLs: backupURLs
        )
    }
}

