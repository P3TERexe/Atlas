import Foundation
import FoundationModels

struct ActionGraph: Codable, Sendable {
    var steps: [ActionStep]

    init(steps: [ActionStep]) {
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey {
        case steps
        case actionGraph
        case graph
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            for key in [CodingKeys.steps, .actionGraph, .graph] where container.contains(key) {
                self.steps = try container.decode([ActionStep].self, forKey: key)
                return
            }
            self.steps = try container.decode([ActionStep].self, forKey: .steps)
        } else {
            let container = try decoder.singleValueContainer()
            self.steps = try container.decode([ActionStep].self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
    }


    
    /// Topologically sorts the steps by their `dependsOn` constraints
    /// (Kahn's algorithm). Throws on unknown dependencies or cycles.
    func topologicallySorted() throws -> ActionGraph {
        // Difensiva: id duplicati renderebbero ambiguo il grafo (e farebbero
        // crashare Dictionary(uniqueKeysWithValues:) più sotto).
        var seenIDs = Set<String>()
        for step in steps {
            guard seenIDs.insert(step.id).inserted else {
                throw ExecutorError.validationFailed("ID passo duplicato: \(step.id)")
            }
        }

        var inDegree: [String: Int] = [:]
        var edges: [String: [String]] = [:]

        for step in steps {
            inDegree[step.id] = 0
        }
        
        for step in steps {
            for dep in step.dependsOn ?? [] {
                guard inDegree[dep] != nil else {
                    throw ExecutorError.validationFailed(
                        "Lo step '\(step.id)' dipende da uno step sconosciuto: \(dep)"
                    )
                }
                edges[dep, default: []].append(step.id)
                inDegree[step.id, default: 0] += 1
            }
        }
        
        // Ready queue: steps with no remaining dependencies, in original order
        var ready: [String] = steps.compactMap { (inDegree[$0.id] ?? 0) == 0 ? $0.id : nil }
        var order: [String] = []
        order.reserveCapacity(steps.count)
        
        var index = 0
        while index < ready.count {
            let current = ready[index]
            index += 1
            order.append(current)
            for next in edges[current] ?? [] {
                inDegree[next, default: 0] -= 1
                if inDegree[next, default: 0] == 0 {
                    ready.append(next)
                }
            }
        }
        
        guard order.count == steps.count else {
            throw ExecutorError.validationFailed("Rilevato un ciclo nelle dipendenze degli step (DAG non valido).")
        }
        
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = steps.sorted { position[$0.id] ?? order.count < position[$1.id] ?? order.count }
        return ActionGraph(steps: sorted)
    }
}

struct ActionStep: Codable, Sendable {
    var id: String
    var tool: String
    var inputs: [String]
    var format: String?
    var grayscale: Bool?
    var quality: Int?
    var dependsOn: [String]?



    enum CodingKeys: String, CodingKey {
        case id, tool, inputs, format, grayscale, quality, dependsOn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.tool = try container.decode(String.self, forKey: .tool)
        
        if let singleInput = try? container.decode(String.self, forKey: .inputs) {
            self.inputs = [singleInput]
        } else {
            self.inputs = try container.decode([String].self, forKey: .inputs)
        }

        self.format = try container.decodeIfPresent(String.self, forKey: .format)
        self.grayscale = try container.decodeIfPresent(Bool.self, forKey: .grayscale)
        self.quality = try container.decodeIfPresent(Int.self, forKey: .quality)

        if let singleDep = try? container.decode(String.self, forKey: .dependsOn) {
            self.dependsOn = [singleDep]
        } else {
            self.dependsOn = try container.decodeIfPresent([String].self, forKey: .dependsOn)
        }
    }

    init(id: String, tool: String, inputs: [String] = [], format: String? = nil,
         grayscale: Bool? = nil, quality: Int? = nil, dependsOn: [String]? = nil) {
        self.id = id
        self.tool = tool
        self.inputs = inputs
        self.format = format
        self.grayscale = grayscale
        self.quality = quality
        self.dependsOn = dependsOn
    }
    
    /// Declared extension-conversion output; other tools do not declare a filename here.
    /// Returning the input unchanged means no distinct output can be predicted.
    func outputName(for input: String) -> String {
        if tool == "image.convert" && grayscale == true {
            let base = (input as NSString).deletingPathExtension
            let ext = format ?? (input as NSString).pathExtension
            return base + "_bw." + ext
        }
        guard ["image.convert", "video.convert", "video.extractAudio"].contains(tool),
              let format, !format.isEmpty, !format.contains("/"), !format.contains(".") else { return input }
        return (input as NSString).deletingPathExtension + "." + format
    }
}

// MARK: - Generable Conformance (macOS 26.0+)

@available(macOS 26.0, *)
extension ActionGraph: Generable {
    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: ActionGraph.self,
            description: "Action plan for filesystem operations",
            properties: [
                .init(name: "steps", description: "Ordered list of actions to execute on the filesystem", type: [ActionStep].self)
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.steps = try content.value([ActionStep].self, forProperty: "steps")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["steps": steps])
    }
}

@available(macOS 26.0, *)
extension ActionStep: Generable {
    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: ActionStep.self,
            description: "A single action to execute",
            properties: [
                .init(name: "id", description: "Unique step identifier, e.g. step_1", type: String.self),
                .init(name: "tool", description: "Tool ID to use, e.g. image.convert, file.rename, file.compress", type: String.self),
                .init(name: "inputs", description: "Input filenames relative to the current directory", type: [String].self),
                .init(name: "format", description: "Output format, e.g. webp, jpg, png. Nil if not applicable.", type: String?.self),
                .init(name: "grayscale", description: "Set to true to convert the image to black & white / grayscale.", type: Bool?.self),
                .init(name: "quality", description: "Output quality from 1 to 100. Nil for default.", type: Int?.self),
                .init(name: "dependsOn", description: "Step IDs this step depends on. Nil if no dependencies.", type: [String]?.self)
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        self.id = try content.value(String.self, forProperty: "id")
        self.tool = try content.value(String.self, forProperty: "tool")
        self.inputs = try content.value([String].self, forProperty: "inputs")
        self.format = try content.value(String?.self, forProperty: "format")
        self.grayscale = try content.value(Bool?.self, forProperty: "grayscale")
        self.quality = try content.value(Int?.self, forProperty: "quality")
        self.dependsOn = try content.value([String]?.self, forProperty: "dependsOn")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "id": id,
            "tool": tool,
            "inputs": inputs,
            "format": format,
            "grayscale": grayscale,
            "quality": quality,
            "dependsOn": dependsOn
        ])
    }
}
