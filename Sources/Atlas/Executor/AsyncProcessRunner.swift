import Foundation

struct AsyncProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    
    var isSuccess: Bool { exitCode == 0 }
}

enum AsyncProcessRunnerError: Error, LocalizedError {
    case timeout(Int)
    
    var errorDescription: String? {
        switch self {
        case .timeout(let seconds):
            return "Il processo ha superato il timeout di \(seconds) secondi."
        }
    }
}

/// Thread-safe cancellation flag shared between the calling task and the
/// detached execution task (which does not inherit cancellation).
final class ProcessCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum AsyncProcessRunner {
    /// Executes a CLI executable asynchronously off the main thread.
    ///
    /// - stdout/stderr are drained concurrently so large outputs (pipe buffer
    ///   is ~64KB) can never deadlock the process.
    /// - The process is terminated (SIGTERM) when the calling task is
    ///   cancelled, so "Annulla" actually stops ffmpeg/gs/zip/shell runs.
    /// - A timeout (default 300s) protects against hung processes.
    static func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 300
    ) async throws -> AsyncProcessResult {
        let cancellation = ProcessCancellationState()
        
        print("[Atlas][Proc] ▶ \(executableURL.lastPathComponent) args=\(arguments.count) stdin=\(stdin?.count ?? 0)B cwd=\(currentDirectoryURL?.path ?? "-")")
        
        let runTask = Task.detached(priority: .userInitiated) { () -> AsyncProcessResult in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            // PATH determinista: i nomi nudi (ffmpeg, ...) devono risolvere
            // dentro la sandbox indipendentemente da come Atlas è stato lanciato.
            process.environment = (process.environment ?? [:]).merging(
                ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
                uniquingKeysWith: { _, new in new }
            )
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            // Drain all three pipes concurrently BEFORE any blocking write:
            // a full pipe buffer (~64KB) must never block the others
            // (classic deadlock source with large stdout/stderr/stdin).
            let stdoutReader = Task.detached(priority: .utility) { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
            let stderrReader = Task.detached(priority: .utility) { stderrPipe.fileHandleForReading.readDataToEndOfFile() }
            
            var stdinWriter: Task<Error?, Never>?
            if let stdin {
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                try process.run()
                // Write stdin off-thread: a payload larger than the pipe buffer
                // blocks until the child consumes it, so it must never run on
                // the thread that also waits for exit/timeout.
                stdinWriter = Task.detached(priority: .utility) { () -> Error? in
                    do {
                        try stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
                        stdinPipe.fileHandleForWriting.closeFile()
                        return nil
                    } catch {
                        return error
                    }
                }
            } else {
                try process.run()
            }
            
            let started = Date()
            while process.isRunning {
                if cancellation.isCancelled {
                    process.terminate()
                    throw CancellationError()
                }
                if Date().timeIntervalSince(started) > timeout {
                    process.terminate()
                    throw AsyncProcessRunnerError.timeout(Int(timeout))
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            
            // The writers/readers complete once the process exits (or is
            // terminated by cancel/timeout below).
            let stdoutData = await stdoutReader.value
            let stderrData = await stderrReader.value
            if let stdinWriter, let writeError = await stdinWriter.value, process.isRunning == false, process.terminationStatus != 0 {
                print("[Atlas][Proc] ⚠️ stdin write error: \(writeError)")
            }
            
            let elapsed = Date().timeIntervalSince(started)
            print("[Atlas][Proc] ✓ \(executableURL.lastPathComponent) exit=\(process.terminationStatus) time=\(String(format: "%.1f", elapsed))s stdout=\(stdoutData.count)B stderr=\(stderrData.count)B")
            
            return AsyncProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
        
        return try await withTaskCancellationHandler {
            try await runTask.value
        } onCancel: {
            cancellation.cancel()
            runTask.cancel()
        }
    }
}
