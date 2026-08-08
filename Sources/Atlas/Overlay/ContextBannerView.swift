import SwiftUI

struct ContextBannerView: View {
    let context: FinderContext?
    @State private var isExpanded: Bool = false
    
    private var folderName: String {
        context?.currentDirectory?.lastPathComponent ?? "Finder"
    }
    
    private var selectedFiles: [URL] {
        context?.selectedFiles ?? []
    }
    
    private var selectedFilesCount: Int {
        selectedFiles.count
    }
    
    private var extensionCounts: [(ext: String, count: Int)] {
        guard !selectedFiles.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        for file in selectedFiles {
            let ext = file.pathExtension.uppercased()
            let key = ext.isEmpty ? "FILE" : ext
            counts[key, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (ext: $0.key, count: $0.value) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 12))
                
                Text(folderName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("·")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                
                if selectedFilesCount > 0 {
                    Text("\(selectedFilesCount) file \(selectedFilesCount == 1 ? "selezionato" : "selezionati")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 4) {
                        ForEach(extensionCounts.prefix(4), id: \.ext) { item in
                            Text("\(item.count) \(item.ext)")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundColor(.accentColor)
                                .cornerRadius(4)
                        }
                    }
                    
                    Spacer()
                    
                    Button(action: { withAnimation { isExpanded.toggle() } }) {
                        HStack(spacing: 3) {
                            Text(isExpanded ? "Nascondi" : "Mostra file")
                                .font(.system(size: 10))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Nessun file selezionato")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
            }
            
            // Selected files pills list (toggled via isExpanded or shown by default if <= 5 files)
            if selectedFilesCount > 0 && (isExpanded || selectedFilesCount <= 5) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selectedFiles, id: \.self) { url in
                            HStack(spacing: 4) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.accentColor.opacity(0.8))
                                Text(url.lastPathComponent)
                                    .font(.system(size: 10, weight: .medium))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.08))
                            .cornerRadius(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
                            )
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}
