import Foundation

@MainActor
class ToolRegistry {
    static let shared = ToolRegistry()
    
    private var capabilities: [String: ToolCapability] = [:]
    
    private init() {
        // Register default plugins here
        register(plugin: ImagePlugin())
        register(plugin: PDFPlugin())
        register(plugin: VideoPlugin())
        register(plugin: FilePlugin())
        register(plugin: ShellPlugin())
    }
    
    func register(plugin: any AtlasPlugin) {
        for capability in plugin.capabilities {
            capabilities[capability.id] = capability
        }
    }
    
    func capability(for id: String) -> ToolCapability? {
        return capabilities[id]
    }
    
    /// ID di tutte le capability registrate, ordinati per stabilità
    /// (consumati dall'enum dello schema del piano).
    var allToolIds: [String] {
        capabilities.keys.sorted()
    }

    func allCapabilities() -> [ToolCapability] {
        return Array(capabilities.values)
    }
}
