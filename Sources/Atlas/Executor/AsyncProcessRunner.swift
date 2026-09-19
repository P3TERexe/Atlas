import Darwin
import Foundation

struct AsyncProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool { exitCode == 0 }
}

enum AsyncProcessRunnerError: Error, LocalizedError {
    case timeout(Int, stderr: String)
    case cleanup(String)
    case pipeIO(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let seconds, let stderr):
            return "Il processo ha superato il timeout di \(seconds) secondi.\n\(stderr)"
        case .cleanup(let details):
            return "Cleanup del processo incompleto: \(details)"
        case .pipeIO(let details):
            return "Errore nelle pipe del processo: \(details)"
        }
    }
}

/// The flag is the only cancellation channel into the detached process owner.
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
    static func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data? = nil,
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 300
    ) async throws -> AsyncProcessResult {
        let cancellation = ProcessCancellationState()
        return try await withTaskCancellationHandler {
            let owner = Task.detached(priority: .userInitiated) {
                try execute(
                    executableURL: executableURL,
                    arguments: arguments,
                    stdin: stdin,
                    currentDirectoryURL: currentDirectoryURL,
                    timeout: timeout,
                    cancellation: cancellation
                )
            }
            return try await owner.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// All pipe I/O, termination and waiting have one off-main owner. Nonblocking
    /// descriptors let it drain both outputs while feeding stdin, without reader
    /// or writer tasks that could outlive a cancelled/failed invocation.
    private static func execute(
        executableURL: URL,
        arguments: [String],
        stdin: Data?,
        currentDirectoryURL: URL?,
        timeout: TimeInterval,
        cancellation: ProcessCancellationState
    ) throws -> AsyncProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = BinaryLocator.searchDirectories.joined(separator: ":")
        process.environment = environment

        let output = Pipe()
        let errors = Pipe()
        let input = stdin.map { _ in Pipe() }
        process.standardOutput = output
        process.standardError = errors
        if let input {
            process.standardInput = input
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        // Covers configuration failures, a failed launch and every running path.
        // There are no outstanding tasks to join: this scope owns every I/O call.
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close()
            try? errors.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
            try? input?.fileHandleForWriting.close()
        }
        try makeNonblocking(output.fileHandleForReading)
        try makeNonblocking(errors.fileHandleForReading)
        if let input {
            try makeNonblocking(input.fileHandleForWriting)
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw pipeError("stdin SIGPIPE")
            }
        }
        if cancellation.isCancelled { throw CancellationError() }
        try process.run()
        // Close our copies of child-owned ends even when the child exits early.
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        try? input?.fileHandleForReading.close()

        var stdout = Data()
        var stderr = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var outputOpen = true
        var errorsOpen = true
        var inputOpen = input != nil
        var inputOffset = 0
        var ioError: Error?
        var interruption: Error?
        let started = ProcessInfo.processInfo.systemUptime
        var terminationStarted: TimeInterval?
        var exitObserved: TimeInterval?
        var cleanupFailed = false

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            do {
                if outputOpen {
                    outputOpen = try drain(output.fileHandleForReading, into: &stdout, buffer: &buffer)
                }
                if errorsOpen {
                    errorsOpen = try drain(errors.fileHandleForReading, into: &stderr, buffer: &buffer)
                }
                if inputOpen, let input, let stdin {
                    inputOpen = try feed(input.fileHandleForWriting, data: stdin, offset: &inputOffset)
                }
            } catch {
                ioError = error
                // In particular, an EPIPE must close the stdin writer too.
                try? input?.fileHandleForWriting.close()
                inputOpen = false
            }

            if process.isRunning {
                if terminationStarted == nil {
                    if cancellation.isCancelled {
                        interruption = CancellationError()
                    } else if now - started >= timeout {
                        interruption = AsyncProcessRunnerError.timeout(Int(timeout), stderr: "")
                    } else if let ioError {
                        interruption = ioError
                    }
                    if interruption != nil {
                        process.terminate()
                        terminationStarted = now
                        try? input?.fileHandleForWriting.close()
                        inputOpen = false
                    }
                } else if let terminationStarted, now - terminationStarted >= 1 {
                    // We still own this Process and have not observed its exit.
                    // This terminates the direct child, not an unproven process tree.
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    process.waitUntilExit()
                }
            }

            if !process.isRunning {
                if exitObserved == nil {
                    process.waitUntilExit()
                    exitObserved = ProcessInfo.processInfo.systemUptime
                    try? input?.fileHandleForWriting.close()
                    inputOpen = false
                }
                if !outputOpen && !errorsOpen { break }
                // A descendant may retain an output pipe after the direct child
                // exits. Never block indefinitely waiting for its EOF.
                if ProcessInfo.processInfo.systemUptime - exitObserved! >= 1 {
                    cleanupFailed = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        let result = AsyncProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        if cleanupFailed {
            throw AsyncProcessRunnerError.cleanup("Pipe ancora aperte dopo l'uscita del processo. \(result.stderr)")
        }
        if let interruption {
            if let error = interruption as? AsyncProcessRunnerError,
               case .timeout(let seconds, _) = error {
                throw AsyncProcessRunnerError.timeout(seconds, stderr: result.stderr)
            }
            throw interruption
        }
        if cancellation.isCancelled { throw CancellationError() }
        if let ioError, result.isSuccess { throw ioError }
        return result
    }

    private static func makeNonblocking(_ handle: FileHandle) throws {
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        guard flags != -1, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw pipeError("fcntl")
        }
    }

    /// Bounded work per pass prevents a continuously noisy output from starving
    /// the other pipe, stdin or the cancellation/timeout check.
    private static func drain(_ handle: FileHandle, into data: inout Data, buffer: inout [UInt8]) throws -> Bool {
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(handle.fileDescriptor, bytes.baseAddress!, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                try? handle.close()
                return false
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            } else if errno != EINTR {
                throw pipeError("read")
            }
        }
        return true
    }

    private static func feed(_ handle: FileHandle, data: Data, offset: inout Int) throws -> Bool {
        if offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(handle.fileDescriptor, bytes.baseAddress!.advanced(by: offset), min(65_536, data.count - offset))
            }
            if count > 0 {
                offset += count
            } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                throw pipeError("write")
            }
        }
        if offset == data.count {
            try? handle.close()
            return false
        }
        return true
    }

    private static func pipeError(_ operation: String) -> AsyncProcessRunnerError {
        .pipeIO("\(operation): \(String(cString: strerror(errno)))")
    }
}
