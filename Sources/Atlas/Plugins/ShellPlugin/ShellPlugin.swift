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
        let cleanExpr = sanitizeBcExpression(expr)
        return ["echo \"\(cleanExpr)\" | bc -l"]
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let rawExpr = step.format ?? step.inputs.joined(separator: " ")
        let expr = sanitizeBcExpression(rawExpr)
        
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
    
    private func sanitizeBcExpression(_ input: String) -> String {
        var s = input.lowercased()
            .replacingOccurrences(of: "% of ", with: " * 0.01 * ")
            .replacingOccurrences(of: "% di ", with: " * 0.01 * ")
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "x", with: "*")
        
        // Handle basic percent string like "15% of 80" -> "80 * 0.15"
        if let range = s.range(of: "%") {
            let numPart = s[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if let val = Double(numPart) {
                s = s.replacingOccurrences(of: "\(numPart)%", with: "(\(val / 100.0))")
            }
        }
        
        return s
    }
}

// MARK: - Generic Shell Action

final class GenericShellAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        let cmd = step.format ?? step.inputs.joined(separator: " ")
        guard !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutorError.validationFailed("Comando shell non specificato.")
        }
        
        let lower = cmd.lowercased()
        let forbidden = ["sudo ", "rm -rf /", "rm -rf ~", "rm -rf *", "mkfs", "dd if=", "> /dev/sd", ":(){ :|:& };:"]
        for bad in forbidden {
            if lower.contains(bad) {
                throw ExecutorError.validationFailed("Comando bloccato per la tua sicurezza: l'esecuzione di '\(bad.trimmingCharacters(in: .whitespaces))' non è consentita da Atlas.")
            }
        }
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let cmd = step.format ?? step.inputs.joined(separator: " ")
        return [cmd]
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        guard let currentDirectory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let cmd = step.format ?? step.inputs.joined(separator: " ")
        
        let result = try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", cmd],
            currentDirectoryURL: currentDirectory
        )
        
        guard result.isSuccess else {
            throw ExecutorError.executionFailed("Comando fallito: \(result.stderr)")
        }
        
        return ActionResult(
            success: true,
            outputFiles: [],
            message: result.stdout.isEmpty ? "Comando eseguito con successo" : result.stdout
        )
    }
}
