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
            
            // Actions — compact, no subtitles
            VStack(spacing: 2) {
                MenuBarButton(
                    icon: "keyboard",
                    title: "Attiva Palette",
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
                                .frame(width: 26, height: 26)
                            Image(systemName: "gear")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                        
                        Text("Impostazioni")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                MenuBarButton(
                    icon: "arrow.counterclockwise",
                    title: "Riavvia",
                    color: .orange
                ) {
                    restartApp()
                }
                
                MenuBarButton(
                    icon: "xmark.circle",
                    title: "Esci",
                    color: .red
                ) {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            
            Divider()
            
            // Footer — version instead of tagline
            HStack {
                Text("Atlas v1.0")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
        .frame(width: 240)
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
    let color: Color
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color.opacity(0.15))
                        .frame(width: 26, height: 26)
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color)
                }
                
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
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
