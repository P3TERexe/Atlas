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
        self.nvidiaModel = defaults.string(forKey: "nvidia_model") ?? "meta/llama-3.3-70b-instruct"
        self.openCodeModel = defaults.string(forKey: "opencode_model") ?? "deepseek-v4-flash-free"
        self.ollamaEndpoint = defaults.string(forKey: "ollama_endpoint") ?? "http://localhost:11434/api/generate"
        self.ollamaModel = defaults.string(forKey: "ollama_model") ?? "llama3"
        self.customBaseURL = defaults.string(forKey: "custom_base_url") ?? "https://api.openai.com/v1"
        self.customModel = defaults.string(forKey: "custom_model") ?? ""
        
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
