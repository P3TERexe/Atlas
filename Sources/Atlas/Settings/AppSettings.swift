import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    
    @Published var keychainError: String? = nil
    
    @Published var openAIApiKey: String = "" {
        didSet {
            scheduleKeychainSave(key: "openai_api_key", newValue: openAIApiKey, errorMessage: "Impossibile salvare la chiave OpenAI nel Keychain.")
        }
    }
    
    @Published var claudeApiKey: String = "" {
        didSet {
            scheduleKeychainSave(key: "claude_api_key", newValue: claudeApiKey, errorMessage: "Impossibile salvare la chiave Claude nel Keychain.")
        }
    }
    
    @Published var nvidiaApiKey: String = "" {
        didSet {
            scheduleKeychainSave(key: "nvidia_api_key", newValue: nvidiaApiKey, errorMessage: "Impossibile salvare la chiave NVIDIA nel Keychain.")
        }
    }
    
    @Published var nvidiaModel: String {
        didSet {
            let trimmed = nvidiaModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != nvidiaModel {
                nvidiaModel = trimmed
                return
            }
            if nvidiaModel != oldValue {
                defaults.set(nvidiaModel, forKey: "nvidia_model")
            }
        }
    }
    
    // MARK: - OpenCode AI (Zen)
    
    @Published var openCodeApiKey: String = "" {
        didSet {
            scheduleKeychainSave(key: "opencode_api_key", newValue: openCodeApiKey, errorMessage: "Impossibile salvare la chiave OpenCode nel Keychain.")
        }
    }
    
    @Published var openCodeModel: String {
        didSet {
            if openCodeModel != oldValue {
                defaults.set(openCodeModel, forKey: "opencode_model")
            }
        }
    }
    
    @Published var ollamaEndpoint: String {
        didSet {
            if ollamaEndpoint != oldValue {
                defaults.set(ollamaEndpoint, forKey: "ollama_endpoint")
            }
        }
    }
    
    @Published var ollamaModel: String {
        didSet {
            if ollamaModel != oldValue {
                defaults.set(ollamaModel, forKey: "ollama_model")
            }
        }
    }
    
    // MARK: - Custom OpenAI-Compatible Provider (OpenCode, GLM-5.2, LM Studio, etc.)
    
    @Published var customBaseURL: String {
        didSet {
            if customBaseURL != oldValue {
                defaults.set(customBaseURL, forKey: "custom_base_url")
            }
        }
    }
    
    @Published var customModel: String {
        didSet {
            let trimmed = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != customModel {
                customModel = trimmed
                return
            }
            if customModel != oldValue {
                defaults.set(customModel, forKey: "custom_model")
            }
        }
    }
    
    @Published var customApiKey: String = "" {
        didSet {
            scheduleKeychainSave(key: "custom_api_key", newValue: customApiKey, errorMessage: "Impossibile salvare la chiave del provider custom nel Keychain.")
        }
    }
    
    // MARK: - Default Provider
    
    @Published var defaultProvider: AIProvider {
        didSet {
            if defaultProvider != oldValue {
                defaults.set(defaultProvider.rawValue, forKey: "default_provider")
            }
        }
    }
    
    // MARK: - Window Style Settings
    
    @Published var useStandardWindow: Bool {
        didSet {
            if useStandardWindow != oldValue {
                defaults.set(useStandardWindow, forKey: "use_standard_window")
                NotificationCenter.default.post(name: .atlasWindowStyleChanged, object: nil)
            }
        }
    }
    
    // MARK: - Thinking / Reasoning Settings
    
    @Published var disableThinking: Bool = false {
        didSet {
            if disableThinking != oldValue {
                defaults.set(disableThinking, forKey: "disable_thinking")
            }
        }
    }
    
    private let defaults = UserDefaults.standard
    
    /// Debounced keychain writes: typing an API key triggers delete+add
    /// (IPC with securityd) per keystroke; this coalesces them to one write
    /// shortly after the user stops typing.
    private var keychainSaveTasks: [String: Task<Void, Never>] = [:]
    
    private init() {
        self.openAIApiKey = KeychainStore.load(key: "openai_api_key") ?? ""
        self.claudeApiKey = KeychainStore.load(key: "claude_api_key") ?? ""
        self.nvidiaApiKey = KeychainStore.load(key: "nvidia_api_key") ?? ""
        self.openCodeApiKey = KeychainStore.load(key: "opencode_api_key") ?? ""
        self.customApiKey = KeychainStore.load(key: "custom_api_key") ?? ""
        let rawNvidia = defaults.string(forKey: "nvidia_model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.nvidiaModel = rawNvidia.isEmpty ? "meta/llama-3.3-70b-instruct" : rawNvidia
        self.openCodeModel = defaults.string(forKey: "opencode_model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "deepseek-v4-flash-free"
        self.ollamaEndpoint = defaults.string(forKey: "ollama_endpoint")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "http://localhost:11434/api/generate"
        self.ollamaModel = defaults.string(forKey: "ollama_model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "llama3"
        self.customBaseURL = defaults.string(forKey: "custom_base_url")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "https://api.openai.com/v1"
        self.customModel = defaults.string(forKey: "custom_model")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        
        if let raw = defaults.string(forKey: "default_provider"), let provider = AIProvider(rawValue: raw) {
            self.defaultProvider = provider
        } else {
            self.defaultProvider = .apple
        }
        
        self.useStandardWindow = defaults.bool(forKey: "use_standard_window")
        self.disableThinking = defaults.bool(forKey: "disable_thinking")
    }
    
    private func scheduleKeychainSave(key: String, newValue: String, errorMessage: String) {
        keychainSaveTasks[key]?.cancel()
        keychainSaveTasks[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            
            if newValue.isEmpty {
                _ = KeychainStore.delete(key: key)
            } else if !KeychainStore.save(key: key, value: newValue) {
                keychainError = errorMessage
            }
        }
    }
    
    func removeOpenCodeKey() {
        _ = KeychainStore.delete(key: "opencode_api_key")
        openCodeApiKey = ""
    }
    
    func removeOpenAIKey() {
        _ = KeychainStore.delete(key: "openai_api_key")
        openAIApiKey = ""
    }
    
    func removeClaudeKey() {
        _ = KeychainStore.delete(key: "claude_api_key")
        claudeApiKey = ""
    }
    
    func removeNvidiaKey() {
        _ = KeychainStore.delete(key: "nvidia_api_key")
        nvidiaApiKey = ""
    }
    
    func removeCustomKey() {
        _ = KeychainStore.delete(key: "custom_api_key")
        customApiKey = ""
    }
}

// MARK: - Preset per la UI impostazioni (consumati da ProviderSections)

extension AppSettings {
    struct CustomPreset {
        let name: String
        let baseURL: String
        let model: String
        /// true se la voce apre un nuovo gruppo nel menu (Divider sopra).
        let startsGroup: Bool

        init(name: String, baseURL: String, model: String, startsGroup: Bool = false) {
            self.name = name
            self.baseURL = baseURL
            self.model = model
            self.startsGroup = startsGroup
        }
    }

    /// Modelli suggeriti per OpenCode AI (Zen).
    static let openCodeModels: [String] = [
        "deepseek-v4-flash-free",
        "big-pickle",
        "mimo-v2.5-free",
        "minimax-m3-free",
        "nemotron-3-ultra-free",
        "deepseek-v4-pro",
        "gpt-5.6-sol",
        "kimi-k2.6",
    ]

    /// Modelli suggeriti per NVIDIA Build.
    static let nvidiaModels: [String] = [
        "meta/llama-3.3-70b-instruct",
        "meta/llama-3.1-70b-instruct",
        "nvidia/llama-3.1-nemotron-70b-instruct",
        "deepseek-ai/deepseek-r1",
    ]

    /// Preset del provider Custom (OpenAI-compatible).
    static let customPresets: [CustomPreset] = [
        CustomPreset(name: "DeepSeek V4 Flash", baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-flash"),
        CustomPreset(name: "DeepSeek V4 Pro", baseURL: "https://api.deepseek.com/v1", model: "deepseek-v4-pro"),
        CustomPreset(name: "OpenCode Go — DeepSeek V4 Flash", baseURL: "https://opencode.ai/zen/go/v1", model: "opencode-go/deepseek-v4-flash", startsGroup: true),
        CustomPreset(name: "OpenCode Go — DeepSeek V4 Pro", baseURL: "https://opencode.ai/zen/go/v1", model: "opencode-go/deepseek-v4-pro"),
        CustomPreset(name: "OpenCode", baseURL: "https://api.opencode.ai/v1", model: "opencode/default", startsGroup: true),
        CustomPreset(name: "GLM-5.2 (ZhipuAI)", baseURL: "https://api.z.ai/api/paas/v4", model: "glm-5.2"),
        CustomPreset(name: "LM Studio (locale)", baseURL: "http://localhost:1234/v1", model: "local-model"),
        CustomPreset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", model: "llama-3.3-70b-versatile"),
        CustomPreset(name: "Together AI", baseURL: "https://api.together.xyz/v1", model: "meta-llama/Llama-3-70b-chat-hf"),
        CustomPreset(name: "Mistral AI", baseURL: "https://api.mistral.ai/v1", model: "mistral-small-latest"),
    ]
}
