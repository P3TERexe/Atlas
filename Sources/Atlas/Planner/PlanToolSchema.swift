import Foundation

// MARK: - Piano come tool nativo

/// Schema JSON del piano d'azione esposto ai provider LLM come funzione
/// (`submit_plan`). I campi rispecchiano 1:1 `ActionStep` (ActionGraph.swift),
/// così il leniente `ActionGraph.init(from:)` decodifica i payload senza adattamenti.
enum PlanToolSchema {
    static let functionName = "submit_plan"
    static let description = "Restituisce il piano d'azione per la richiesta dell'utente."

    /// JSON-Schema (convenzione OpenAI) dei parametri della funzione.
    /// `tool.enum` è popolato dai tool realmente registrati, passati dal chiamante.
    static func parametersJSON(toolIds: [String]) -> [String: Any] {
        return [
            "type": "object",
            "properties": [
                "steps": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": ["type": "string"],
                            "tool": ["type": "string", "enum": toolIds],
                            "inputs": ["type": "array", "items": ["type": "string"]],
                            "format": ["type": "string"],
                            "grayscale": ["type": "boolean"],
                            "quality": ["type": "integer"],
                            "dependsOn": ["type": "array", "items": ["type": "string"]]
                        ],
                        "required": ["id", "tool", "inputs"]
                    ]
                ]
            ],
            "required": ["steps"]
        ]
    }

    /// Versione serializzata per `input_schema` (Anthropic) e `format` (Ollama).
    static func parametersData(toolIds: [String]) throws -> Data {
        let json = parametersJSON(toolIds: toolIds)
        do {
            return try JSONSerialization.data(withJSONObject: json)
        } catch {
            throw PlannerError.decodingFailed("Impossibile serializzare lo schema del piano: \(error.localizedDescription)")
        }
    }
}
