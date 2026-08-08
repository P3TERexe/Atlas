import SwiftUI
import AppKit
@preconcurrency import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleOverlay = Self("toggleOverlay", default: .init(.space, modifiers: [.option]))
    static let globalUndo = Self("globalUndo", default: .init(.z, modifiers: [.command, .shift]))
}

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // MARK: - Menu Bar Icon & Widget
        MenuBarExtra {
            MenuBarView()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                Text("Atlas")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .menuBarExtraStyle(.window)
        
        // MARK: - Settings Window
        Settings {
            SettingsView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var overlayWindowController: OverlayWindowController?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        overlayWindowController = OverlayWindowController()
        
        KeyboardShortcuts.onKeyDown(for: .toggleOverlay) { [weak self] in
            self?.toggleOverlay()
        }
        
        KeyboardShortcuts.onKeyDown(for: .globalUndo) {
            Task { @MainActor in
                AtlasUndoManager.shared.undo()
            }
        }
    }
    
    func toggleOverlay() {
        guard let controller = overlayWindowController else { return }
        
        // Se l'overlay è già visibile, nascondilo
        if controller.window?.isVisible == true {
            controller.hideOverlay()
            return
        }
        
        // Atlas si attiva SOLO quando Finder è l'app in primo piano
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier == "com.apple.finder" else {
            return
        }
        
        controller.showOverlay()
    }
}
