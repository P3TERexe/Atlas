import SwiftUI
import AppKit

struct PreviewView: View {
    let graph: ActionGraph
    let context: FinderContext
    let onExecute: () -> Void
    let onCancel: () -> Void
    
    /// Shell commands resolved once per graph (off the body), so the preview
    /// never re-scans the filesystem on every SwiftUI body evaluation.
    @State private var shellCommandsByStep: [String: [String]] = [:]
    
    var body: some View {
        let assessment = RiskAssessment.analyze(graph: graph, context: context)
        
        return VStack(alignment: .leading, spacing: 12) {
            // Header: Title + Risk Badge
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                    Text("Anteprima Piano")
                        .font(.headline)
                }
                
                Spacer()
                
                // Risk Assessment Badge
                riskBadge(for: assessment.riskLevel)
            }
            
            // Risk Summary Notice
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
                Text(assessment.summaryMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04))
            .cornerRadius(6)
            
            // Scrollable Steps Section
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(graph.steps, id: \.id) { step in
                        StepCardView(step: step, shellCommands: shellCommandsByStep[step.id])
                    }
                }
                .padding(.trailing, 2)
            }
            
            // Bottom Action Bar
            HStack {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Text("Annulla")
                        Text("Esc")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.1))
                            .cornerRadius(3)
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Spacer()
                
                Button(action: onExecute) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.caption2)
                        Text("Esegui piano")
                            .font(.body.weight(.bold))
                        Text("⌘↩")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .opacity(0.8)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: graph.steps.map(\.id).joined(separator: ",")) {
            await loadShellCommands()
        }
    }
    
    private func loadShellCommands() async {
        var resolved: [String: [String]] = [:]
        for step in graph.steps {
            resolved[step.id] = ToolRegistry.shared.capability(for: step.tool)?.executor.shellCommands(step: step, context: context)
        }
        shellCommandsByStep = resolved
    }
    
    private func riskBadge(for level: RiskLevel) -> some View {
        let color: Color = switch level {
        case .none: .blue
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
        return HStack(spacing: 5) {
            Image(systemName: level.iconName)
                .font(.caption.bold())
            Text("Rischio \(level.title)")
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.18))
        .foregroundColor(color)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Step Card View

struct StepCardView: View {
    let step: ActionStep
    let shellCommands: [String]?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header row: Tool Icon + Human Name + Format Badge
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: iconForTool(step.tool))
                        .foregroundColor(.accentColor)
                        .font(.system(size: 14))
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(humanName(for: step.tool))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.primary)
                    Text(step.tool)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if let format = step.format {
                    Text(format.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(5)
                }
            }
            
            Divider()
            
            // Inputs & Outputs Diff List
            if !step.inputs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(step.inputs, id: \.self) { input in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                            
                            Text(input)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            if step.format != nil {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9))
                                    .foregroundColor(.secondary)
                                    .padding(.top, 3)
                                
                                let outputName = step.outputName(for: input)
                                Text(outputName)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.green)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
            
            // Shell Commands Block
            if let commands = shellCommands, !commands.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Comando Terminale Eseguito:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    
                    ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                        HStack(alignment: .top, spacing: 6) {
                            Text("$")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                            
                            Text(command)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            
                            Spacer(minLength: 4)
                            
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Copia comando terminale")
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
    
    private func iconForTool(_ tool: String) -> String {
        if tool.hasPrefix("image") { return "photo" }
        if tool.hasPrefix("pdf") { return "doc.text" }
        if tool.hasPrefix("video") { return "film" }
        if tool.hasPrefix("audio") { return "speaker.wave.2" }
        if tool.hasPrefix("file") { return "doc" }
        if tool.hasPrefix("shell") { return "terminal" }
        return "gearshape"
    }
    
    private func humanName(for tool: String) -> String {
        switch tool {
        case "image.convert": return "Converti Immagine"
        case "image.resize": return "Ridimensiona Immagine"
        case "image.rotate": return "Ruota Immagine"
        case "image.thumbnail": return "Crea Miniatura"
        case "image.stripExif": return "Pulisci Metadati EXIF"
        case "pdf.merge": return "Unisci PDF"
        case "pdf.compress": return "Comprimi PDF"
        case "pdf.split": return "Dividi Pagine PDF"
        case "file.select": return "Seleziona nel Finder"
        case "file.rename": return "Rinomina File"
        case "file.zip", "file.compress": return "Crea Archivio ZIP"
        case "video.convert": return "Converti Video"
        case "video.extractAudio": return "Estrai Audio"
        case "shell.calc": return "Calcola Espressione"
        case "shell.run": return "Esegui Comando Shell"
        default: return tool
        }
    }
}
