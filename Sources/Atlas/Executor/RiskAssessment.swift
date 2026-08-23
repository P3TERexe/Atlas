import Foundation

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
        
        for step in graph.steps {
            switch step.tool {
            case "file.rename":
                maxRisk = .high
                // Use the same resolver as the executor so the preview matches
                // what will actually be touched (selection, directories, etc.).
                for fileURL in FileResolver.resolveInputURLs(step: step, context: context) {
                    items.append(PredictedFileItem(url: fileURL, action: .modify, reason: "Rinominato secondo template '\(step.format ?? "")'"))
                }
                
            case "file.trash":
                maxRisk = .high
                for fileURL in FileResolver.resolveInputURLs(step: step, context: context, allowDirectories: true) {
                    items.append(PredictedFileItem(url: fileURL, action: .delete, reason: "Spostamento nel Cestino di macOS"))
                }
                
            case "image.convert":
                for input in step.inputs {
                    let originalURL = dir.appendingPathComponent(input)
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
                for input in step.inputs {
                    let base = (input as NSString).deletingPathExtension
                    let page1URL = dir.appendingPathComponent("\(base)_page_1.pdf")
                    items.append(PredictedFileItem(url: page1URL, action: .create, reason: "Estratte pagine singole da \(input)"))
                }
                
            case "pdf.compress":
                maxRisk = max(maxRisk, .low)
                for input in step.inputs {
                    let base = (input as NSString).deletingPathExtension
                    let targetURL = dir.appendingPathComponent("\(base)-compressed.pdf")
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "PDF ottimizzato"))
                }
                
            case "video.extractAudio":
                maxRisk = max(maxRisk, .low)
                for input in step.inputs {
                    let base = (input as NSString).deletingPathExtension
                    let ext = step.format ?? "m4a"
                    let targetURL = dir.appendingPathComponent("\(base).\(ext)")
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Audio estratto da video"))
                }
                
            case "video.convert":
                maxRisk = max(maxRisk, .low)
                for input in step.inputs {
                    let base = (input as NSString).deletingPathExtension
                    let ext = step.format ?? "mp4"
                    let targetURL = dir.appendingPathComponent("\(base).\(ext)")
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Video convertito"))
                }
                
            case "file.copy":
                maxRisk = max(maxRisk, .low)
                for input in step.inputs {
                    let targetURL = dir.appendingPathComponent("copie").appendingPathComponent(input)
                    items.append(PredictedFileItem(url: targetURL, action: .create, reason: "Creazione di copie multiple in cartella 'copie'"))
                }
                
            case "file.select", "shell.calc":
                // Pure selection / computation — no filesystem modification or risk!
                break
                
            case "shell.run":
                let cmd = step.format ?? step.inputs.joined(separator: " ")
                // Downgrade conservativo: .medium solo se tutti i leader del
                // comando sono non-distruttivi e non ci sono redirezioni;
                // altrimenti resta .high. La reason continua a includere il
                // comando integrale per trasparenza UI.
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
}
