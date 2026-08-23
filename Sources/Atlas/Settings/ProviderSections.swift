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

// MARK: - Apple Intelligence (semplice, zero configurazione)

struct AppleIntelligenceSection: View {
    var body: some View {
        ProviderSection(
            name: "Apple Intelligence",
            icon: "brain.head.profile",
            isConfigured: true
        ) {
            Text("On-device, zero configurazione")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - OpenCode AI

struct OpenCodeSection: View {
    @ObservedObject var settings: AppSettings
    @State private var isTesting = false
    @State private var testResult: String? = nil

    var body: some View {
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
                    ForEach(AppSettings.openCodeModels, id: \.self) { model in
                        Button(model) {
                            settings.openCodeModel = model
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            APIActionRow(
                hasKey: !settings.openCodeApiKey.isEmpty,
                isTesting: isTesting,
                testResult: testResult,
                onTest: runTest,
                onRemove: { settings.removeOpenCodeKey() }
            )
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await ProviderTester.openCode(apiKey: settings.openCodeApiKey)
            await MainActor.run {
                isTesting = false
                testResult = result
            }
        }
    }
}

// MARK: - NVIDIA Build

struct NvidiaSection: View {
    @ObservedObject var settings: AppSettings
    @State private var isTesting = false
    @State private var testResult: String? = nil

    var body: some View {
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
                    ForEach(AppSettings.nvidiaModels, id: \.self) { model in
                        Button(model) {
                            settings.nvidiaModel = model
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            APIActionRow(
                hasKey: !settings.nvidiaApiKey.isEmpty,
                isTesting: isTesting,
                testResult: testResult,
                onTest: runTest,
                onRemove: { settings.removeNvidiaKey() }
            )
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await ProviderTester.nvidia(apiKey: settings.nvidiaApiKey)
            await MainActor.run {
                isTesting = false
                testResult = result
            }
        }
    }
}

// MARK: - OpenAI

struct OpenAISEction: View {
    @ObservedObject var settings: AppSettings
    @State private var isTesting = false
    @State private var testResult: String? = nil

    var body: some View {
        ProviderSection(
            name: "OpenAI",
            icon: "circle.hexagongrid",
            isConfigured: !settings.openAIApiKey.isEmpty
        ) {
            APIKeyField(placeholder: "API Key (sk-...)", key: $settings.openAIApiKey)

            APIActionRow(
                hasKey: !settings.openAIApiKey.isEmpty,
                isTesting: isTesting,
                testResult: testResult,
                onTest: runTest,
                onRemove: { settings.removeOpenAIKey() }
            )
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await ProviderTester.openAI(apiKey: settings.openAIApiKey)
            await MainActor.run {
                isTesting = false
                testResult = result
            }
        }
    }
}

// MARK: - Claude (Anthropic)

struct ClaudeSection: View {
    @ObservedObject var settings: AppSettings
    @State private var isTesting = false
    @State private var testResult: String? = nil

    var body: some View {
        ProviderSection(
            name: "Claude (Anthropic)",
            icon: "bubble.left.and.text.bubble.right",
            isConfigured: !settings.claudeApiKey.isEmpty
        ) {
            APIKeyField(placeholder: "API Key (sk-ant-...)", key: $settings.claudeApiKey)

            APIActionRow(
                hasKey: !settings.claudeApiKey.isEmpty,
                isTesting: isTesting,
                testResult: testResult,
                onTest: runTest,
                onRemove: { settings.removeClaudeKey() }
            )
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await ProviderTester.claude(apiKey: settings.claudeApiKey)
            await MainActor.run {
                isTesting = false
                testResult = result
            }
        }
    }
}

// MARK: - Ollama (Locale)

struct OllamaSection: View {
    @ObservedObject var settings: AppSettings
    @State private var isTesting = false
    @State private var testResult: String? = nil

    var body: some View {
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
                Button(action: runTest) {
                    if isTesting {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Text("Test")
                    }
                }
                .disabled(isTesting || settings.ollamaEndpoint.isEmpty)
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.hasPrefix("✓") ? .green : .red)
            }
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await ProviderTester.ollama(endpoint: settings.ollamaEndpoint)
            await MainActor.run {
                isTesting = false
                testResult = result
            }
        }
    }
}

// MARK: - Custom (OpenAI-Compatible)

struct CustomSection: View {
    @ObservedObject var settings: AppSettings
    @State private var isTesting = false
    @State private var testResult: String? = nil

    var body: some View {
        ProviderSection(
            name: "Custom (OpenAI-Compatible)",
            icon: "puzzlepiece.extension",
            isConfigured: !settings.customBaseURL.isEmpty
        ) {
            HStack {
                TextField("Base URL", text: $settings.customBaseURL)
                    .textFieldStyle(.roundedBorder)

                Menu {
                    ForEach(Array(AppSettings.customPresets.enumerated()), id: \.offset) { index, preset in
                        if preset.startsGroup {
                            Divider()
                        }
                        Button(preset.name) {
                            settings.customBaseURL = preset.baseURL
                            settings.customModel = preset.model
                        }
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
                    runTest()
                }
                .disabled(isTesting || settings.customBaseURL.isEmpty)

                if !settings.customApiKey.isEmpty {
                    Button("Rimuovi") {
                        settings.removeCustomKey()
                    }
                }
            }

            if let result = testResult {
                Text(result)
                    .font(.caption)
                    .foregroundColor(result.hasPrefix("✓") ? .green : .red)
            }
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        Task {
            let result = await ProviderTester.custom(baseURL: settings.customBaseURL, apiKey: settings.customApiKey)
            await MainActor.run {
                isTesting = false
                testResult = result
            }
        }
    }
}

// MARK: - Tab Provider AI

struct ProviderSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
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
            AppleIntelligenceSection()

            // MARK: OpenCode AI
            OpenCodeSection(settings: settings)

            // MARK: NVIDIA Build
            NvidiaSection(settings: settings)

            // MARK: OpenAI
            OpenAISEction(settings: settings)

            // MARK: Claude
            ClaudeSection(settings: settings)

            // MARK: Ollama
            OllamaSection(settings: settings)

            // MARK: Custom
            CustomSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}
