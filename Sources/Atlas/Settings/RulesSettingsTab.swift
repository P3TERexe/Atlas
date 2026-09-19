import SwiftUI

struct RulesSettingsTab: View {
    @ObservedObject var rulesStore: RulesStore
    
    @State private var newTrigger: String = ""
    @State private var newInstruction: String = ""
    @State private var newFolderFilter: String = ""
    @State private var isAddingRule: Bool = false
    @State private var showValidationError: Bool = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Regole di Automazione Prompt")
                        .font(.headline)
                    Text("Le regole aggiungono automaticamente istruzioni dettagliate al modello AI quando la richiesta contiene una determinata parola chiave o quando operi in una specifica cartella.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Regole Attive") {
                if rulesStore.rules.isEmpty {
                    Text("Nessuna regola configurata. Aggiungi la tua prima regola qui sotto.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(rulesStore.rules) { rule in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { rule.isEnabled },
                                set: { _ in rulesStore.toggle(id: rule.id) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(rule.trigger)
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundColor(.accentColor)
                                        .cornerRadius(4)

                                    if let folder = rule.folderFilter, !folder.isEmpty {
                                        HStack(spacing: 3) {
                                            Image(systemName: "folder")
                                                .font(.caption2)
                                            Text(folder)
                                                .font(.caption2)
                                        }
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12))
                                        .cornerRadius(4)
                                    }
                                }

                                Text(rule.instruction)
                                    .font(.system(size: 12))
                                    .foregroundColor(rule.isEnabled ? .primary : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer()

                            Button(action: {
                                rulesStore.delete(id: rule.id)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                            .help("Elimina regola")
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Nuova Regola") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Trigger:")
                            .font(.caption.bold())
                            .frame(width: 80, alignment: .leading)
                        TextField("es. youtube, podcast, webp", text: $newTrigger)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Istruzione:")
                            .font(.caption.bold())
                            .frame(width: 80, alignment: .leading)
                        TextField("es. Esporta a 1080p 30fps codec H.264", text: $newInstruction)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Cartella:")
                            .font(.caption.bold())
                            .frame(width: 80, alignment: .leading)
                        TextField("Opzionale (es. Video, Download)", text: $newFolderFilter)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Spacer()
                        Button("Aggiungi Regola") {
                            addRule()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newTrigger.trimmingCharacters(in: .whitespaces).isEmpty || newInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func addRule() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        let instruction = newInstruction.trimmingCharacters(in: .whitespaces)
        let folder = newFolderFilter.trimmingCharacters(in: .whitespaces)
        
        guard !trigger.isEmpty && !instruction.isEmpty else { return }
        
        let rule = UserRule(
            trigger: trigger,
            instruction: instruction,
            folderFilter: folder.isEmpty ? nil : folder,
            isEnabled: true
        )
        rulesStore.add(rule: rule)
        
        // Reset form
        newTrigger = ""
        newInstruction = ""
        newFolderFilter = ""
    }
}
