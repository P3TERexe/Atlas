import AppKit
import SwiftUI

extension Notification.Name {
    static let atlasWindowStyleChanged = Notification.Name("atlasWindowStyleChanged")
}

class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class OverlayWindowController: NSWindowController {
    
    init() {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 440),
            styleMask: [.titled, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        
        // The visual effect container (frosted glass background)
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 16
        visualEffect.layer?.masksToBounds = true
        
        let hostingView = NSHostingView(rootView: CommandPaletteView())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])
        
        panel.contentView = visualEffect
        panel.center()
        
        super.init(window: panel)
        
        applyWindowStyle()
        
        // Hide when clicking outside (only in HUD overlay mode)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        
        // Hide when SwiftUI Escape is pressed
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hideFromNotification),
            name: .atlasHideOverlay,
            object: nil
        )
        
        // Update window style when settings change
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleStyleChange),
            name: .atlasWindowStyleChanged,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc func applyWindowStyle() {
        guard let panel = self.window as? NSPanel else { return }
        
        let isStandard = AppSettings.shared.useStandardWindow
        
        if isStandard {
            // Standard macOS Window ("Finestra Vera")
            panel.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            panel.title = "Atlas — Prompt Command Palette"
            panel.titlebarAppearsTransparent = false
            panel.titleVisibility = .visible
            panel.level = .normal
            panel.isFloatingPanel = false
            panel.hidesOnDeactivate = false
            panel.isOpaque = true
            panel.backgroundColor = .windowBackgroundColor
            panel.hasShadow = true
        } else {
            // Floating Overlay HUD Panel (Default)
            panel.styleMask = [.titled, .fullSizeContentView, .borderless]
            panel.title = ""
            panel.titlebarAppearsTransparent = true
            panel.titleVisibility = .hidden
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
        }
    }
    
    @objc func handleStyleChange() {
        applyWindowStyle()
    }
    
    @objc func windowDidResignKey() {
        // Automatically hide on focus loss ONLY if in HUD overlay mode.
        // Adds a 350ms graceful delay so instant selection actions in Finder
        // display their result banner before the overlay smoothly hides.
        if !AppSettings.shared.useStandardWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, let window = self.window else { return }
                if !window.isKeyWindow {
                    self.hideOverlay()
                }
            }
        }
    }
    
    @objc func hideFromNotification() {
        hideOverlay()
    }
    
    func showOverlay() {
        guard let window = self.window else { return }
        
        applyWindowStyle()
        window.center()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
    }
    
    func hideOverlay() {
        guard let window = self.window, window.isVisible else { return }
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0.0
        }, completionHandler: {
            Task { @MainActor in
                window.orderOut(nil)
            }
        })
    }
}
