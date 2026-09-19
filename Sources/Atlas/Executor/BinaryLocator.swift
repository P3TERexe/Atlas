import Foundation

/// Absolute-path binary resolution shared by plugins and `ShellGuard`.
///
/// GUI-launched apps inherit an unpredictable `$PATH` (typically just
/// `/usr/bin:/bin:/usr/sbin:/sbin`), so bare binary names are never resolved
/// through the environment: only these fixed directories are probed, in order.
enum BinaryLocator {
    /// Directories probed in order; fixed by policy.
    static let searchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// Returns the first existing absolute path whose `lastPathComponent`
    /// equals `name`, or `nil` if no fixed directory contains it.
    /// Thread-safe and cached in memory. NEVER consults `$PATH`.
    static func locate(_ name: String) -> String? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                let path = candidate.path
                lock.lock()
                cache[name] = path
                lock.unlock()
                return path
            }
        }
        return nil
    }

    /// Clears the in-memory cache.
    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
