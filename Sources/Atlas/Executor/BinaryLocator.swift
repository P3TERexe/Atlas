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

    /// Returns the first existing absolute path whose `lastPathComponent`
    /// equals `name`, or `nil` if no fixed directory contains it.
    /// NEVER consults `$PATH`.
    static func locate(_ name: String) -> String? {
        for directory in searchDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
