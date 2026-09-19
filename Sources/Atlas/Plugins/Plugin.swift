import Foundation

struct ActionResult: Sendable {
    let success: Bool
    let outputFiles: [URL]
    let message: String?
    var backupURLs: [URL: URL] = [:] // original -> backup (per rollback)
    let undoSupported: Bool
    
    init(success: Bool, outputFiles: [URL], message: String?, backupURLs: [URL: URL] = [:], undoSupported: Bool = true) {
        self.success = success
        self.outputFiles = outputFiles
        self.message = message
        self.backupURLs = backupURLs
        self.undoSupported = undoSupported
    }
}

struct ActionExecutionError: Error {
    let underlying: Error
    let partialResult: ActionResult
}

enum StagedOutput {
    static func write(to destination: URL, journal: inout [URL], body: (URL) async throws -> Void) async throws {
        try Task.checkCancellation()
        var temporary = destination.deletingLastPathComponent().appendingPathComponent(".atlas-output-\(UUID().uuidString)")
        if !destination.pathExtension.isEmpty {
            temporary.appendPathExtension(destination.pathExtension)
        }
        journal.append(temporary)
        try await body(temporary)
        try Task.checkCancellation()
        // FileManager move refuses an existing destination, including a racing writer.
        try FileManager.default.moveItem(at: temporary, to: destination)
        journal.removeAll { $0 == temporary }
        journal.append(destination)
    }
}

enum InputResolver {
    /// Authoritative resolution: explicit inputs are exact (relative to the
    /// Finder directory or absolute) and never silently dropped; empty inputs
    /// freeze to the full selection, then the visible candidates.
    static func resolve(
        step: ActionStep,
        context: FinderContext,
        extensions: Set<String>? = nil,
        allowDirectories: Bool = false
    ) throws -> [URL] {
        func accepted(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
            if !allowDirectories && isDir.boolValue { return false }
            if let extensions, extensions.contains(url.pathExtension.lowercased()) == false { return false }
            return true
        }

        func parse(_ input: String) throws -> URL {
            if let url = URL(string: input), url.isFileURL, url.path.hasPrefix("/") {
                return url
            }
            if input.hasPrefix("/") {
                return URL(fileURLWithPath: input)
            }
            guard let directory = context.currentDirectory else {
                throw ExecutorError.validationFailed("Cartella corrente non disponibile per '\(input)'.")
            }
            return directory.appendingPathComponent(input)
        }
        if !step.inputs.isEmpty {
            var seen = Set<URL>()
            var resolved: [URL] = []
            for input in step.inputs {
                let url = try parse(input)
                guard seen.insert(url.standardizedFileURL).inserted else { continue }
                guard accepted(url) else {
                    throw ExecutorError.validationFailed("Input richiesto non disponibile o di tipo errato: \(url.lastPathComponent)")
                }
                resolved.append(url)
            }
            return resolved
        }

        // Selection freezes scope: filter it, never fall back to the visible
        // directory when the selection matches nothing.
        if !context.selectedFiles.isEmpty {
            var seen = Set<URL>()
            let selected = context.selectedFiles.filter { seen.insert($0.standardizedFileURL).inserted }
            let matching = selected.filter(accepted)
            guard !matching.isEmpty else {
                throw ExecutorError.validationFailed("Nessun elemento selezionato compatibile con l'operazione richiesta.")
            }
            return matching
        }
        var seen = Set<URL>()
        let visible = context.visibleFiles.filter { seen.insert($0.standardizedFileURL).inserted }
        let matching = visible.filter(accepted)
        guard !matching.isEmpty else {
            throw ExecutorError.validationFailed("Nessun file compatibile trovato nella cartella visibile.")
        }
        return matching
    }
}

typealias ItemProgressCallback = @Sendable (_ itemIndex: Int, _ totalItems: Int, _ detailMessage: String) -> Void

protocol ActionExecutor: Sendable {
    func validate(step: ActionStep, context: FinderContext) throws
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]?
}

extension ActionExecutor {
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        try await execute(step: step, context: context, progress: nil)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        return nil
    }
}

struct ToolCapability {
    let id: String              // e.g. "image.convert"
    let description: String
    let inputFormats: [String]
    let outputFormats: [String]
    let executor: any ActionExecutor
}

protocol AtlasPlugin {
    var id: String { get }
    var capabilities: [ToolCapability] { get }
}
