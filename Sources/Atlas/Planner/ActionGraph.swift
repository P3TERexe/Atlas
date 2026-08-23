import Foundation
import FoundationModels

struct ActionGraph: Codable, Sendable, Generable {
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
            if let steps = try? container.decode([ActionStep].self, forKey: .steps) {
                self.steps = steps
                return
            }
            if let steps = try? container.decode([ActionStep].self, forKey: .actionGraph) {
                self.steps = steps
                return
            }
            if let steps = try? container.decode([ActionStep].self, forKey: .graph) {
                self.steps = steps
                return
            }
        }
        
        if let singleContainer = try? decoder.singleValueContainer(),
           let steps = try? singleContainer.decode([ActionStep].self) {
            self.steps = steps
            return
        }
        
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.steps = try container.decode([ActionStep].self, forKey: .steps)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(steps, forKey: .steps)
    }

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

struct ActionStep: Codable, Sendable, Generable {
    var id: String
    var tool: String
    var inputs: [String]
    var format: String?
    var grayscale: Bool?
    var quality: Int?
    var dependsOn: [String]?

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

    enum CodingKeys: String, CodingKey {
        case id, tool, inputs, format, grayscale, quality, dependsOn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.tool = try container.decode(String.self, forKey: .tool)
        
        if let inputArray = try? container.decode([String].self, forKey: .inputs) {
            self.inputs = inputArray
        } else if let singleInput = try? container.decode(String.self, forKey: .inputs) {
            self.inputs = [singleInput]
        } else {
            self.inputs = []
        }
        
        self.format = try? container.decode(String.self, forKey: .format)
        self.grayscale = try? container.decode(Bool.self, forKey: .grayscale)
        self.quality = try? container.decode(Int.self, forKey: .quality)
        
        if let depArray = try? container.decode([String].self, forKey: .dependsOn) {
            self.dependsOn = depArray
        } else if let singleDep = try? container.decode(String.self, forKey: .dependsOn) {
            self.dependsOn = [singleDep]
        } else {
            self.dependsOn = nil
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
    
    /// Output filename for an input (same directory), e.g. "foto.png" → "foto.jpg".
    /// Returns the input unchanged when no output format is set.
    func outputName(for input: String) -> String {
        guard let format else { return input }
        return (input as NSString).deletingPathExtension + "." + format
    }
}
