import Foundation

/// Captures directory and selection together, then scans the captured directory off-main.
struct FinderContextProvider {
    private struct Snapshot: Decodable {
        let directory: String
        let selected: [String]
    }

    struct ContextError: Error, LocalizedError {
        let reason: String

        var errorDescription: String? {
            "Impossibile leggere il contesto Finder: \(reason)\nVerifica Impostazioni di Sistema → Privacy e sicurezza → Automazione → Atlas → Finder (System Settings > Privacy & Security > Automation > Atlas > Finder)."
        }
    }

    private static let finderScript = """
        ObjC.import('Foundation');
        function run() {
            const finder = Application('Finder');
            function filePath(item) {
                const url = $.NSURL.URLWithString(item.url());
                if (!url || !url.isFileURL) {
                    throw new Error('Finder did not return a file URL.');
                }
                return ObjC.unwrap(url.path);
            }
            const directory = finder.finderWindows.length > 0
                ? filePath(finder.finderWindows[0].target())
                : filePath(finder.desktop);
            const selected = finder.selection().map(filePath);
            return JSON.stringify({directory: directory, selected: selected});
        }
        """

    func getCurrentContext() async throws -> FinderContext {
        do {
            try Task.checkCancellation()
            guard let osascript = BinaryLocator.locate("osascript") else {
                throw ContextError(reason: "osascript non disponibile.")
            }
            let result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: osascript),
                arguments: ["-l", "JavaScript", "-e", Self.finderScript],
                timeout: 10
            )
            try Task.checkCancellation()
            guard result.isSuccess else {
                throw ContextError(reason: "osascript terminato con codice \(result.exitCode): \(result.stderr)")
            }
            let snapshot = try Self.decodeSnapshot(result.stdout)
            let scan = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let files = try FileManager.default.contentsOfDirectory(
                    at: snapshot.directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).sorted { $0.path < $1.path }
                let tools = [
                    ("sips", "sips"),
                    ("python3", "python3"),
                    ("zip", "zip"),
                    ("rsync", "rsync"),
                    ("ffmpeg", "ffmpeg"),
                    ("magick", "imagemagick"),
                    ("gs", "gs")
                ].compactMap { binary, name in
                    BinaryLocator.locate(binary) == nil ? nil : name
                }
                try Task.checkCancellation()
                return (files, tools)
            }
            let (visibleFiles, installedTools) = try await withTaskCancellationHandler {
                try await scan.value
            } onCancel: {
                scan.cancel()
            }
            try Task.checkCancellation()
            return FinderContext(
                currentDirectory: snapshot.directory,
                selectedFiles: snapshot.selected,
                visibleFiles: visibleFiles,
                installedTools: installedTools,
                timestamp: Date()
            )
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            if let error = error as? ContextError {
                throw error
            }
            throw ContextError(reason: error.localizedDescription)
        }
    }

    /// JSON framing preserves spaces, embedded newlines and Unicode in Finder paths.
    static func decodeSnapshot(_ output: String) throws -> (directory: URL, selected: [URL]) {
        let snapshot: Snapshot
        do {
            snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(output.utf8))
        } catch {
            throw ContextError(reason: "Risposta JSON di Finder non valida: \(error.localizedDescription)")
        }
        guard snapshot.directory.hasPrefix("/"), snapshot.selected.allSatisfy({ $0.hasPrefix("/") }) else {
            throw ContextError(reason: "Finder ha restituito un percorso non assoluto.")
        }
        return (
            URL(fileURLWithPath: snapshot.directory, isDirectory: true),
            snapshot.selected.map { URL(fileURLWithPath: $0) }
        )
    }
}
