import AppKit
import SwiftUI

class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class OverlayWindowController: NSWindowController {
    
    init() {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        
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
        
        // Hide when clicking outside
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
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc func windowDidResignKey() {
        hideOverlay()
    }
    
    @objc func hideFromNotification() {
        hideOverlay()
    }
    
    func showOverlay() {
        guard let window = self.window else { return }
        
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
