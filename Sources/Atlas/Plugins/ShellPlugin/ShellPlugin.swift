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
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
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
        
        // Handle ALL percent patterns like "15%" -> "(0.15)" FIRST, so the
        // phrase replacements below can no longer consume the '%' sign.
        if let regex = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)\\s*%") {
            var result = ""
            var cursor = s.startIndex
            regex.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { match, _, _ in
                guard let match, let numRange = Range(match.range(at: 1), in: s),
                      let val = Double(s[numRange]),
                      let fullRange = Range(match.range, in: s) else { return }
                result += s[cursor..<fullRange.lowerBound] + "(\(val / 100.0))"
                cursor = fullRange.upperBound
            }
            result += s[cursor...]
            s = result
        }
        
        // Phrase forms: "15 percent of 80", "15 per cento di 80"
        s = s.replacingOccurrences(of: " per cento di ", with: " * 0.01 * ")
            .replacingOccurrences(of: "% of ", with: " * 0.01 * ")
            .replacingOccurrences(of: "% di ", with: " * 0.01 * ")
        
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
        let tmpDir = FileManager.default.temporaryDirectory.path
        let backupRoot = BackupStore.defaultRoot().path
        
        var profile = """
        (version 1)(deny default)
        (allow process-exec (subpath "/usr/bin") (subpath "/bin") (subpath "/opt/homebrew/bin") (subpath "/usr/local/bin") (subpath "/sbin") (subpath "/usr/sbin"))
        (allow file-read*)
        (allow file-write* (subpath "\(workingDir.path)") (subpath "\(tmpDir)") (subpath "\(backupRoot)"))
        (allow process-fork)
        """
        if allowNetwork {
            profile += "\n(allow network*)"
        }
        profile += "\n"
        
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atlas-sandbox-\(UUID().uuidString).sbpl")
        try profile.write(to: url, atomically: true, encoding: .utf8)
        return url
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
    
    /// true se sandbox-exec esiste E applica davvero i filtri (subpath) di
    /// `file-write*` su questo sistema. Su alcune build recenti di macOS il
    /// binario c'è ma QUALUNQUE regola di scrittura filtrata nega la
    /// scrittura anche dentro le root consentite: in quel caso girare sotto
    /// sandbox romperebbe ogni comando. Rilevato UNA sola volta con un
    /// canary (scrittura in una directory temporanea) e messo in cache.
    static let sandboxUsable: Bool = {
        guard FileManager.default.fileExists(atPath: "/usr/bin/sandbox-exec") else { return false }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("atlas-sbx-probe-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return false }
        defer { try? fm.removeItem(at: dir) }
        
        let profileText = """
        (version 1)(deny default)
        (allow process-exec (subpath "/bin"))
        (allow file-read*)
        (allow file-write* (subpath "\(dir.resolvingSymlinksInPath().path)"))
        (allow process-fork)
        """
        let profile = dir.appendingPathComponent("probe.sbpl")
        guard (try? profileText.write(to: profile, atomically: true, encoding: .utf8)) != nil else { return false }
        defer { try? fm.removeItem(at: profile) }
        
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        probe.arguments = ["-f", profile.path, "/bin/sh", "-c", ": > out.txt"]
        probe.currentDirectoryURL = dir
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        guard (try? probe.run()) != nil else { return false }
        probe.waitUntilExit()
        return probe.terminationStatus == 0 && fm.fileExists(atPath: dir.appendingPathComponent("out.txt").path)
    }()
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
    
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let cmd = step.format ?? step.inputs.joined(separator: " ")
        
        // Snapshot directory contents before execution
        let beforeFiles = Set((try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil)) ?? [])
        
        // Sandbox: deny-write fuori dalla cartella di lavoro. Fallback
        // pre-deciso: senza /usr/bin/sandbox-exec, o su sistemi che ignorano/
        // negano i filtri di scrittura del profilo (sandboxUsable), si gira
        // senza sandbox — la allowlist di ShellGuard resta l'unico strato,
        // nessuna regressione funzionale.
        let executableURL: URL
        let arguments: [String]
        if Self.sandboxUsable {
            let profile = try ShellPlugin.makeSandboxProfile(
                workingDir: currentDirectory,
                allowNetwork: Self.needsNetwork(cmd)
            )
            defer { try? FileManager.default.removeItem(at: profile) }
            executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
            arguments = ["-f", profile.path, "/bin/zsh", "-c", cmd]
        } else {
            print("[Atlas][Shell] sandbox non disponibile o non efficace: esecuzione solo con allowlist")
            executableURL = URL(fileURLWithPath: "/bin/zsh")
            arguments = ["-c", cmd]
        }
        
        let result = try await AsyncProcessRunner.run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectory
        )
        
        guard result.isSuccess else {
            let errorMsg = result.stderr.isEmpty ? result.stdout : result.stderr
            throw ExecutorError.executionFailed("Comando shell fallito: \(errorMsg.isEmpty ? "Codice uscita \(result.exitCode)" : errorMsg)")
        }
        
        // Snapshot newly created files/directories
        let afterFiles = Set((try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil)) ?? [])
        let createdFiles = Array(afterFiles.subtracting(beforeFiles))
        
        return ActionResult(
            success: true,
            outputFiles: createdFiles,
            message: result.stdout.isEmpty ? "Comando eseguito con successo (\(createdFiles.count) nuovi elementi)" : result.stdout
        )
    }
}
