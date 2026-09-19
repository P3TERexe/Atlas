import Foundation

enum PlanValidationError: Error, LocalizedError {
    case emptyPlan
    case toolNotFound(String)
    case formatMismatch(expected: String, found: String?)
    case grayscaleMissing
    case noMatchingFiles(tool: String, expectedType: String)
    case intentMismatch(String)

    var errorDescription: String? {
        switch self {
        case .emptyPlan:
            return "L'AI ha generato un piano vuoto (0 step)."
        case .toolNotFound(let tool):
            return "Il piano generato richiede un tool non esistente: '\(tool)'."
        case .formatMismatch(let expected, let found):
            return "Richiesta per formato '\(expected)', ma l'AI ha impostato '\(found ?? "nessuno")'."
        case .grayscaleMissing:
            return "Richiesta conversione in Bianco e Nero, ma il flag 'grayscale' non è stato impostato."
        case .noMatchingFiles(let tool, let expectedType):
            return "Il comando '\(tool)' richiede file \(expectedType), ma non ne sono stati trovati nel contesto."
        case .intentMismatch(let reason):
            return "Verifica piano fallita: \(reason)"
        }
    }
}

struct PlanValidator {
    /// Checks tools, graph structure and inputs. Only complete local phrases
    /// have a canonical intent; arbitrary natural language is not inferred.
    @MainActor
    static func validate(graph: ActionGraph, query: String, context: FinderContext) throws {
        guard !graph.steps.isEmpty else { throw PlanValidationError.emptyPlan }
        let sorted = try graph.topologicallySorted()
        for step in sorted.steps {
            guard ToolRegistry.shared.capability(for: step.tool) != nil else {
                throw PlanValidationError.toolNotFound(step.tool)
            }
        }

        // Each entry contains only outputs declared by extension conversions
        // and their ancestors. Rename/copy formats are not output extensions.
        var availableOutputs: [String: Set<URL>] = [:]
        for step in sorted.steps {
            guard let capability = ToolRegistry.shared.capability(for: step.tool) else { continue }
            let predecessors = (step.dependsOn ?? []).reduce(into: Set<URL>()) {
                $0.formUnion(availableOutputs[$1] ?? [])
            }
            if step.tool.hasPrefix("shell.") {
                try capability.executor.validate(step: step, context: context)
                availableOutputs[step.id] = predecessors
                continue
            }
            let extensions: Set<String>? = capability.inputFormats.isEmpty || capability.inputFormats.contains("*") ? nil : Set(capability.inputFormats)
            let allowDirectories = ["file.zip", "file.compress", "file.select", "file.trash", "file.move"].contains(step.tool)
            var inputs: [URL] = []
            var hasFutureInput = false
            if step.inputs.isEmpty {
                if step.tool == "file.mkdir" {
                    // file.mkdir does not require inputs
                } else if step.dependsOn != nil && !step.dependsOn!.isEmpty {
                    // Depends on predecessor step outputs
                    hasFutureInput = true
                } else {
                    inputs = try InputResolver.resolve(step: step, context: context, extensions: extensions, allowDirectories: allowDirectories)
                }
            } else {
                for input in step.inputs {
                    let url = try inputURL(input, context: context)
                    if !FileManager.default.fileExists(atPath: url.path), predecessors.contains(url) {
                        guard extensions == nil || extensions!.contains(url.pathExtension.lowercased()) else {
                            throw PlanValidationError.intentMismatch("Output precedente di tipo incompatibile: \(input)")
                        }
                        hasFutureInput = true
                        inputs.append(url)
                    } else {
                        var single = step
                        single.inputs = [input]
                        inputs += try InputResolver.resolve(step: single, context: context, extensions: extensions, allowDirectories: allowDirectories)
                    }
                }
            }
            if !hasFutureInput {
                try capability.executor.validate(step: step, context: context)
            }
            if ["image.convert", "video.convert", "video.extractAudio"].contains(step.tool),
               let format = step.format, !capability.outputFormats.contains(format.lowercased()) {
                throw PlanValidationError.intentMismatch("Formato non supportato da '\(step.tool)': \(format)")
            }
            var declared = predecessors
            if step.tool == "file.mkdir", let folderName = step.format, let dir = context.currentDirectory {
                declared.insert(dir.appendingPathComponent(folderName).standardizedFileURL)
            }
            for input in inputs {
                let output = step.outputName(for: input.path)
                if output != input.path {
                    declared.insert(URL(fileURLWithPath: output).standardizedFileURL)
                }
            }
            availableOutputs[step.id] = declared
        }
    }

    private static func inputURL(_ input: String, context: FinderContext) throws -> URL {
        if let url = URL(string: input), url.isFileURL { return url.standardizedFileURL }
        if input.hasPrefix("/") { return URL(fileURLWithPath: input).standardizedFileURL }
        guard let directory = context.currentDirectory else {
            throw PlanValidationError.intentMismatch("Cartella corrente non disponibile per '\(input)'.")
        }
        return directory.appendingPathComponent(input).standardizedFileURL
    }
}
