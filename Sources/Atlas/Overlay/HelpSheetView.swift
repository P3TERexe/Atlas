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
                Text("Guida & Limitazioni")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // Section 1: Capabilities
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cosa può fare Atlas", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.green)
                        
                        Group {
                            HelpBullet(icon: "photo", text: "Converti, ridimensiona, ruota, crea miniature e pulisci EXIF da immagini (PNG, JPG, WebP, HEIC, GIF)")
                            HelpBullet(icon: "video", text: "Converti video in MP4/MOV ed estrai audio MP3/M4A")
                            HelpBullet(icon: "doc.text", text: "Unisci, dividi pagine e comprimi documenti PDF")
                            HelpBullet(icon: "doc.zipper", text: "Crea e gestisci archivi ZIP (inclusa la compressione di cartelle intere)")
                            HelpBullet(icon: "function", text: "Calcoli matematici ad alta precisione (es. '15% di 85.99', 'sqrt(1764)') via bc nativo")
                            HelpBullet(icon: "cursorarrow.click.2", label: "Selezione", text: "Seleziona file specifici nel Finder (es. 'seleziona file webp')")
                        }
                    }
                    .padding(10)
                    .background(Color.green.opacity(0.06))
                    .cornerRadius(8)
                    
                    // Section 2: Instant Actions 0ms
                    VStack(alignment: .leading, spacing: 6) {
                        Label("⚡ Instant Actions (0ms)", systemImage: "bolt.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.yellow)
                        
                        Text("Scrivi semplicemente la parola chiave senza frasi complesse per un'esecuzione istantanea locale a 0ms:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        HStack(spacing: 6) {
                            Text("jpg")
                            Text("png")
                            Text("webp")
                            Text("mp3")
                            Text("mp4")
                            Text("zip")
                            Text("unisci pdf")
                            Text("bw")
                        }
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.accentColor)
                    }
                    .padding(10)
                    .background(Color.yellow.opacity(0.06))
                    .cornerRadius(8)
                    
                    // Section 3: Limitations
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Cosa NON può fare (Limitazioni)", systemImage: "hand.raised.fill")
                            .font(.subheadline.bold())
                            .foregroundColor(.orange)
                        
                        Group {
                            HelpBullet(icon: "eye.slash", text: "Non legge o analizza il contenuto visuale delle foto (es. 'trova la foto con il gatto')")
                            HelpBullet(icon: "bubble.left.and.bubble.right", text: "Non è una chat generica (risponde solo ad azioni sul filesystem)")
                            HelpBullet(icon: "doc.richtext", text: "Non modifica il testo interno dei file Word o PDF (solo unione/split/conversione)")
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(8)
                    
                    // Section 4: Shortcuts
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Scorciatoie Utili", systemImage: "keyboard")
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)
                        
                        Group {
                            ShortcutRow(shortcut: "⌥ Space", description: "Apri/Chiudi Atlas nel Finder")
                            ShortcutRow(shortcut: "↑ / ↓", description: "Naviga cronologia comandi recenti nella barra")
                            ShortcutRow(shortcut: "⌘ H", description: "Mostra cronologia completa operazioni con undo selettivo")
                            ShortcutRow(shortcut: "⌘ ⇧ Z", description: "Annulla (Undo) l'ultima operazione eseguita")
                            ShortcutRow(shortcut: "Esc", description: "Chiudi Atlas")
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
