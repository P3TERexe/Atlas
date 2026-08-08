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
        
        let runTask = Task.detached(priority: .userInitiated) { () -> AsyncProcessResult in
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectoryURL
            
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            
            if let stdin {
                let stdinPipe = Pipe()
                process.standardInput = stdinPipe
                try process.run()
                stdinPipe.fileHandleForWriting.write(stdin)
                stdinPipe.fileHandleForWriting.closeFile()
            } else {
                try process.run()
            }
            
            // Drain both pipes concurrently: a blocked pipe must never
            // prevent the other from being read (deadlock source).
            let stdoutReader = Task.detached(priority: .utility) { stdoutPipe.fileHandleForReading.readDataToEndOfFile() }
            let stderrReader = Task.detached(priority: .utility) { stderrPipe.fileHandleForReading.readDataToEndOfFile() }
            
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
            
            let stdoutData = await stdoutReader.value
            let stderrData = await stderrReader.value
            
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
