import SwiftUI
import AppKit

// MARK: - Menu Bar Widget View

struct MenuBarView: View {
    @ObservedObject private var settings = AppSettings.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                
                Text("Atlas")
                    .font(.system(size: 12, weight: .semibold))
                
                Spacer()
                
                // Active provider badge
                Label(settings.defaultProvider.rawValue, systemImage: settings.defaultProvider.icon)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            
            Divider()
            
            // Actions
            VStack(spacing: 2) {
                MenuBarButton(
                    icon: "keyboard",
                    title: "Attiva Palette",
                    subtitle: "⌥ Space (con Finder aperto)",
                    color: .accentColor
                ) {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.toggleOverlay()
                    }
                }
                
                SettingsLink {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(width: 28, height: 28)
                            Image(systemName: "gear")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Impostazioni")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.primary)
                            Text("Provider AI, API keys")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                MenuBarButton(
                    icon: "arrow.counterclockwise",
                    title: "Riavvia Atlas",
                    subtitle: "Ricarica l'applicazione",
                    color: .orange
                ) {
                    restartApp()
                }
                
                MenuBarButton(
                    icon: "xmark.circle",
                    title: "Esci da Atlas",
                    subtitle: "Chiudi l'applicazione",
                    color: .red
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            
            Divider()
            
            // Footer
            HStack {
                Text("Atlas — Natural Language Filesystem")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .frame(width: 260)
        .background(.regularMaterial)
    }
    
    private func restartApp() {
        guard let executableURL = Bundle.main.executableURL else {
            NSApplication.shared.terminate(nil)
            return
        }
        let process = Process()
        process.executableURL = executableURL
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Menu Bar Row Button

struct MenuBarButton: View {
    let icon: String
    let title: String
    let subtitle: String
    let color: Color
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color.opacity(0.15))
                        .frame(width: 28, height: 28)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(color)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
