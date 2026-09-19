import SwiftUI

// MARK: - Settings View (composizione: tab estratte in ProviderSections.swift)

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            // MARK: - Tab Provider AI
            ProviderSettingsTab(settings: settings)
                .tabItem {
                    Label("Provider AI", systemImage: "cpu")
                }

            // MARK: - Tab Regole
            RulesSettingsTab(rulesStore: RulesStore.shared)
                .tabItem {
                    Label("Regole", systemImage: "list.bullet.rectangle")
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
}
