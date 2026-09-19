import Darwin
import XCTest
@testable import Atlas

@MainActor
final class AsyncProcessRunnerTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The expectation bounds even regressions where the runner never returns;
    /// unlike a task-group race, it does not join the hung invocation on timeout.
    private func boundedResult(_ task: Task<AsyncProcessResult, Error>) async throws -> Result<AsyncProcessResult, Error> {
        let finished = expectation(description: "Process owner completes all I/O")
        var outcome: Result<AsyncProcessResult, Error>?
        let observer = Task { @MainActor in
            outcome = await task.result
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 6)
        guard let outcome else {
            task.cancel()
            observer.cancel()
            throw NSError(domain: "AsyncProcessRunnerTests.deadline", code: 1)
        }
        return outcome
    }

    private func waitForPID(at url: URL) async throws -> pid_t {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let text = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "AsyncProcessRunnerTests.missingPID", code: 1)
    }

    private func assertExited(_ pid: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        let status = Darwin.kill(pid, 0)
        let error = errno
        XCTAssertEqual(status, -1, "Child still exists when runner returns", file: file, line: line)
        XCTAssertEqual(error, ESRCH, file: file, line: line)
    }

    func testCancellationDrainsBothPipesAndWaitsForUncooperativeChildExit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "trap '' TERM; echo $$ > child.pid; while :; do printf 'stdout\\n'; printf 'stderr\\n' >&2; done"],
                currentDirectoryURL: directory,
                timeout: 10
            )
        }
        defer { task.cancel() }
        let pid = try await waitForPID(at: directory.appendingPathComponent("child.pid"))
        defer { if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) } }
        try await Task.sleep(for: .milliseconds(80))
        task.cancel()
        let result = try await boundedResult(task)
        switch result {
        case .success: XCTFail("Cancellation must not report success")
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)")
        }
        assertExited(pid)
    }

    func testTimeoutClosesBlockedLargeStdinAndWaitsForExit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "trap '' TERM; echo $$ > child.pid; printf '  diagnostic\\n\\n' >&2; while :; do :; done"],
                stdin: Data(repeating: 65, count: 2 * 1_024 * 1_024),
                currentDirectoryURL: directory,
                timeout: 0.3
            )
        }
        defer { task.cancel() }
        let pid = try await waitForPID(at: directory.appendingPathComponent("child.pid"))
        defer { if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) } }
        let result = try await boundedResult(task)
        switch result {
        case .failure(let error as AsyncProcessRunnerError):
            guard case .timeout(_, let stderr) = error else { return XCTFail("Expected timeout, got \(error)") }
            XCTAssertEqual(stderr, "  diagnostic\n\n")
        default: XCTFail("Expected process timeout, got \(result)")
        }
        assertExited(pid)
    }

    func testUnlaunchableProcessClosesEveryPipe() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            try await AsyncProcessRunner.run(
                executableURL: directory.appendingPathComponent("does-not-exist"),
                arguments: [],
                stdin: Data(repeating: 65, count: 256 * 1_024),
                timeout: 1
            )
        }
        let result = try await boundedResult(task)
        guard case .failure(let error) = result else { return XCTFail("Missing executable must fail") }
        XCTAssertFalse(error is AsyncProcessRunnerError, "Launch error must not become timeout or cleanup error")
    }

    func testLargeStdinFeedsWhileBothOutputPipesDrain() async throws {
        let payload = Data(repeating: 65, count: 512 * 1_024)
        let task = Task {
            try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/tee"),
                arguments: ["/dev/stderr"],
                stdin: payload,
                timeout: 4
            )
        }
        let result = try await boundedResult(task).get()
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(Data(result.stdout.utf8), payload)
        XCTAssertEqual(Data(result.stderr.utf8), payload)
    }

    func testOutputWhitespaceAndFailureStderrAreData() async throws {
        let task = Task {
            try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "printf '  output\\n\\n'; printf '\\n error  \\n' >&2; exit 7"],
                timeout: 1
            )
        }
        let result = try await boundedResult(task).get()
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.stdout, "  output\n\n")
        XCTAssertEqual(result.stderr, "\n error  \n")
    }

    func testExitedChildWithInheritedOpenPipesFailsCleanupWithinDeadline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let task = Task {
            try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 4 & echo $! > descendant.pid; exit 0"],
                currentDirectoryURL: directory,
                timeout: 2
            )
        }
        defer { task.cancel() }
        let pid = try await waitForPID(at: directory.appendingPathComponent("descendant.pid"))
        defer { if Darwin.kill(pid, 0) == 0 { _ = Darwin.kill(pid, SIGKILL) } }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await boundedResult(task)
        guard case .failure(let error as AsyncProcessRunnerError) = result,
              case .cleanup = error else { return XCTFail("Inherited pipe must report cleanup error: \(result)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
    }
}
