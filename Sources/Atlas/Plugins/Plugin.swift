import Foundation

struct ActionResult: Sendable {
    let success: Bool
    let outputFiles: [URL]
    let message: String?
    var backupURLs: [URL: URL] = [:] // original -> backup (per rollback)
    
    init(success: Bool, outputFiles: [URL], message: String?, backupURLs: [URL: URL] = [:]) {
        self.success = success
        self.outputFiles = outputFiles
        self.message = message
        self.backupURLs = backupURLs
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
