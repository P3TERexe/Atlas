import SwiftUI
@preconcurrency import KeyboardShortcuts

// MARK: - Reusable Provider Section (Collapsible)

struct ProviderSection<Content: View>: View {
    let name: String
    let icon: String
    let isConfigured: Bool
    @ViewBuilder let content: () -> Content
    
    @State private var isExpanded: Bool = false
    
    var body: some View {
        Section {
            // Header — click to expand/collapse
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundColor(.accentColor)
                        .font(.system(size: 16))
                    
                    Text(name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if isConfigured {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    } else {
                        Image(systemName: "circle.dashed")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - API Key Field

struct APIKeyField: View {
    let placeholder: String
    @Binding var key: String
    @State private var showKey: Bool = false
    
    var body: some View {
        HStack {
            if showKey {
                TextField(placeholder, text: $key)
                    .textFieldStyle(.roundedBorder)
            } else {
                SecureField(placeholder, text: $key)
                    .textFieldStyle(.roundedBorder)
            }
            
            Button(action: { showKey.toggle() }) {
                Image(systemName: showKey ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Test/Remove Row

struct APIActionRow: View {
    let hasKey: Bool
    let isTesting: Bool
    let testResult: String?
    let onTest: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
        HStack {
            if hasKey {
                Label("Keychain ✓", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
            
            Spacer()
            
            Button("Test") { onTest() }
                .disabled(isTesting || !hasKey)
            
            Button("Rimuovi") { onRemove() }
                .disabled(!hasKey)
        }
        
        if let result = testResult {
            Text(result)
                .font(.caption)
                .foregroundColor(result.hasPrefix("✓") ? .green : .red)
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    
    @State private var testingOllama: Bool = false
    @State private var ollamaTestResult: String? = nil
    
    @State private var testingOpenAI: Bool = false
    @State private var openAITestResult: String? = nil
    
    @State private var testingClaude: Bool = false
    @State private var claudeTestResult: String? = nil
    
    @State private var testingNvidia: Bool = false
    @State private var nvidiaTestResult: String? = nil
    
    @State private var testingOpenCode: Bool = false
    @State private var openCodeTestResult: String? = nil
    
    @State private var testingCustom: Bool = false
    @State private var customTestResult: String? = nil
    
    var body: some View {
        TabView {
            // MARK: - Tab Provider AI
            Form {
                // MARK: Window Style — compact toggle
                Section("Finestra & Scorciatoia") {
                    Picker("Tipo Finestra", selection: $settings.useStandardWindow) {
                        Text("Overlay HUD").tag(false)
                        Text("Finestra Standard").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    
                    HStack {
                        Text("Scorciatoia di attivazione")
                        Spacer()
                        KeyboardShortcuts.Recorder(for: .toggleOverlay)
                    }
                }
                
                Section("Pensiero AI") {
                    Toggle("Disabilita ragionamento esteso (Modalità Veloce)", isOn: $settings.disableThinking)
                }
                
                Section("Provider Predefinito") {
                    Picker("Seleziona Provider", selection: $settings.defaultProvider) {
                        ForEach(AIProvider.allCases) { provider in
                            Label(provider.rawValue, systemImage: provider.icon)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                
                // MARK: Apple Intelligence
                ProviderSection(
                    name: "Apple Intelligence",
                    icon: "brain.head.profile",
                    isConfigured: true
                ) {
                    Text("On-device, zero configurazione")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // MARK: OpenCode AI
                ProviderSection(
                    name: "OpenCode AI (Zen)",
                    icon: "chevron.left.forwardslash.chevron.right",
                    isConfigured: !settings.openCodeApiKey.isEmpty
                ) {
                    APIKeyField(placeholder: "API Key", key: $settings.openCodeApiKey)
                    
                    HStack {
                        TextField("Modello", text: $settings.openCodeModel)
                            .textFieldStyle(.roundedBorder)
                        
                        Menu {
                            Button("deepseek-v4-flash-free") {
                                settings.openCodeModel = "deepseek-v4-flash-free"
                            }
                            Button("big-pickle") {
                                settings.openCodeModel = "big-pickle"
                            }
                            Button("mimo-v2.5-free") {
                                settings.openCodeModel = "mimo-v2.5-free"
                            }
                            Button("minimax-m3-free") {
                                settings.openCodeModel = "minimax-m3-free"
                            }
                            Button("nemotron-3-ultra-free") {
                                settings.openCodeModel = "nemotron-3-ultra-free"
                            }
                            Divider()
                            Button("deepseek-v4-pro") {
                                settings.openCodeModel = "deepseek-v4-pro"
                            }
                            Button("gpt-5.6-sol") {
                                settings.openCodeModel = "gpt-5.6-sol"
                            }
                            Button("kimi-k2.6") {
                                settings.openCodeModel = "kimi-k2.6"
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    
                    APIActionRow(
                        hasKey: !settings.openCodeApiKey.isEmpty,
                        isTesting: testingOpenCode,
                        testResult: openCodeTestResult,
                        onTest: testOpenCodeConnection,
                        onRemove: { settings.removeOpenCodeKey() }
                    )
                }
                
                // MARK: NVIDIA Build
                ProviderSection(
                    name: "NVIDIA Build",
                    icon: "cpu",
                    isConfigured: !settings.nvidiaApiKey.isEmpty
                ) {
                    APIKeyField(placeholder: "API Key (nvapi-...)", key: $settings.nvidiaApiKey)
                    
                    HStack {
                        TextField("Modello", text: $settings.nvidiaModel)
                            .textFieldStyle(.roundedBorder)
                        
                        Menu {
                            Button("meta/llama-3.3-70b-instruct") {
                                settings.nvidiaModel = "meta/llama-3.3-70b-instruct"
                            }
                            Button("meta/llama-3.1-70b-instruct") {
                                settings.nvidiaModel = "meta/llama-3.1-70b-instruct"
                            }
                            Button("nvidia/llama-3.1-nemotron-70b-instruct") {
                                settings.nvidiaModel = "nvidia/llama-3.1-nemotron-70b-instruct"
                            }
                            Button("deepseek-ai/deepseek-r1") {
                                settings.nvidiaModel = "deepseek-ai/deepseek-r1"
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    
                    APIActionRow(
                        hasKey: !settings.nvidiaApiKey.isEmpty,
                        isTesting: testingNvidia,
                        testResult: nvidiaTestResult,
                        onTest: testNvidiaConnection,
                        onRemove: { settings.removeNvidiaKey() }
                    )
                }
                
                // MARK: OpenAI
                ProviderSection(
                    name: "OpenAI",
                    icon: "circle.hexagongrid",
                    isConfigured: !settings.openAIApiKey.isEmpty
                ) {
                    APIKeyField(placeholder: "API Key (sk-...)", key: $settings.openAIApiKey)
                    
                    APIActionRow(
                        hasKey: !settings.openAIApiKey.isEmpty,
                        isTesting: testingOpenAI,
                        testResult: openAITestResult,
                        onTest: testOpenAIConnection,
                        onRemove: { settings.removeOpenAIKey() }
                    )
                }
                
                // MARK: Claude
                ProviderSection(
                    name: "Claude (Anthropic)",
                    icon: "bubble.left.and.text.bubble.right",
                    isConfigured: !settings.claudeApiKey.isEmpty
                ) {
                    APIKeyField(placeholder: "API Key (sk-ant-...)", key: $settings.claudeApiKey)
                    
                    APIActionRow(
                        hasKey: !settings.claudeApiKey.isEmpty,
                        isTesting: testingClaude,
                        testResult: claudeTestResult,
                        onTest: testClaudeConnection,
                        onRemove: { settings.removeClaudeKey() }
                    )
                }
                
                // MARK: Ollama
                ProviderSection(
                    name: "Ollama (Locale)",
                    icon: "desktopcomputer",
                    isConfigured: !settings.ollamaEndpoint.isEmpty
                ) {
                    TextField("Endpoint", text: $settings.ollamaEndpoint)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Modello", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        Spacer()
                        Button(action: testOllamaConnection) {
                            if testingOllama {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Text("Test")
                            }
                        }
                        .disabled(testingOllama || settings.ollamaEndpoint.isEmpty)
                    }
                    
                    if let result = ollamaTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
                
                // MARK: Custom
                ProviderSection(
                    name: "Custom (OpenAI-Compatible)",
                    icon: "puzzlepiece.extension",
                    isConfigured: !settings.customBaseURL.isEmpty
                ) {
                    HStack {
                        TextField("Base URL", text: $settings.customBaseURL)
                            .textFieldStyle(.roundedBorder)
                        
                        Menu {
                            Button("DeepSeek V4 Flash") {
                                settings.customBaseURL = "https://api.deepseek.com/v1"
                                settings.customModel = "deepseek-v4-flash"
                            }
                            Button("DeepSeek V4 Pro") {
                                settings.customBaseURL = "https://api.deepseek.com/v1"
                                settings.customModel = "deepseek-v4-pro"
                            }
                            Divider()
                            Button("OpenCode Go — DeepSeek V4 Flash") {
                                settings.customBaseURL = "https://opencode.ai/zen/go/v1"
                                settings.customModel = "opencode-go/deepseek-v4-flash"
                            }
                            Button("OpenCode Go — DeepSeek V4 Pro") {
                                settings.customBaseURL = "https://opencode.ai/zen/go/v1"
                                settings.customModel = "opencode-go/deepseek-v4-pro"
                            }
                            Divider()
                            Button("OpenCode") {
                                settings.customBaseURL = "https://api.opencode.ai/v1"
                                settings.customModel = "opencode/default"
                            }
                            Button("GLM-5.2 (ZhipuAI)") {
                                settings.customBaseURL = "https://api.z.ai/api/paas/v4"
                                settings.customModel = "glm-5.2"
                            }
                            Button("LM Studio (locale)") {
                                settings.customBaseURL = "http://localhost:1234/v1"
                                settings.customModel = "local-model"
                            }
                            Button("Groq") {
                                settings.customBaseURL = "https://api.groq.com/openai/v1"
                                settings.customModel = "llama-3.3-70b-versatile"
                            }
                            Button("Together AI") {
                                settings.customBaseURL = "https://api.together.xyz/v1"
                                settings.customModel = "meta-llama/Llama-3-70b-chat-hf"
                            }
                            Button("Mistral AI") {
                                settings.customBaseURL = "https://api.mistral.ai/v1"
                                settings.customModel = "mistral-small-latest"
                            }
                        } label: {
                            Image(systemName: "chevron.down.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    
                    TextField("Modello", text: $settings.customModel)
                        .textFieldStyle(.roundedBorder)
                    
                    APIKeyField(placeholder: "API Key (opzionale)", key: $settings.customApiKey)
                    
                    HStack {
                        Spacer()
                        
                        Button("Test") {
                            testCustomConnection()
                        }
                        .disabled(testingCustom || settings.customBaseURL.isEmpty)
                        
                        if !settings.customApiKey.isEmpty {
                            Button("Rimuovi") {
                                settings.removeCustomKey()
                            }
                        }
                    }
                    
                    if let result = customTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Provider AI", systemImage: "cpu")
            }
            
            // MARK: - Tab Informazioni
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)
                
                Text("Atlas")
                    .font(.title.bold())
                
                Text("Natural language interface for your filesystem")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Divider()
                    .padding(.horizontal)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("• ⌥ Space per attivare (con Finder attivo)")
                    Text("• ⌘⇧Z per annullare")
                    Text("• API key salvate nel Keychain")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                
                Spacer()
            }
            .padding(30)
            .tabItem {
                Label("Informazioni", systemImage: "info.circle")
            }
        }
        .frame(width: 520, height: 500)
        .alert("Errore Keychain", isPresented: Binding(
            get: { settings.keychainError != nil },
            set: { if !$0 { settings.keychainError = nil } }
        )) {
            Button("OK", role: .cancel) {
                settings.keychainError = nil
            }
        } message: {
            Text(settings.keychainError ?? "")
        }
    }
    
    // MARK: - Test API Actions
    
    private func testOpenCodeConnection() {
        testingOpenCode = true
        openCodeTestResult = nil
        
        guard let url = URL(string: "https://opencode.ai/zen/v1/models") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.openCodeApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 6
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    self.testingOpenCode = false
                    if let http = response as? HTTPURLResponse {
                        switch http.statusCode {
                        case 200:
                            self.openCodeTestResult = "✓ API Key valida!"
                        case 401, 403:
                            self.openCodeTestResult = "❌ API Key non valida (\(http.statusCode))"
                        default:
                            self.openCodeTestResult = "✓ Connesso (HTTP \(http.statusCode))"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingOpenCode = false
                    self.openCodeTestResult = "❌ Connessione fallita: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testOpenAIConnection() {
        testingOpenAI = true
        openAITestResult = nil
        
        guard let url = URL(string: "https://api.openai.com/v1/models") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.openAIApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    self.testingOpenAI = false
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        self.openAITestResult = "✓ API Key valida!"
                    } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        self.openAITestResult = "❌ API Key non valida (401)"
                    } else {
                        self.openAITestResult = "❌ Risposta non valida"
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingOpenAI = false
                    self.openAITestResult = "❌ Connessione fallita: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testClaudeConnection() {
        testingClaude = true
        claudeTestResult = nil
        
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("anthropic-version=2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("Bearer \(settings.claudeApiKey)", forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 5
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    self.testingClaude = false
                    if let http = response as? HTTPURLResponse {
                        if http.statusCode == 401 || http.statusCode == 403 {
                            self.claudeTestResult = "❌ API Key non valida (\(http.statusCode))"
                        } else {
                            self.claudeTestResult = "✓ API Key valida!"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingClaude = false
                    self.claudeTestResult = "❌ Connessione fallita: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testNvidiaConnection() {
        testingNvidia = true
        nvidiaTestResult = nil
        
        guard let url = URL(string: "https://integrate.api.nvidia.com/v1/models") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(settings.nvidiaApiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    self.testingNvidia = false
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        self.nvidiaTestResult = "✓ API Key valida!"
                    } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        self.nvidiaTestResult = "❌ API Key non valida (401)"
                    } else {
                        self.nvidiaTestResult = "✓ Accettata"
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingNvidia = false
                    self.nvidiaTestResult = "❌ Connessione fallita: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testOllamaConnection() {
        testingOllama = true
        ollamaTestResult = nil
        
        guard let url = URL(string: settings.ollamaEndpoint) else {
            testingOllama = false
            ollamaTestResult = "❌ URL non valido"
            return
        }
        
        let rootURL = url.deletingLastPathComponent().deletingLastPathComponent() // http://localhost:11434
        var request = URLRequest(url: rootURL)
        request.timeoutInterval = 3
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    self.testingOllama = false
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        self.ollamaTestResult = "✓ Raggiungibile!"
                    } else {
                        self.ollamaTestResult = "✓ Risposta ricevuta"
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingOllama = false
                    self.ollamaTestResult = "❌ Non raggiungibile: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testCustomConnection() {
        testingCustom = true
        customTestResult = nil
        
        // Try to hit /models on the base URL (OpenAI-compatible standard endpoint)
        let base = settings.customBaseURL.hasSuffix("/") ? String(settings.customBaseURL.dropLast()) : settings.customBaseURL
        let urlString = base + "/models"
        
        guard let url = URL(string: urlString) else {
            testingCustom = false
            customTestResult = "❌ URL non valido"
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        if !settings.customApiKey.isEmpty {
            request.setValue("Bearer \(settings.customApiKey)", forHTTPHeaderField: "Authorization")
        }
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                await MainActor.run {
                    self.testingCustom = false
                    if let http = response as? HTTPURLResponse {
                        switch http.statusCode {
                        case 200:
                            self.customTestResult = "✓ Raggiungibile, API Key valida!"
                        case 401, 403:
                            self.customTestResult = "❌ Accesso negato (\(http.statusCode))"
                        case 404:
                            // Some custom servers don't expose /models — treat as reachable
                            self.customTestResult = "✓ Raggiungibile"
                        default:
                            self.customTestResult = "⚠︎ HTTP \(http.statusCode)"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingCustom = false
                    self.customTestResult = "❌ Non raggiungibile: \(error.localizedDescription)"
                }
            }
        }
    }
}
