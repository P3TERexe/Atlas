import Foundation
import Combine

struct UserRule: Codable, Identifiable {
    let id: UUID
    var trigger: String
    var instruction: String
    var folderFilter: String?
    var isEnabled: Bool
    
    init(id: UUID = UUID(), trigger: String, instruction: String, folderFilter: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.trigger = trigger
        self.instruction = instruction
        self.folderFilter = folderFilter
        self.isEnabled = isEnabled
    }
}

@MainActor
final class RulesStore: ObservableObject {
    static let shared = RulesStore()
    
    @Published private(set) var rules: [UserRule] = []
    
    private let fileURL: URL
    
    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Atlas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("rules.json")
        load()
    }
    
    func activeRules(for query: String, currentFolder: String?) -> [UserRule] {
        let lowerQuery = query.lowercased()
        return rules.filter { rule in
            guard rule.isEnabled else { return false }
            
            // Check trigger match
            let triggerMatch = lowerQuery.contains(rule.trigger.lowercased())
            
            // Check folder match if set
            if let filter = rule.folderFilter, !filter.isEmpty {
                guard let folder = currentFolder, folder.lowercased().contains(filter.lowercased()) else {
                    return false
                }
            }
            
            return triggerMatch
        }
    }
    
    func add(rule: UserRule) {
        rules.append(rule)
        save()
    }
    
    func update(rule: UserRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
            save()
        }
    }
    
    func delete(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }
    
    func toggle(id: UUID) {
        if let index = rules.firstIndex(where: { $0.id == id }) {
            rules[index].isEnabled.toggle()
            save()
        }
    }

    // MARK: - Persistence
    
    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([UserRule].self, from: data) else {
            // Default sample rules if empty
            rules = [
                UserRule(trigger: "youtube", instruction: "Export video as MP4, 1080p, 30fps, H.264 codec"),
                UserRule(trigger: "instagram", instruction: "Crop or resize image to 1080x1080 square format")
            ]
            save()
            return
        }
        rules = decoded
    }
    
    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
