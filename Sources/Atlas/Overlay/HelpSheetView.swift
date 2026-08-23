import SwiftUI

struct HelpSheetView: View {
    let onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                Text("Guida")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 2)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    
                    // Section 1: Capabilities
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cosa può fare Atlas", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.green)
                        
                        Group {
                            HelpBullet(icon: "photo", text: "Converti immagini (PNG, JPG, WebP, HEIC, GIF)")
                            HelpBullet(icon: "video", text: "Converti video (MP4/MOV) ed estrai audio")
                            HelpBullet(icon: "doc.text", text: "Unisci, dividi e comprimi PDF")
                            HelpBullet(icon: "doc.zipper", text: "Crea archivi ZIP")
                            HelpBullet(icon: "function", text: "Calcoli matematici (es. '15% di 85.99')")
                            HelpBullet(icon: "cursorarrow.click.2", text: "Seleziona file nel Finder per tipo")
                        }
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.06))
                    .cornerRadius(8)
                    
                    // Section 2: Limitations
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Limitazioni", systemImage: "hand.raised.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.orange)
                        
                        Group {
                            HelpBullet(icon: "eye.slash", text: "Non analizza il contenuto visuale delle foto")
                            HelpBullet(icon: "bubble.left.and.bubble.right", text: "Non è una chat — solo azioni su file")
                            HelpBullet(icon: "doc.richtext", text: "Non modifica testo interno di Word/PDF")
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(8)
                    
                    // Section 3: Shortcuts
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Scorciatoie", systemImage: "keyboard")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                        
                        Group {
                            ShortcutRow(shortcut: "⌥ Space", description: "Apri/Chiudi Atlas")
                            ShortcutRow(shortcut: "↑ / ↓", description: "Naviga cronologia comandi")
                            ShortcutRow(shortcut: "⌘⇧Z", description: "Annulla ultima operazione")
                            ShortcutRow(shortcut: "Esc", description: "Chiudi")
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04))
                    .cornerRadius(8)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HelpBullet: View {
    let icon: String
    var label: String? = nil
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.accentColor)
                .frame(width: 16)
            
            if let l = label {
                Text(l)
                    .font(.caption.bold())
            }
            
            Text(text)
                .font(.caption)
                .foregroundColor(.primary)
        }
    }
}

struct ShortcutRow: View {
    let shortcut: String
    let description: String
    
    var body: some View {
        HStack {
            Text(shortcut)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.1))
                .cornerRadius(4)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
