import Foundation
import PDFKit

enum FileActionType: String, Codable {
    case create
    case modify
    case delete
    case move
}

enum RiskLevel: String, Codable, Comparable {
    case none
    case low
    case medium
    case high
    
    private var severity: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
    
    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.severity < rhs.severity
    }
    
    var title: String {
        switch self {
        case .none: return "Nullo"
        case .low: return "Basso"
        case .medium: return "Medio"
        case .high: return "Alto"
        }
    }
    
    var iconName: String {
        switch self {
        case .none: return "shield.slash"
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.shield"
        case .high: return "hand.raised.square"
        }
    }
}

struct PredictedFileItem: Identifiable {
    let id = UUID()
    let url: URL
    let action: FileActionType
    let reason: String
}

struct RiskAssessment {
    let riskLevel: RiskLevel
    let predictedItems: [PredictedFileItem]
    let summaryMessage: String
    
    static func analyze(graph: ActionGraph, context: FinderContext) -> RiskAssessment {
        guard let dir = context.currentDirectory else {
            return RiskAssessment(riskLevel: .none, predictedItems: [], summaryMessage: "Nessun rischio — operazione nel Finder.")
        }
        
        var items: [PredictedFileItem] = []
        var maxRisk: RiskLevel = .none
        
        var declaredOutputs = Set<String>()
        for step in graph.steps {
            switch step.tool {
            case "file.rename":
                maxRisk = .high
                // Same resolver as the executor so preview matches execution.
                let resolved = (try? InputResolver.resolve(step: step, context: context)) ?? []
                for fileURL in resolved {
                    items.append(PredictedFileItem(url: fileURL, action: .modify, reason: "Rinominato secondo template '\(step.format ?? "")'"))
                }
            case "file.trash":
                maxRisk = .high
                let resolved = (try? InputResolver.resolve(step: step, context: context, allowDirectories: true)) ?? []
                for fileURL in resolved {
                    items.append(PredictedFileItem(url: fileURL, action: .delete, reason: "Spostamento nel Cestino di macOS"))
                }
            case "image.convert":
                let resolved = (try? InputResolver.resolve(step: step, context: context, extensions: MediaFormats.image)) ?? []
                for originalURL in resolved {
                    let ext = step.format ?? originalURL.pathExtension
                    let suffix = (step.grayscale == true) ? "_bw" : ""
                    let newName = originalURL.deletingPathExtension().lastPathComponent + suffix + "." + ext
                    let targetURL = dir.appendingPathComponent(newName)
                    if targetURL.path == originalURL.path {
                        maxRisk = max(maxRisk, .medium)
                        items.append(PredictedFileItem(url: targetURL, action: .modify, reason: "Sovrascrizione file originale"))
                    } else {
                        maxRisk = max(maxRisk, .low)
                        items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Generata nuova immagine"))
                    }
                }
            case "file.zip", "file.compress":
                maxRisk = max(maxRisk, .low)
                let archiveName = step.format ?? "archive.zip"
                let targetURL = dir.appendingPathComponent(archiveName)
                items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Creato nuovo archivio ZIP"))
            case "pdf.merge", "pdf.fromImages":
                maxRisk = max(maxRisk, .low)
                let targetURL = dir.appendingPathComponent("merged.pdf")
                items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Unione di file in PDF"))
            case "pdf.split":
                maxRisk = max(maxRisk, .medium)
                let resolved = (try? InputResolver.resolve(step: step, context: context, extensions: ["pdf"])) ?? []
                for input in resolved {
                    let base = input.deletingPathExtension().lastPathComponent
                    let pageCount = Self.pdfPageCount(of: input)
                    if let pageCount {
                        for page in 1...pageCount {
                            items.append(PredictedFileItem(
                                url: dir.appendingPathComponent("\(base)_page_\(page).pdf"),
                                action: .create,
                                reason: "Estratta pagina \(page) da \(input.lastPathComponent)"
                            ))
                        }
                    } else {
                        items.append(PredictedFileItem(
                            url: dir.appendingPathComponent("\(base)_page_*.pdf"),
                            action: .create,
                            reason: "Pagine estratte da \(input.lastPathComponent); numero determinato all'esecuzione"
                        ))
                    }
                }
            case "pdf.compress":
                maxRisk = max(maxRisk, .low)
                let resolved = (try? InputResolver.resolve(step: step, context: context, extensions: ["pdf"])) ?? []
                for input in resolved {
                    let base = input.deletingPathExtension().lastPathComponent
                    let targetURL = dir.appendingPathComponent("\(base)-compressed.pdf")
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "PDF ottimizzato"))
                }
            case "video.extractAudio":
                maxRisk = max(maxRisk, .low)
                let resolved = (try? InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video)) ?? []
                for input in resolved {
                    let base = input.deletingPathExtension().lastPathComponent
                    let ext = step.format ?? "m4a"
                    let targetURL = dir.appendingPathComponent("\(base).\(ext)")
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Audio estratto da video"))
                }
            case "video.convert":
                maxRisk = max(maxRisk, .low)
                let resolved = (try? InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video)) ?? []
                for input in resolved {
                    let base = input.deletingPathExtension().lastPathComponent
                    let ext = step.format ?? "mp4"
                    let targetURL = dir.appendingPathComponent("\(base).\(ext)")
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Video convertito"))
                }
            case "file.copy":
                maxRisk = max(maxRisk, .low)
                let resolved = (try? InputResolver.resolve(step: step, context: context)) ?? []
                for input in resolved {
                    let targetURL = dir.appendingPathComponent("copie").appendingPathComponent(input.lastPathComponent)
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Creazione di copie multiple in cartella 'copie'"))
                }
            case "file.select", "shell.calc":
                break
            case "shell.run":
                let cmd = step.format ?? step.inputs.joined(separator: " ")
                maxRisk = ShellGuard.classify(cmd) ? .medium : .high
                items.append(PredictedFileItem(
                    url: dir.appendingPathComponent("(comando shell)"),
                    action: .modify,
                    reason: "Esegue un comando shell arbitrario: \(cmd)"
                ))
            default:
                maxRisk = max(maxRisk, .medium)
                items.append(PredictedFileItem(
                    url: dir.appendingPathComponent("(strumento sconosciuto)"),
                    action: .modify,
                    reason: "Strumento non riconosciuto: \(step.tool)"
                ))
            }
            for input in step.inputs where declaredOutputs.contains(input) {
                items.append(PredictedFileItem(
                    url: dir.appendingPathComponent(input),
                    action: .create,
                    reason: "Output dello step precedente, verificato all'esecuzione"
                ))
            }
            if let outputName = Self.declaredOutputName(for: step) {
                declaredOutputs.insert(outputName)
            }
        }
        
        let summary: String
        switch maxRisk {
        case .none:
            summary = "Nessun rischio — operazione di sola lettura o selezione elementi nel Finder."
        case .low:
            summary = "Operazione sicura — verranno creati nuovi file senza sovrascrizioni."
        case .medium:
            summary = "Operazione moderata — genererà file multipli o possibili sovrascrizioni."
        case .high:
            summary = "Attenzione: l'operazione modificherà file esistenti direttamente."
        }
        
        return RiskAssessment(riskLevel: maxRisk, predictedItems: items, summaryMessage: summary)
    }

    /// Output file name a step declares for conversion-style tools, or nil.
    private static func declaredOutputName(for step: ActionStep) -> String? {
        guard let format = step.format, !format.isEmpty else { return nil }
        return step.inputs.map { $0 as NSString }.map { $0.deletingPathExtension + "." + format }.first
    }

    /// Number of pages in a local PDF, used to enumerate split outputs in the preview.
    private static func pdfPageCount(of url: URL) -> Int? {
        guard let document = PDFDocument(url: url) else { return nil }
        let count = document.pageCount
        return count > 0 ? count : nil
    }
}
