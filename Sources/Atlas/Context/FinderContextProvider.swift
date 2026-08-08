import Foundation

/// Gathers the current Finder context (frontmost window, selection, visible
/// files, installed tools) entirely off the main thread:
/// - Finder data via `/usr/bin/osascript` (Process-based, no main-thread
///   AppleScript run-loop blocking).
/// - Filesystem scans on detached utility tasks.
struct FinderContextProvider {
    
    func getCurrentContext() async -> FinderContext {
        async let directoryTask = finderCurrentDirectory()
        async let selectedTask = finderSelectedFiles()
        
        let currentDirectory = await directoryTask
        let selectedFiles = await selectedTask
        let visibleFiles = await visibleFiles(in: currentDirectory)
        let installedTools = await installedTools()
        
        return FinderContext(
            currentDirectory: currentDirectory,
            selectedFiles: selectedFiles,
            visibleFiles: visibleFiles,
            installedTools: installedTools,
            timestamp: Date()
        )
    }
    
    // MARK: - Finder AppleScript (via osascript)
    
    private func runAppleScript(_ source: String) async -> String? {
        guard let result = try? await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", source],
            timeout: 10
        ), result.isSuccess, !result.stdout.isEmpty else {
            return nil
        }
        return result.stdout
    }
    
    private func finderCurrentDirectory() async -> URL? {
        // Fallback: Desktop if no window is found
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        
        let output = await runAppleScript("""
            tell application "Finder"
                if (count of Finder windows) > 0 then
                    return POSIX path of (target of front window as alias)
                else
                    return POSIX path of (desktop as alias)
                end if
            end tell
            """)
        
        if let path = output, !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return desktop
    }
    
    private func finderSelectedFiles() async -> [URL] {
        // Newline-separated output: one POSIX path per line (handles commas in names)
        let output = await runAppleScript("""
            tell application "Finder"
                set theSelection to selection
                set posixPaths to ""
                repeat with anItem in theSelection
                    try
                        set posixPaths to posixPaths & (POSIX path of (anItem as alias)) & linefeed
                    end try
                end repeat
                return posixPaths
            end tell
            """)
        
        guard let output, !output.isEmpty else { return [] }
        
        return output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
    }
    
    // MARK: - Filesystem
    
    private func visibleFiles(in directory: URL?) async -> [URL] {
        guard let directory else { return [] }
        
        return await Task.detached(priority: .utility) {
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }.value
    }
    
    private func installedTools() async -> [String] {
        await Task.detached(priority: .utility) {
            var tools = ["sips", "python3", "zip", "rsync"] // Defaults on macOS
            
            // Check for homebrew tools
            let fm = FileManager.default
            if fm.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") || fm.fileExists(atPath: "/usr/local/bin/ffmpeg") {
                tools.append("ffmpeg")
            }
            if fm.fileExists(atPath: "/opt/homebrew/bin/magick") || fm.fileExists(atPath: "/usr/local/bin/magick") {
                tools.append("imagemagick")
            }
            
            return tools
        }.value
    }
}
