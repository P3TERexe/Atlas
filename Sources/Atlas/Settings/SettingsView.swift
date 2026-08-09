import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    
    @State private var showOpenAIKey: Bool = false
    @State private var showClaudeKey: Bool = false
    @State private var showNvidiaKey: Bool = false
    @State private var showOpenCodeKey: Bool = false
    @State private var showCustomKey: Bool = false
    
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
                // MARK: Stile Finestra Palette
                Section("Stile Finestra Palette") {
                    Picker("Tipo di Finestra Prompt", selection: $settings.useStandardWindow) {
                        Label("Overlay Fluttuante HUD (Default)", systemImage: "sparkles")
                            .tag(false)
                        Label("Finestra Standard macOS (\"Finestra Vera\")", systemImage: "macwindow")
                            .tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    
                    Text(settings.useStandardWindow ?
                        "✓ Modalità Finestra Vera attiva: la palette appare come una normale finestra macOS con barra del titolo, pulsanti di ridimensionamento e chiusura. Non si chiude automaticamente quando clicchi all'esterno." :
                        "✓ Modalità Overlay HUD attiva: la palette appare come una barra fluttuante trasparente e si chiude automaticamente al click esterno."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                Section("Apple Intelligence (On-Device)") {
                    HStack {
                        Image(systemName: "brain.head.profile")
                            .foregroundColor(.accentColor)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Foundation Models")
                                .font(.headline)
                            Text("Modello integrato nel sistema. Massimo rispetto della privacy, zero configurazione.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                
                // MARK: OpenCode AI (Zen)
                Section("OpenCode AI (Zen)") {
                    HStack {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .foregroundColor(.accentColor)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenCode AI (Zen Inference API)")
                                .font(.headline)
                            Text("Ottieni l'API Key gratuita o pro su opencode.ai/auth.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    HStack {
                        if showOpenCodeKey {
                            TextField("API Key (opencode.ai/auth)", text: $settings.openCodeApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key (opencode.ai/auth)", text: $settings.openCodeApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Button(action: { showOpenCodeKey.toggle() }) {
                            Image(systemName: showOpenCodeKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    
                    HStack {
                        TextField("Modello", text: $settings.openCodeModel)
                            .textFieldStyle(.roundedBorder)
                        
                        Menu {
                            Button("deepseek-v4-flash-free (Gratuito)") {
                                settings.openCodeModel = "deepseek-v4-flash-free"
                            }
                            Button("big-pickle (Gratuito)") {
                                settings.openCodeModel = "big-pickle"
                            }
                            Button("mimo-v2.5-free (Gratuito)") {
                                settings.openCodeModel = "mimo-v2.5-free"
                            }
                            Button("minimax-m3-free (Gratuito)") {
                                settings.openCodeModel = "minimax-m3-free"
                            }
                            Button("nemotron-3-ultra-free (Gratuito)") {
                                settings.openCodeModel = "nemotron-3-ultra-free"
                            }
                            Divider()
                            Button("deepseek-v4-pro (Pro)") {
                                settings.openCodeModel = "deepseek-v4-pro"
                            }
                            Button("gpt-5.6-sol (Pro)") {
                                settings.openCodeModel = "gpt-5.6-sol"
                            }
                            Button("kimi-k2.6 (Pro)") {
                                settings.openCodeModel = "kimi-k2.6"
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Seleziona un modello OpenCode Zen")
                    }
                    
                    HStack {
                        if !settings.openCodeApiKey.isEmpty {
                            Label("Salvata nel Keychain", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Label("Chiave assente (opencode.ai/auth)", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Test API") {
                            testOpenCodeConnection()
                        }
                        .disabled(testingOpenCode || settings.openCodeApiKey.isEmpty)
                        
                        Button("Rimuovi") {
                            settings.removeOpenCodeKey()
                        }
                        .disabled(settings.openCodeApiKey.isEmpty)
                    }
                    
                    if let result = openCodeTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
                
                // MARK: NVIDIA Build
                Section("NVIDIA Build") {
                    HStack {
                        if showNvidiaKey {
                            TextField("API Key (nvapi-...)", text: $settings.nvidiaApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key (nvapi-...)", text: $settings.nvidiaApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Button(action: { showNvidiaKey.toggle() }) {
                            Image(systemName: showNvidiaKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    
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
                        .help("Seleziona un modello NVIDIA attivo")
                    }
                    
                    HStack {
                        if !settings.nvidiaApiKey.isEmpty {
                            Label("Salvata nel Keychain", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Label("Chiave assente", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Test API") {
                            testNvidiaConnection()
                        }
                        .disabled(testingNvidia || settings.nvidiaApiKey.isEmpty)
                        
                        Button("Rimuovi") {
                            settings.removeNvidiaKey()
                        }
                        .disabled(settings.nvidiaApiKey.isEmpty)
                    }
                    
                    if let result = nvidiaTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
                
                // MARK: OpenAI
                Section("OpenAI") {
                    HStack {
                        if showOpenAIKey {
                            TextField("API Key (sk-...)", text: $settings.openAIApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key (sk-...)", text: $settings.openAIApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Button(action: { showOpenAIKey.toggle() }) {
                            Image(systemName: showOpenAIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    
                    HStack {
                        if !settings.openAIApiKey.isEmpty {
                            Label("Salvata nel Keychain", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Label("Chiave assente", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Test API") {
                            testOpenAIConnection()
                        }
                        .disabled(testingOpenAI || settings.openAIApiKey.isEmpty)
                        
                        Button("Rimuovi") {
                            settings.removeOpenAIKey()
                        }
                        .disabled(settings.openAIApiKey.isEmpty)
                    }
                    
                    if let result = openAITestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
                
                // MARK: Claude (Anthropic)
                Section("Claude (Anthropic)") {
                    HStack {
                        if showClaudeKey {
                            TextField("API Key (sk-ant-...)", text: $settings.claudeApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key (sk-ant-...)", text: $settings.claudeApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Button(action: { showClaudeKey.toggle() }) {
                            Image(systemName: showClaudeKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    
                    HStack {
                        if !settings.claudeApiKey.isEmpty {
                            Label("Salvata nel Keychain", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Label("Chiave assente", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Test API") {
                            testClaudeConnection()
                        }
                        .disabled(testingClaude || settings.claudeApiKey.isEmpty)
                        
                        Button("Rimuovi") {
                            settings.removeClaudeKey()
                        }
                        .disabled(settings.claudeApiKey.isEmpty)
                    }
                    
                    if let result = claudeTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.hasPrefix("✓") ? .green : .red)
                    }
                }
                
                // MARK: Ollama (Locale)
                Section("Ollama (Locale)") {
                    TextField("Endpoint REST", text: $settings.ollamaEndpoint)
                        .textFieldStyle(.roundedBorder)
                    
                    TextField("Nome Modello", text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        Text("Es. endpoint: http://localhost:11434/api/generate")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        Button(action: testOllamaConnection) {
                            if testingOllama {
                                ProgressView().scaleEffect(0.6)
                            } else {
                                Text("Test Connessione")
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
                
                // MARK: Custom OpenAI-Compatible
                Section("Custom (OpenAI-Compatible)") {
                    HStack {
                        Image(systemName: "puzzlepiece.extension")
                            .foregroundColor(.accentColor)
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Provider Custom OpenAI-Compatible")
                                .font(.headline)
                            Text("Qualsiasi server con API /chat/completions: OpenCode, GLM-5.2, LM Studio, vLLM, ecc.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    
                    HStack {
                        TextField("Base URL (es. https://api.z.ai/api/paas/v4)", text: $settings.customBaseURL)
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
                        .help("Seleziona preset provider")
                    }
                    
                    TextField("Modello (es. glm-5.2)", text: $settings.customModel)
                        .textFieldStyle(.roundedBorder)
                    
                    HStack {
                        if showCustomKey {
                            TextField("API Key (opzionale)", text: $settings.customApiKey)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("API Key (opzionale)", text: $settings.customApiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button(action: { showCustomKey.toggle() }) {
                            Image(systemName: showCustomKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }
                    
                    HStack {
                        if !settings.customApiKey.isEmpty {
                            Label("API Key salvata nel Keychain", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Label("API Key assente (opzionale per server locali)", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Test API") {
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
                    Text("• Scorciatoia di attivazione: ⌥ Space (solo con Finder attivo)")
                    Text("• Annullamento azioni: ⌘⇧Z")
                    Text("• Le API key sono archiviate in sicurezza nel Keychain di macOS.")
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
        .frame(width: 560, height: 560)
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
                            self.openCodeTestResult = "✓ API Key OpenCode valida e server connesso!"
                        case 401, 403:
                            self.openCodeTestResult = "❌ API Key OpenCode non valida (\(http.statusCode)). Generane una nuova su opencode.ai/auth."
                        default:
                            self.openCodeTestResult = "✓ Connessione a OpenCode stabilita (HTTP \(http.statusCode))."
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingOpenCode = false
                    self.openCodeTestResult = "❌ Connessione a OpenCode fallita: \(error.localizedDescription)"
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
                        self.openAITestResult = "✓ API Key OpenAI valida!"
                    } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        self.openAITestResult = "❌ API Key OpenAI non valida (401 Unauthorized)."
                    } else {
                        self.openAITestResult = "❌ Risposta non valida da OpenAI."
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingOpenAI = false
                    self.openAITestResult = "❌ Connessione a OpenAI fallita: \(error.localizedDescription)"
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
                            self.claudeTestResult = "❌ API Key Claude non valida (\(http.statusCode))."
                        } else {
                            self.claudeTestResult = "✓ API Key Claude valida!"
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingClaude = false
                    self.claudeTestResult = "❌ Connessione ad Anthropic fallita: \(error.localizedDescription)"
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
                        self.nvidiaTestResult = "✓ API Key NVIDIA Build valida!"
                    } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                        self.nvidiaTestResult = "❌ API Key NVIDIA Build non valida (401 Unauthorized)."
                    } else {
                        self.nvidiaTestResult = "✓ API Key NVIDIA accettata."
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingNvidia = false
                    self.nvidiaTestResult = "❌ Connessione a NVIDIA Build fallita: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func testOllamaConnection() {
        testingOllama = true
        ollamaTestResult = nil
        
        guard let url = URL(string: settings.ollamaEndpoint) else {
            testingOllama = false
            ollamaTestResult = "❌ URL endpoint non valido."
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
                        self.ollamaTestResult = "✓ Server Ollama raggiungibile!"
                    } else {
                        self.ollamaTestResult = "✓ Risposta ricevuta da Ollama."
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingOllama = false
                    self.ollamaTestResult = "❌ Impossibile connettersi a Ollama: \(error.localizedDescription)"
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
            customTestResult = "❌ Base URL non valido."
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
                            self.customTestResult = "✓ Provider raggiungibile e API Key valida!"
                        case 401, 403:
                            self.customTestResult = "❌ API Key non valida o accesso negato (\(http.statusCode))."
                        case 404:
                            // Some custom servers don't expose /models — treat as reachable
                            self.customTestResult = "✓ Server raggiungibile (endpoint /models non esposto)."
                        default:
                            self.customTestResult = "⚠︎ Risposta HTTP \(http.statusCode) dal provider."
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.testingCustom = false
                    self.customTestResult = "❌ Impossibile connettersi al provider: \(error.localizedDescription)"
                }
            }
        }
    }
}
