import SwiftUI

/// Riga di un file creato: icona, nome, reveal nel Finder, doppio click per aprire.
struct OutputFileRow: View {
    let url: URL
    @State private var isHovered = false
    @State private var fileIcon: NSImage? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let fileIcon {
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
            }

            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Reveal in Finder
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Mostra nel Finder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            NSWorkspace.shared.open(url)
        }
        .task {
            let path = url.path
            await MainActor.run {
                if self.fileIcon == nil {
                    self.fileIcon = NSWorkspace.shared.icon(forFile: path)
                }
            }
        }
        .help("Doppio click per aprire")
    }
}
