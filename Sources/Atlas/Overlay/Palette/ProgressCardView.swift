import SwiftUI

/// Card di avanzamento durante l'esecuzione (messaggio + percentuale + barra).
struct ProgressCardView: View {
    let progress: ProgressUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.message)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                Spacer()
                Text("\(Int(progress.fraction * 100))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.18))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.15), value: progress.fraction)

            if let detail = progress.detail {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
