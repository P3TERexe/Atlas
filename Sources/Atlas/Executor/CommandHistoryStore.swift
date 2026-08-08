import Foundation
import Combine

/// Persists the command palette query history across view re-creations and app restarts.
/// Backed by ApplicationSupport/Atlas/commandHistory.json so it survives app updates.
@MainActor
final class CommandHistoryStore: ObservableObject {
    static let shared = CommandHistoryStore()

    @Published private(set) var history: [String] = []

    private let fileURL: URL
    private static let maxEntries = 100

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Atlas", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("commandHistory.json")
        load()
    }

    // MARK: - Public API

    func append(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Remove duplicate then re-append at end (most recent = last)
        var h = history.filter { $0 != trimmed }
        h.append(trimmed)
        if h.count > Self.maxEntries { h = Array(h.suffix(Self.maxEntries)) }
        history = h
        save()
    }

    func clear() {
        history = []
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return }
        history = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
