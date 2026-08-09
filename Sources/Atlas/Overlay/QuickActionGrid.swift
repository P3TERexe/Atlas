import SwiftUI

struct ActionPill: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let command: String
    let tint: Color
}

struct QuickActionCategory: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let pills: [ActionPill]
}

struct QuickActionGrid: View {
    let onSelect: (String) -> Void
    
    private let categories: [QuickActionCategory] = [
        QuickActionCategory(
            title: "Immagini",
            icon: "photo",
            pills: [
                ActionPill(icon: "photo", label: "JPG", command: "jpg", tint: .blue),
                ActionPill(icon: "photo.fill", label: "PNG", command: "png", tint: .blue),
                ActionPill(icon: "globe", label: "WebP", command: "webp", tint: .blue),
                ActionPill(icon: "arrow.up.left.and.arrow.down.right", label: "Resize 1024px", command: "ridimensiona immagini a 1024px", tint: .blue),
                ActionPill(icon: "circle.righthalf.filled", label: "B&W", command: "bw", tint: .blue),
                ActionPill(icon: "xmark.shield", label: "Pulisci EXIF", command: "rimuovi metadati EXIF immagini", tint: .blue),
                ActionPill(icon: "text.viewfinder", label: "OCR Rename", command: "ocr", tint: .blue)
            ]
        ),
        QuickActionCategory(
            title: "Video & Audio",
            icon: "film",
            pills: [
                ActionPill(icon: "play.rectangle", label: "MP4", command: "mp4", tint: .purple),
                ActionPill(icon: "waveform", label: "MP3", command: "mp3", tint: .purple)
            ]
        ),
        QuickActionCategory(
            title: "Documenti PDF",
            icon: "doc.text",
            pills: [
                ActionPill(icon: "doc.on.doc", label: "Unisci PDF", command: "unisci pdf", tint: .red),
                ActionPill(icon: "doc.richtext", label: "Immagini → PDF", command: "immagini in unico pdf", tint: .red),
                ActionPill(icon: "arrow.down.right.and.arrow.up.left", label: "Comprimi PDF", command: "comprimi pdf", tint: .red),
                ActionPill(icon: "scissors", label: "Split Pagine", command: "dividi pagine pdf", tint: .red)
            ]
        ),
        QuickActionCategory(
            title: "File & Archivi",
            icon: "folder",
            pills: [
                ActionPill(icon: "doc.zipper", label: "ZIP", command: "zip", tint: .green),
                ActionPill(icon: "pencil.and.outline", label: "Rinomina", command: "rinomina file", tint: .green),
                ActionPill(icon: "cursorarrow.click.2", label: "Seleziona", command: "seleziona file", tint: .green)
            ]
        ),
        QuickActionCategory(
            title: "Calcoli & Utility",
            icon: "function",
            pills: [
                ActionPill(icon: "plusminus.circle", label: "Calcola 15% di 85.99", command: "15% of 85.99", tint: .orange),
                ActionPill(icon: "terminal", label: "Esegui Shell", command: "shell", tint: .orange)
            ]
        )
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Azioni Rapide & Formati Supportati")
                .font(.caption.weight(.bold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 2)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(categories) { cat in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: cat.icon)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(cat.title)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            
                            FlowLayout(spacing: 6) {
                                ForEach(cat.pills) { pill in
                                    Button(action: { onSelect(pill.command) }) {
                                        HStack(spacing: 5) {
                                            Image(systemName: pill.icon)
                                                .font(.system(size: 10))
                                            Text(pill.label)
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(pill.tint.opacity(0.12))
                                        .foregroundColor(pill.tint)
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(pill.tint.opacity(0.2), lineWidth: 1)
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .padding(12)
    }
}

// Helper layout for wrapping pills horizontally
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0
        var x: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                height += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
