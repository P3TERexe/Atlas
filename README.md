# Atlas

> Natural language interface for your filesystem.

Atlas è una command palette globale per macOS che ti permette di descrivere operazioni sui file in italiano (o in qualsiasi lingua) e le esegue in modo sicuro, con anteprima e undo.

---

## Obiettivo

Eliminare il gap tra **quello che vuoi fare** e **come farlo**.

Invece di ricordarti i flag di `sips`, `ffmpeg` o `pandoc`, apri Atlas e scrivi:

```
converti tutte le immagini in webp
```

Atlas capisce il contesto (dove sei, cosa hai selezionato), costruisce un piano strutturato, te lo mostra per approvazione, e lo esegue.

---

## Comportamento desiderato

### Attivazione
- Atlas porta automaticamente il Finder in primo piano alla pressione della scorciatoia
- Scorciatoia globale: `⌥ Space`
- L'overlay è un pannello flottante con sfondo frosted glass, oppure una finestra macOS standard configurabile nelle Impostazioni

### Flusso principale

```
1. Apri Finder su una cartella con file
2. Seleziona i file su cui lavorare (opzionale)
3. Premi ⌥ Space
4. Scrivi cosa vuoi fare in linguaggio naturale
5. Atlas analizza la richiesta e mostra un piano (anteprima con comandi terminale completi e badge di rischio)
6. Confermi → Atlas esegue con barra di progresso in tempo reale
7. Se qualcosa va storto → ⌘⇧Z per annullare tutto
```

### Anteprima ed Esecuzione Istantanea
- **Operazioni a Rischio Nullo** (`file.select`, `shell.calc`): Vengono eseguite **istantaneamente a 0ms** senza schermate intermedie.
- **Operazioni con Modifiche**: Atlas ti mostra sempre l'anteprima completa prima di eseguire:
  - Quali file verranno toccati e l'esatto comando da terminale (multi-linea senza tagli)
  - Livello di rischio valutato (Basso / Medio / Alto)

### Undo transazionale

Ogni operazione crea una `Transaction` che traccia:
- I file **creati** (possono essere eliminati per rollback)
- I file **modificati** (vengono salvati in backup prima)
- I file **spostati nel Cestino** (vengono ripristinati nella posizione originale)

`⌘⇧Z` inverte l'ultima transazione completata.

---

## Funzioni

### Sprint 1 — MVP ✅

| Funzione | Stato |
|----------|-------|
| Overlay globale (`⌥ Space`) con auto-attivazione Finder | ✅ |
| Attivazione e lettura contesto Finder (cartella, selezione, file visibili) | ✅ |
| Pianificazione con Apple Foundation Models | ✅ |
| Fallback Ollama locale | ✅ |
| Selettore modello AI nella UI | ✅ |
| Anteprima piano prima dell'esecuzione | ✅ |
| Esecuzione via Plugin SDK | ✅ |
| Plugin ImagePlugin (conversione immagini via `ImageIO` e `sips`) | ✅ |
| Pannello Impostazioni & API Keys (Keychain + Ollama/OpenAI/Claude/NVIDIA/OpenCode AI) | ✅ |
| Undo transazionale (`⌘⇧Z`) | ✅ |
| Progress in tempo reale con indicazione del singolo file | ✅ |
| Suggerimenti contestuali cliccabili | ✅ |

### Sprint 2 — Core Plugins & Multi-Plugin Pipeline ✅

| Funzione | Stato |
|----------|-------|
| Plugin PDF (merge, split, compress, `pdf.fromImages` da Immagini a PDF nativo) | ✅ |
| Cronologia operazioni (persistente, Cmd+H nella palette, riesecuzione ed undo selettivo) | ✅ |
| Barra di progresso dettagliata in tempo reale con % e nome file | ✅ |
| Plugin Video (estrai audio m4a/mp3, converti mp4/mov) | ✅ |
| Plugin File (rinomina batch con template, zip, comprimi, `file.trash` Cestino nativo) | ✅ |
| Pipeline multi-step (DAG con dipendenze) | ✅ |
| Provider OpenCode AI (Zen API) + NVIDIA + Base URL Custom | ✅ |

### Sprint 3 — Substage Parity & Advanced Capabilities ✅

| Funzione | Stato |
|----------|-------|
| **Instant Actions (0ms)**: Parser locale deterministico per shorthand (`jpg`, `png`, `zip`, `mp3`, `bw`, `immagini in pdf`, `seleziona foto`, etc.) | ✅ |
| **Controllo Dinamico Thinking AI & Indicatore UI**: Soppressione del *thinking* per query dirette e badge visivo dinamico (`⚡ Veloce (0ms)` vs `🧠 Ragionamento AI`) per query complesse | ✅ |
| **Risk Assessment & Risk Level None**: Livelli di rischio (Nullo/Basso/Medio/Alto) con auto-esecuzione a 0ms per azioni di sola lettura | ✅ |
| **Cestino macOS Sicuro (`file.trash`)**: Spostamento nativo nel Cestino con `trashItem` e rollback completo | ✅ |
| **Comandi Shell Generici e Filtri di Sicurezza (`shell.run`)**: Esecuzione aperta di comandi `zsh` con blocco automatico dei comandi distruttivi (`sudo`, `rm -rf /`, `rm -rf ~`) | ✅ |
| **Visualizzazione Comandi Lunghi Multi-Linea**: Multi-line wrapping completo nell'anteprima senza tagli o troncamenti | ✅ |
| **Modalità Finestra Vera vs Overlay HUD**: Opzione configurabile nelle impostazioni dell'app | ✅ |
| **Rules System**: Regole e preferenze utente personalizzate persistenti (`rules.json` + iniezione nel prompt) | ✅ |
| **PlanValidator & Autocorrezione**: Validazione aderenza query/formato con ciclo di retry ed estrazione estensione file | ✅ |
| **Rollback Selettivo**: Annullamento arbitrario di qualsiasi transazione storica dal menu Cronologia | ✅ |
| **Esecuzione CLI Asincrona (`AsyncProcessRunner`)**: Processi fuori dal MainActor per UI sempre fluida | ✅ |
| **Plugin Shell**: Calcolatrice ad alta precisione `shell.calc` (`bc`) ed esecutore shell generico | ✅ |
| **ImagePlugin Avanzato**: Resize, rotazione, miniature, EXIF e conversione in Bianco e Nero (`grayscale`) | ✅ |
| **Navigazione Cronologia Tasti Frecce (↑/↓)**: Cycling stile terminale delle query precedenti | ✅ |

---

## To-Do e Roadmap

### ✅ Funzionalità Completate Recenti
- [x] **Controllo Dinamico Thinking AI & Indicatore Visivo UI**: Disabilitazione automatica del ragionamento per risposte sotto i 0.5s su richieste semplici e badge visivo dinamico (`⚡ Veloce (0ms)` / `🧠 Ragionamento AI`). ✅
- [x] **Integrazione OpenCode AI (Zen API)**: Supporto nativo per i modelli OpenCode (`deepseek-v4-flash-free`, `big-pickle`, `deepseek-v4-pro`, etc.) con gestione API key nel Keychain. ✅
- [x] **Livello di Rischio Nullo (`RiskLevel.none`) & Esecuzione Istantanea 0ms**: Esecuzione senza schermata di anteprima per operazioni di lettura o selezione. ✅
- [x] **Comandi Shell Generici (`shell.run`) & Guardiani di Sicurezza**: Supporto per qualsiasi richiesta aperta con blocco automatico dei comandi distruttivi per la sicurezza dell'utente (`sudo`, `rm -rf /`). ✅
- [x] **Eliminazione Sicura via Cestino (`file.trash`)**: Spostamento nel Cestino di macOS con supporto al ripristino ed all'Undo (`Cmd+Z`). ✅
- [x] **Barra di Progresso Granulare in Tempo Reale**: Percentuale numerica esatta, animazione fluida ed etichetta del singolo file in lavorazione (`⚙️ Elaborazione 4/10: foto_4.png`). ✅
- [x] **Visualizzazione Comandi Lunghi Multi-Linea**: Text wrapping completo nell'anteprima per ispezionare integralmente qualsiasi comando terminale generato. ✅
- [x] **Stile Finestra Personalizzabile**: Opzione per scegliere tra Finestra macOS Standard e Panel Overlay HUD nelle Impostazioni. ✅
- [x] **Shortcut Tastiera Personalizzabile**: Consentire all'utente di cambiare la scorciatoia di attivazione globale nelle Impostazioni (tramite `KeyboardShortcuts.Recorder`). ✅
- [x] **Redesign completo dell'interfaccia UI**: De-clutter visivo, barra input minimalista, menu `⋯` compatto, banner contesto auto-espandibile e provider nelle impostazioni a sezioni fisarmonica (`ProviderSection`). ✅

### 🔴 Da Fare Futuro (Backend & SDK)
- [ ] **Native Tool Calling / Function Calling**: Supporto della specifica OpenAI `tools`/`functions` invece dell'output JSON via prompt.
- [ ] **Plugin SDK Pubblico & Homebrew Cask**: Struttura modulare per plugin di terze parti e pacchetto di distribuzione.
- [ ] **Riconoscimento Immagini Nativo Apple per Rinomina File**: Attualmente la rinomina basata sul contenuto delle immagini funziona soltanto tramite OCR (`image.ocrRename` / `VNRecognizeTextRequest`). Indagare se è possibile estenderla al riconoscimento degli oggetti e della scena nativo di Apple (`VNClassifyImageRequest`) per rinominare automaticamente i file in base a ciò che raffigurano.

---

## Architettura

```
⌥ Space (Auto-attiva Finder)
    │
    ▼
OverlayWindowController        ← NSPanel flottante o Finestra macOS Standard
    │
    ▼
FinderContextProvider          ← AppleScript → cartella corrente + selezione
    │
    ▼
PromptBuilder                  ← Assembla il prompt con contesto + tool registry
    │
    ▼
Planner ──────────────────────► AppleModelProvider      (default, @Generable)
                                 OpenCodeModelProvider   (OpenCode AI Zen API)
                                 OllamaModelProvider     (fallback locale)
                                 OpenAI / Claude / NVIDIA / Custom Provider
    │
    ▼
ActionGraph                    ← Struct Swift tipizzata, DAG di step
    │
    ▼
ExecutorFramework              ← Dispatch topologico, progress callback per file
    │
    ├── ToolRegistry           ← Registro dichiarativo dei plugin
    │
    ├── ImagePlugin            ← image.convert / resize / rotate / thumbnail / EXIF
    ├── PDFPlugin              ← pdf.merge/split/compress + pdf.fromImages (PDFKit)
    ├── VideoPlugin            ← video.extractAudio + video.convert
    ├── FilePlugin             ← file.rename/zip/compress/select/trash
    └── ShellPlugin            ← shell.calc (bc) + shell.run (comandi zsh flessibili)
    │
    ▼
Transaction + UndoManager      ← Traccia file creati/modificati/cestinati, rollback
    │
    ▼
HistoryStore                  ← Cronologia persistente (history.json)
```

---

## Build & Run

```bash
cd /Users/pepe/Stuff/Substage/Atlas

# Build + installa in /Applications/Atlas.app
make install

# Build + package + firma + apri
make run

# Solo build
make build
```

---

## Struttura del progetto

```
Atlas/
├── Package.swift
├── Makefile
├── Info.plist
├── Atlas.entitlements
└── Sources/Atlas/
    ├── AtlasApp.swift                    ← @main, hotkey, AppDelegate, auto-Finder
    ├── Context/
    │   ├── FinderContext.swift           ← Model: cartella, selezione, tools
    │   └── FinderContextProvider.swift   ← Lettura via AppleScript
    ├── Planner/
    │   ├── ActionGraph.swift             ← DAG di ActionStep
    │   ├── InstantActionParser.swift     ← Parser locale 0ms per shorthand
    │   ├── ModelProvider.swift           ← Provider: Apple/OpenCode/Ollama/OpenAI/Claude/NVIDIA
    │   ├── PlanValidator.swift           ← Validazione aderenza query/formati
    │   ├── Planner.swift                 ← Coordinatore del piano
    │   └── PromptBuilder.swift           ← System prompt e compact prompt
    ├── Executor/
    │   ├── ExecutorFramework.swift       ← Progress callbacks per file, dispatch topologico
    │   ├── RiskAssessment.swift          ← Simulazione impatto file e livelli di rischio (Nullo..Alto)
    │   ├── ToolRegistry.swift            ← Registro plugin
    │   ├── Transaction.swift             ← Backup + rollback (Codable)
    │   ├── HistoryStore.swift            ← Cronologia persistente (JSON)
    │   └── UndoManager.swift             ← Gestione ⌘⇧Z e Cestino
    ├── Plugins/
    │   ├── Plugin.swift                  ← ItemProgressCallback, AtlasPlugin, ActionExecutor
    │   ├── ImagePlugin/ImagePlugin.swift ← image.convert/resize/rotate/thumbnail/stripExif
    │   ├── PDFPlugin/PDFPlugin.swift     ← pdf.merge/split/compress + pdf.fromImages
    │   ├── VideoPlugin/VideoPlugin.swift ← video.extractAudio/convert
    │   ├── FilePlugin/FilePlugin.swift   ← file.rename/zip/compress/select/trash
    │   └── ShellPlugin/ShellPlugin.swift ← shell.calc/run
    └── Overlay/
        ├── OverlayWindowController.swift ← NSPanel flottante / Finestra Standard toggle
        ├── CommandPaletteView.swift      ← UI principale, selettore modello, barra progress
        ├── PreviewView.swift             ← Anteprima piano, multi-line command wrapping
        ├── SettingsView.swift            ← Configurazione provider, Keychain, OpenCode AI, Stile Finestra
        ├── HistoryView.swift             ← Cronologia ed Undo selettivo
        └── DebugContextView.swift        ← Log prompt/risposta
```
