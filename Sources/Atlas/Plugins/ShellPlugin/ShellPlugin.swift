import Foundation

class ShellPlugin: AtlasPlugin {
    let id = "shell"
    
    var capabilities: [ToolCapability] {
        [
            ToolCapability(
                id: "shell.calc",
                description: "Evaluates mathematical expressions using macOS native 'bc' calculator (e.g. '15% of 85.99', 'sqrt(1764)', '5 * 12')",
                inputFormats: [],
                outputFormats: [],
                executor: CalcShellAction()
            ),
            ToolCapability(
                id: "shell.run",
                description: "Executes a transparent CLI terminal command (e.g. ffmpeg, sips, zip, git, curl)",
                inputFormats: [],
                outputFormats: [],
                executor: GenericShellAction()
            )
        ]
    }
}

// MARK: - Calculator Action via `bc`

final class CalcShellAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        guard step.format != nil || !step.inputs.isEmpty else {
            throw ExecutorError.validationFailed("Espressione matematica non specificata.")
        }
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let expr = step.format ?? step.inputs.joined(separator: " ")
        let cleanExpr = Self.sanitizeBcExpression(expr)
        return ["echo \"\(cleanExpr)\" | bc -l"]
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        let rawExpr = step.format ?? step.inputs.joined(separator: " ")
        let expr = Self.sanitizeBcExpression(rawExpr)
        
        let result = try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/bc"),
            arguments: ["-l"],
            stdin: "\(expr)\n".data(using: .utf8)
        )
        
        guard result.isSuccess && !result.stdout.isEmpty else {
            throw ExecutorError.executionFailed("Errore calcolo per '\(expr)': \(result.stderr)")
        }
        
        return ActionResult(
            success: true,
            outputFiles: [],
            message: "Risultato: \(rawExpr) = \(result.stdout)"
        )
    }
    
    /// Visible for testing (internal).
    static func sanitizeBcExpression(_ input: String) -> String {
        var s = input.lowercased()
            .replacingOccurrences(of: "×", with: "*")
        
        // Replace only STANDALONE 'x' (multiplication sign), not 'x' inside
        // words or hexadecimal notation.
        if let regex = try? NSRegularExpression(pattern: "(?<=[\\d\\s)])x(?=[\\d\\s(]|$)") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "*")
        }
        
        // Consume the complete numeric phrase before isolated percentages.
        // Keep division in bc rather than rounding through a Double.
        let number = "([+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+))"
        let phrase = "^\\s*" + number + "\\s*(?:%\\s*(?:of|di)|(?:percent of|per cento di))\\s*" + number + "\\s*$"
        if let regex = try? NSRegularExpression(pattern: phrase),
           regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
            return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "($1/100)*($2)")
        }
        // Do not reinterpret incomplete or qualified natural-language phrases.
        if s.range(of: "\\b(?:of|di|percent|per cento)\\b", options: .regularExpression) != nil ||
            (s.contains("%") && s.range(of: "[A-Za-z]", options: .regularExpression) != nil) {
            return input
        }
        if let regex = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])" + number + "\\s*%") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "($1/100)")
        }
        
        return s
    }
}

// MARK: - Generic Shell Action

/// Token-aware safety analysis for `shell.run`. A plain substring blocklist is
/// trivially bypassed (`rm -fr /`, `find -delete`, `curl | sh`, ...), so the
/// command is split into pipelines/segments and each segment's binary and
/// flags are inspected.
enum ShellGuard {
    /// Binaries that must never run from Atlas (system control, process
    /// management, arbitrary script execution).
    private static let forbiddenBinaries: Set<String> = [
        "sudo", "su", "doas", "shutdown", "reboot", "halt", "launchctl",
        "killall", "pkill", "kill", "osascript", "osacompile",
        "dd", "mkfs", "diskutil", "hdiutil", "csrutil", "nvram"
    ]

    /// Binari ammessi come primo token di un segmento. Tutto il resto è bloccato.
    /// Interpreti (sh/bash/zsh/python/perl/ruby/swift/tclsh) e wrapper
    /// (env/nice/nohup/command/exec/time/xargs/find) volutamente ASSENTI:
    /// permetterli reintrodurrebbe l'evasione da wrapper.
    private static let allowedSegmentLeaders: Set<String> =
        ["ffmpeg","ffprobe","magick","convert","sips","zip","unzip","bc",
         "git","curl","wget","ping","sqlite3","afconvert","mdls","mdfind",
         "plutil","textutil","ditto","tar","gs","python3"]
    
    /// Error thrown when a command fails the safety analysis.
    struct BlockedError: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    
    static func validate(_ rawCommand: String) throws {
        // Normalize: strip quotes/backticks for analysis, collapse whitespace,
        // lowercase. Command substitution is rejected outright: the payload of
        // $(...) or `...` would evade per-segment analysis.
        let lower = rawCommand.lowercased()
        if lower.contains("$(") || lower.contains("`") {
            throw BlockedError(reason: "Comando bloccato: la sostituzione di comandi ($(...) o backtick) non è consentita da Atlas.")
        }
        
        // Pipe-to-shell patterns (curl/wget ... | sh|bash|zsh|python|perl|ruby)
        if let regex = try? NSRegularExpression(pattern: "(?:curl|wget)[^|;]*\\|\\s*(?:ba)?(?:z)?sh\\b|(?:curl|wget)[^|;]*\\|\\s*(?:python3?|perl|ruby)\\b") {
            if regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                throw BlockedError(reason: "Comando bloccato: l'esecuzione di script scaricati dalla rete (pipe verso una shell) non è consentita da Atlas.")
            }
        }
        
        // Download-then-execute: una scrittura su disco della rete seguita
        // dall'esecuzione di un interprete/shell sul file scaricato
        // (`curl url > x.py && python3 x.py`) è l'equivalente senza pipe del
        // pattern sopra e viene bloccata allo stesso modo.
        if let regex = try? NSRegularExpression(pattern: "(?:curl|wget)\\b[^;&|\n]*>[^;&|\n]*[;&][^\\n]*(?:python3?|perl|ruby|(?:ba|z)?sh)\\b") {
            if regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) != nil {
                throw BlockedError(reason: "Comando bloccato: scaricare ed eseguire codice dalla rete non è consentito da Atlas.")
            }
        }
        
        let segments = splitIntoSegments(lower)
        for segment in segments {
            try validateSegment(segment)
        }
    }
    
    static func splitIntoSegments(_ cmd: String) -> [String] {
        cmd.split(whereSeparator: { ";&|\n".contains($0) })
           .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
           .filter { !$0.isEmpty }
    }
    
    private static func validateSegment(_ segment: String) throws {
        // Whitespace-aware tokenization: tab/newline separators must not fuse
        // tokens (`sudo\trm -rf /` deve vedersi come leader `sudo`).
        let tokens = segment
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
        guard let binaryToken = tokens.first else { return }
        let binary = URL(fileURLWithPath: binaryToken).lastPathComponent
        let args = Array(tokens.dropFirst())
        
        // Allowlist chiusa: il primo token di ogni segmento deve essere un
        // binario ammesso. Interpreti e wrapper restano fuori per design.
        guard allowedSegmentLeaders.contains(binary) else {
            throw BlockedError(reason: "Comando '\(binary)' non consentito.")
        }
        
        guard !forbiddenBinaries.contains(binary) else {
            throw BlockedError(reason: "Comando bloccato per la tua sicurezza: '\(binary)' non è consentito da Atlas.")
        }
        
        switch binary {
        case "rm":
            let flags = args.filter { $0.hasPrefix("-") }.joined()
            let hasRecursive = flags.contains("r") || args.contains("--recursive")
            let hasForce = flags.contains("f") || args.contains("--force")
            let targets = args.filter { !$0.hasPrefix("-") }
            
            if hasRecursive && hasForce {
                throw BlockedError(reason: "Comando bloccato per la tua sicurezza: 'rm' ricorsivo e forzato (-rf) non è consentito da Atlas. Usa la funzione 'Cestino' (file.trash).")
            }
            // Block rm targeting absolute paths outside the working directory or home-relative paths
            for target in targets {
                if target == "/" || target == "~" || target.hasPrefix("~/") || target.hasPrefix("$home") || target.hasPrefix("/users/") || target == ".." || target.hasPrefix("../") || target.contains("/../") || target.contains("${") {
                    throw BlockedError(reason: "Comando bloccato per la tua sicurezza: 'rm' su percorsi assoluti o home non è consentito da Atlas.")
                }
                if hasRecursive && target.contains("*") {
                    throw BlockedError(reason: "Comando bloccato per la tua sicurezza: 'rm' ricorsivo con glob non è consentito da Atlas.")
                }
            }
            
        case "find":
            // `find -delete` distrugge senza conferma: qualunque invocazione
            // con quel flag è respinta.
            if args.contains("-delete") {
                throw BlockedError(reason: "Comando bloccato per la tua sicurezza: 'find -delete' non è consentito da Atlas.")
            }
            
        case "python3":
            // `python3 -c '...'` è esecuzione di codice arbitrario: solo lo
            // script su file resta ammesso.
            if args.contains(where: { $0 == "-c" || $0.hasPrefix("-c") }) {
                throw BlockedError(reason: "Comando bloccato per la tua sicurezza: 'python3 -c' non è consentito da Atlas.")
            }
            
        case "mv":
            // mv of home or absolute root-level targets can destroy data
            let targets = args.filter { !$0.hasPrefix("-") }
            if targets.contains("~") || targets.contains("/") || targets.contains(where: { $0 == "/users" || ($0.hasPrefix("/users/") && $0.split(separator: "/").count <= 3) }) {
                throw BlockedError(reason: "Comando bloccato per la tua sicurezza: spostamenti su percorsi di sistema/home non sono consentiti da Atlas.")
            }
            
        case "chmod", "chown", "chflags":
            if args.contains(where: { $0.contains("r") && $0.hasPrefix("-") }), args.last == "/" || args.last == "~" {
                throw BlockedError(reason: "Comando bloccato per la tua sicurezza: cambio ricorsivo di permessi sulla radice/home non è consentito da Atlas.")
            }
            
        default:
            break
        }
        
        // Redirect analysis on EVERY '>' run (not just the first): target is
        // the text after the last '>' of the run; block system/home/variable
        // expansion targets.
        if let regex = try? NSRegularExpression(pattern: ">+") {
            let range = NSRange(segment.startIndex..., in: segment)
            for match in regex.matches(in: segment, range: range) {
                guard let matchRange = Range(match.range, in: segment) else { continue }
                var target = segment[matchRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                target = target.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if target == "/" || target.hasPrefix("/users/") || target.hasPrefix("~") || target.contains("${") {
                    throw BlockedError(reason: "Comando bloccato per la tua sicurezza: redirezione verso percorsi di sistema/home non è consentita da Atlas.")
                }
            }
        }
    }
    
    /// true sse nessun leader del comando è distruttivo e non compaiono
    /// redirezioni. Usata dal downgrade conservativo del rischio in
    /// `RiskAssessment` per `shell.run`.
    static func classify(_ cmd: String) -> Bool {
        let lower = cmd.lowercased()
        if lower.contains(">") { return false }
        let destructiveLeaders: Set<String> = ["rm", "mv", "chmod", "chown", "dd", "find"]
        return splitIntoSegments(lower).allSatisfy { segment in
            guard let first = segment
                .components(separatedBy: .whitespacesAndNewlines)
                .first(where: { !$0.isEmpty }) else { return true }
            let leader = URL(fileURLWithPath: first).lastPathComponent
            return !destructiveLeaders.contains(leader)
        }
    }
}

extension ShellPlugin {
    /// Scrive un profilo SBPL temporaneo e ritorna il suo path.
    /// Write permesso SOLO sotto workingDir (+ subpath), TMPDIR e
    /// BackupStore.defaultRoot(). Lettura ampia. Network negato di default;
    /// profilo "online" solo se qualche leader ∈ {curl, wget, ping}.
    static func makeSandboxProfile(workingDir: URL, allowNetwork: Bool) throws -> URL {
        let profile = sandboxProfileText(
            writeDirectories: [workingDir, FileManager.default.temporaryDirectory, BackupStore.rootOverride ?? BackupStore.defaultRoot()],
            allowNetwork: allowNetwork
        )
        
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-sandbox-\(UUID().uuidString).sbpl")
        try profile.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func sandboxProfileText(writeDirectories: [URL], allowNetwork: Bool) -> String {
        let roots = writeDirectories.map { directory in
            let escapedPath = directory.resolvingSymlinksInPath().path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "(subpath \"\(escapedPath)\")"
        }.joined(separator: " ")
        var profile = """
        (version 1)(deny default)
        (allow process-exec (subpath "/usr/bin") (subpath "/bin") (subpath "/opt/homebrew/bin") (subpath "/usr/local/bin") (subpath "/sbin") (subpath "/usr/sbin"))
        (allow file-read*)
        (allow file-write* \(roots))
        (allow process-fork)
        """
        if allowNetwork { profile += "\n(allow network*)" }
        return profile + "\n"
    }
}

final class GenericShellAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        let cmd = step.format ?? step.inputs.joined(separator: " ")
        guard !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutorError.validationFailed("Comando shell non specificato.")
        }
        
        do {
            try ShellGuard.validate(cmd)
        } catch let error as ShellGuard.BlockedError {
            throw ExecutorError.validationFailed(error.reason)
        }
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let cmd = step.format ?? step.inputs.joined(separator: " ")
        return [cmd]
    }
    
    /// true sse qualche leader del comando richiede rete (curl, wget, ping).
    private static func needsNetwork(_ cmd: String) -> Bool {
        let networkLeaders: Set<String> = ["curl", "wget", "ping"]
        return ShellGuard.splitIntoSegments(cmd.lowercased()).contains { segment in
            guard let first = segment
                .components(separatedBy: .whitespacesAndNewlines)
                .first(where: { !$0.isEmpty }) else { return false }
            return networkLeaders.contains(URL(fileURLWithPath: first).lastPathComponent)
        }
    }
    
    /// A single off-main probe checks both permitted writes and confinement.
    /// Callers share its bounded lifetime rather than cancelling each other's probe.
    private static let sandboxProbe = Task.detached(priority: .utility) { () -> Bool in
        let fm = FileManager.default
        let sandboxURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        guard fm.isExecutableFile(atPath: sandboxURL.path) else { return false }

        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        do {
            let allowed = root.appendingPathComponent("allowed", isDirectory: true)
            let denied = root.appendingPathComponent("denied", isDirectory: true)
            try fm.createDirectory(at: allowed, withIntermediateDirectories: true)
            try fm.createDirectory(at: denied, withIntermediateDirectories: true)
            let protectedFile = denied.appendingPathComponent("sentinel.txt")
            let sentinel = Data("Atlas sandbox probe sentinel".utf8)
            try sentinel.write(to: protectedFile)

            let profile = root.appendingPathComponent("probe.sbpl")
            let profileText = ShellPlugin.sandboxProfileText(writeDirectories: [allowed], allowNetwork: false)
            try profileText.write(to: profile, atomically: true, encoding: .utf8)

            let permitted = try await AsyncProcessRunner.run(
                executableURL: sandboxURL,
                arguments: ["-f", profile.path, "/bin/zsh", "-c", "printf atlas > out.txt"],
                currentDirectoryURL: allowed,
                timeout: 5
            )
            guard permitted.isSuccess,
                  try Data(contentsOf: allowed.appendingPathComponent("out.txt")) == Data("atlas".utf8) else {
                return false
            }

            let prohibited = try await AsyncProcessRunner.run(
                executableURL: sandboxURL,
                arguments: ["-f", profile.path, "/bin/zsh", "-c", "printf changed > sentinel.txt"],
                currentDirectoryURL: denied,
                timeout: 5
            )
            let retainedContent = (try? Data(contentsOf: protectedFile)) ?? Data()
            return !prohibited.isSuccess && retainedContent == sentinel
        } catch {
            return false
        }
    }

    static var sandboxUsable: Bool {
        get async { await sandboxProbe.value }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        try Task.checkCancellation()
        try validate(step: step, context: context)
    
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let cmd = step.format ?? step.inputs.joined(separator: " ")
        
        // This difference is only for displaying new outputs, not a complete undo journal.
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil)) ?? [])
        
        var profileURL: URL?
        defer {
            if let profileURL { try? FileManager.default.removeItem(at: profileURL) }
        }
        let sandboxAvailable = await Self.sandboxUsable
        try Task.checkCancellation()
        guard sandboxAvailable else {
            throw ExecutorError.executionFailed("Esecuzione shell non disponibile: sandbox non efficace su questo sistema.")
        }
        let profile = try ShellPlugin.makeSandboxProfile(
            workingDir: currentDirectory,
            allowNetwork: Self.needsNetwork(cmd)
        )
        profileURL = profile
        let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let arguments = ["-f", profile.path, "/bin/zsh", "-c", cmd]
        
        let undoMessage = "Undo non disponibile per questo comando shell"
        do {
            let result = try await AsyncProcessRunner.run(
                executableURL: executableURL,
                arguments: arguments,
                currentDirectoryURL: currentDirectory
            )

            guard result.isSuccess else {
                let errorMsg = result.stderr.isEmpty ? result.stdout : result.stderr
                throw ExecutorError.executionFailed("Comando shell fallito: \(errorMsg.isEmpty ? "Codice uscita \(result.exitCode)" : errorMsg)")
            }

            let afterFiles = Set((try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil)) ?? [])
            let createdFiles = Array(afterFiles.subtracting(beforeFiles))
            let outputMessage = result.stdout.isEmpty ? "Comando eseguito con successo (\(createdFiles.count) nuovi elementi)" : result.stdout

            return ActionResult(
                success: true,
                outputFiles: createdFiles,
                message: "\(outputMessage)\n\(undoMessage)",
                undoSupported: false
            )
        } catch {
            let afterFiles = Set((try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil)) ?? [])
            throw ActionExecutionError(
                underlying: error,
                partialResult: ActionResult(
                    success: false,
                    outputFiles: Array(afterFiles.subtracting(beforeFiles)),
                    message: undoMessage,
                    undoSupported: false
                )
            )
        }
    }
}
