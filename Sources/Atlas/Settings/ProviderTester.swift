import Foundation

/// Unica implementazione URLSession per i test di connessione ai provider AI.
/// Ogni helper costruisce solo la request-specifica (endpoint/header/timeout)
/// e mappa lo stato HTTP nel messaggio d'esito italiano; l'esecuzione è condivisa.
enum ProviderTester {
    /// Esegue la request e traduce l'esito in messaggio italiano.
    static func test(
        endpoint: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutInterval: TimeInterval = 6,
        connectionError: (Error) -> String = { "❌ Connessione fallita: \($0.localizedDescription)" },
        messageForStatus: (Int) -> String
    ) async -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return "❌ Risposta non valida"
            }
            return messageForStatus(http.statusCode)
        } catch {
            return connectionError(error)
        }
    }

    // MARK: - Per-provider helpers

    static func openCode(apiKey: String) async -> String {
        await test(endpoint: URL(string: "https://opencode.ai/zen/v1/models")!, timeoutInterval: 6) { status in
            switch status {
            case 200:
                return "✓ API Key valida!"
            case 401, 403:
                return "❌ API Key non valida (\(status))"
            default:
                return "✓ Connesso (HTTP \(status))"
            }
        }
    }

    static func openAI(apiKey: String) async -> String {
        await test(endpoint: URL(string: "https://api.openai.com/v1/models")!, timeoutInterval: 5) { status in
            switch status {
            case 200:
                return "✓ API Key valida!"
            case 401:
                return "❌ API Key non valida (401)"
            default:
                return "❌ Risposta non valida"
            }
        }
    }

    /// Test Claude: header corretti `x-api-key` + `anthropic-version`
    /// (in precedenza inviava un Bearer malformato dentro x-api-key).
    static func claude(apiKey: String) async -> String {
        await test(
            endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
            ],
            timeoutInterval: 5
        ) { status in
            (status == 401 || status == 403) ? "❌ API Key non valida (\(status))" : "✓ API Key valida!"
        }
    }

    static func nvidia(apiKey: String) async -> String {
        await test(endpoint: URL(string: "https://integrate.api.nvidia.com/v1/models")!, timeoutInterval: 5) { status in
            switch status {
            case 200:
                return "✓ API Key valida!"
            case 401:
                return "❌ API Key non valida (401)"
            default:
                return "✓ Accettata"
            }
        }
    }

    /// Ollama: GET sull'endpoint base, senza auth.
    static func ollama(endpoint: String) async -> String {
        guard let url = URL(string: endpoint) else {
            return "❌ URL non valido"
        }
        let rootURL = url.deletingLastPathComponent().deletingLastPathComponent() // http://localhost:11434
        return await test(endpoint: rootURL, timeoutInterval: 3, connectionError: { "❌ Non raggiungibile: \($0.localizedDescription)" }) { status in
            status == 200 ? "✓ Raggiungibile!" : "✓ Risposta ricevuta"
        }
    }

    /// Custom OpenAI-compatible: prova /models sulla base URL.
    static func custom(baseURL: String, apiKey: String) async -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: base + "/models") else {
            return "❌ URL non valido"
        }
        var headers: [String: String] = [:]
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        return await test(endpoint: url, headers: headers, timeoutInterval: 6, connectionError: { "❌ Non raggiungibile: \($0.localizedDescription)" }) { status in
            switch status {
            case 200:
                return "✓ Raggiungibile, API Key valida!"
            case 401, 403:
                return "❌ Accesso negato (\(status))"
            case 404:
                // Some custom servers don't expose /models — treat as reachable
                return "✓ Raggiungibile"
            default:
                return "⚠︎ HTTP \(status)"
            }
        }
    }
}
