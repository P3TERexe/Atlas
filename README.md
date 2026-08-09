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

- Atlas si attiva **solo quando Finder è l'app in primo piano**
- Scorciatoia globale: `⌥ Space`
- Se Finder non è attivo, la scorciatoia non fa nulla
- L'overlay è un pannello flottante, senza bordi, con sfondo frosted glass

### Flusso principale

```
1. Apri Finder su una cartella con file
2. Seleziona i file su cui lavorare (opzionale)
3. Premi ⌥ Space
4. Scrivi cosa vuoi fare in linguaggio naturale
5. Atlas analizza la richiesta e mostra un piano (anteprima)
6. Confermi → Atlas esegue
7. Se qualcosa va storto → ⌘⇧Z per annullare tutto
```

### Anteprima obbligatoria

Atlas **non esegue mai direttamente** un comando senza mostrarti prima:
- Quali file verranno toccati
- In quale formato/modalità
- Parametri rilevati (qualità, destinazione, ecc.)

Solo dopo la tua conferma esplicita ([Esegui]) Atlas procede.

### Undo transazionale

Ogni operazione crea una `Transaction` che traccia:
- I file **creati** (possono essere eliminati per rollback)
- I file **modificati** (vengono salvati in backup prima)

`⌘⇧Z` inverte l'ultima transazione completata.

---

## Funzioni

### Sprint 1 — MVP ✅

| Funzione | Stato |
|----------|-------|
| Overlay globale (`⌥ Space`) | ✅ |
| Attivazione solo da Finder | ✅ |
| Lettura contesto Finder (cartella, selezione) | ✅ |
| Pianificazione con Apple Foundation Models | ✅ |
| Fallback Ollama locale | ✅ |
| Selettore modello AI nella UI | ✅ |
| Anteprima piano prima dell'esecuzione | ✅ |
| Esecuzione via Plugin SDK | ✅ |
| Plugin ImagePlugin (conversione immagini via `sips`) | ✅ |
| Pannello Impostazioni & API Keys (Keychain + Ollama/OpenAI/Claude/NVIDIA) | ✅ |
| Undo transazionale (`⌘⇧Z`) | ✅ |
| Progress in tempo reale | ✅ |
| Suggerimenti contestuali cliccabili | ✅ |

### Sprint 2 — Completato ✅

| Funzione | Stato |
|----------|-------|
| Plugin PDF (merge, split, compress) | ✅ |
| Cronologia operazioni (persistente, Cmd+H nella palette) | ✅ |
| Barra di progresso dettagliata (step per step) | ✅ |
| Plugin Video (estrai audio m4a/mp3, converti mp4/mov) | ✅ |
| Plugin File (rinomina batch con template, zip, comprimi) | ✅ |
| Pipeline multi-step (DAG con dipendenze) | ✅ |
| Provider NVIDIA + base URL custom | ✅ |

### Sprint 3 — Substage Parity & Advanced Capabilities ✅

| Funzione | Stato |
|----------|-------|
| **Instant Actions (0ms)**: Parser locale deterministico per shorthand (`jpg`, `png`, `zip`, `mp3`, `bw`, etc.) | ✅ |
| **Risk Assessment**: Simulazione impatto file e badge di rischio (Basso/Medio/Alto) prima dell'esecuzione | ✅ |
| **Rules System**: Regole e preferenze utente personalizzate persistenti (`rules.json` + iniezione nel prompt) | ✅ |
| **PlanValidator & Autocorrezione**: Validazione aderenza query/formato con ciclo di retry automatico | ✅ |
| **Rollback Selettivo**: Annullamento arbitrario di qualsiasi transazione storica dal menu Cronologia | ✅ |
| **Esecuzione CLI Asincrona (`AsyncProcessRunner`)**: Processi fuori dal MainActor per UI sempre fluida | ✅ |
| **Plugin Shell**: Calcolatrice ad alta precisione `shell.calc` (`bc`) ed esecutore shell trasparent `shell.run` | ✅ |
| **ImagePlugin Avanzato**: Resize (`image.resize`), rotazione (`image.rotate`), miniature (`image.thumbnail`), EXIF (`image.stripExif`) | ✅ |
| **Selezione Finder**: Evidenziazione diretta file nel Finder (`file.select`) | ✅ |
| **Zip Ricorsivo Cartelle**: Supporto compressione gerarchia directory (`zip -r`) | ✅ |
| **Navigazione Cronologia Tasti Frecce (↑/↓)**: Cycling stile terminale delle query precedenti | ✅ |

---

## To-Do e Roadmap

### ✅ Funzionalità Completate Recenti
- [x] **Funzioni Complesse & Pipeline Multi-Plugin**: Esecuzione diretta di workflow multi-formato (es. *"prendi tutte le immagini selezionate e mettile in un unico PDF"*, `pdf.fromImages` a 0ms nativo). ✅
- [x] **Instant Actions (Parser Locale 0ms)**: Esecuzione istantanea senza latenza LLM per comandi deterministici. ✅
- [x] **Risk Assessment & Prediction**: Simulazione visiva dell'impatto sui file e badge del livello di rischio nell'anteprima. ✅
- [x] **User Rules System**: Gestione regole utente con iniezione dinamica nel prompt dell'AI. ✅
- [x] **Rollback Selettivo dalla Cronologia**: Annullamento arbitrario di qualsiasi transazione passata via Cmd+H. ✅
- [x] **Fix Process Bloccante su MainActor**: Esecuzione CLI asincrona con `Task.detached` + `AsyncProcessRunner`. ✅
- [x] **Plugin Shell & Calcolatrice**: Calcoli deterministici via `bc` ed esecuzione shell generica. ✅
- [x] **ImagePlugin Avanzato**: Ridimensionamento, rotazione, miniature e pulizia EXIF. ✅
- [x] **Supporto Cartelle per Zip (`file.zip`/`file.compress`)**: Compressione ricorsiva directory con `zip -r`. ✅
- [x] **Navigazione Cronologia Comandi (Frecce ↑/↓)**: Navigazione query precedenti con tasti freccia. ✅
- [x] **Smart Multi-File Resolution**: Risolzione automatica di tutti i file selezionati in Finder. ✅

### 🔴 Da Fare Futuro
- [ ] **Native Tool Calling / Function Calling**: Supporto della specifica OpenAI `tools`/`functions` invece dell'output JSON via prompt.
- [ ] **Shortcut Tastiera Personalizzabile**: Consentire all'utente di cambiare la scorciatoia di attivazione (oggi fissa su `⌥ Space`).
- [ ] **Plugin SDK Pubblico & Homebrew Cask**: Struttura modulare per plugin di terze parti e pacchetto di distribuzione.

---

## Architettura

```
⌥ Space
    │
    ▼
OverlayWindowController        ← NSPanel flottante, dark mode, frosted glass
    │
    ▼
FinderContextProvider          ← AppleScript → cartella corrente + selezione
    │
    ▼
PromptBuilder                  ← Assembla il prompt con contesto + tool registry
    │
    ▼
Planner ──────────────────────► AppleModelProvider   (default, @Generable)
                                 OllamaModelProvider  (fallback locale)
                                 OpenAIModelProvider  (placeholder)
    │
    ▼
ActionGraph                    ← Struct Swift tipizzata (@Generable), DAG di step
    │
    ▼
ExecutorFramework              ← Dispatch topologico, progress callback
    │
    ├── ToolRegistry           ← Registro dichiarativo dei plugin
    │
    ├── ImagePlugin            ← image.convert (ImageIO + sips/ffmpeg fallback)
    ├── PDFPlugin              ← pdf.merge/split (PDFKit) + pdf.compress (gs/magick)
    ├── VideoPlugin            ← video.extractAudio (AVFoundation/ffmpeg) + video.convert
    └── FilePlugin             ← file.rename/zip/compress
    │
    ▼
Transaction + UndoManager      ← Traccia file creati/modificati, rollback
    │
    ▼
HistoryStore                  ← Cronologia persistente (history.json)
```

### Principio chiave

> L'LLM decide **cosa** fare (produce un `ActionGraph`).  
> L'Executor decide **come** farlo (sceglie il tool corretto).

Il modello non vede mai i dettagli di implementazione (`sips`, `ffmpeg`, ecc.).
Questo rende il sistema sicuro, testabile e indipendente dal modello AI usato.

---

## Plugin SDK

Ogni plugin espone `ToolCapability`:

```swift
ToolCapability(
    id: "image.convert",
    description: "Converts images between formats",
    inputFormats: ["png", "jpg", "heic"],
    outputFormats: ["webp", "jpg", "png"],
    executor: ConvertImageAction()
)
```

Implementare `ActionExecutor`:

```swift
protocol ActionExecutor: Sendable {
    func validate(step: ActionStep, context: FinderContext) throws
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult
}
```

---

## AI: Apple Foundation Models

Il modello di default è **Apple Foundation Models** (on-device, privato, nessuna API key).

Le strutture dati usano il macro `@Generable` di Apple per garantire output strutturato
senza parsing JSON manuale:

```swift
@Generable
struct ActionGraph {
    @Guide(description: "Ordered list of actions to execute")
    var steps: [ActionStep]
}
```

**Requisiti**: macOS 26+ su Apple Silicon con Apple Intelligence attivo.  
**Fallback**: Ollama locale (selezionabile nell'UI).

---

## Stack tecnico

| Layer | Tecnologia |
|-------|-----------|
| UI | SwiftUI + AppKit (NSPanel) |
| Hotkey globale | KeyboardShortcuts (sindresorhus) |
| Contesto Finder | NSAppleScript (AppleScript) |
| AI primario | Apple Foundation Models (`FoundationModels`) |
| AI fallback | Ollama REST API locale |
| Executor | Swift Process (`sips`, `ffmpeg`, ecc.) |
| Build | Swift Package Manager + Makefile |

---

## Build & Run

```bash
cd /Users/pepe/Stuff/Substage/Atlas

# Build + package + firma + apri
make run

# Solo build
make build

# Pulizia
make clean
```

**Requisiti**:
- macOS 26+ (Tahoe)
- Xcode 26 / Swift 6.2+
- Apple Silicon (per Apple Intelligence)

---

## Struttura del progetto

```
Atlas/
├── Package.swift
├── Makefile
├── Info.plist
├── Atlas.entitlements
└── Sources/Atlas/
    ├── AtlasApp.swift                    ← @main, hotkey, AppDelegate
    ├── Context/
    │   ├── FinderContext.swift           ← Model: cartella, selezione, tools
    │   └── FinderContextProvider.swift   ← Lettura via AppleScript
    ├── Planner/
    │   ├── ActionGraph.swift             ← @Generable DAG di ActionStep
    │   ├── ModelProvider.swift           ← Protocollo + Apple/Ollama/OpenAI/Claude/NVIDIA
    │   ├── Planner.swift                 ← Coordinatore, delega al provider
    │   └── PromptBuilder.swift           ← Assembla il system prompt
    ├── Executor/
    │   ├── ExecutorFramework.swift       ← Dispatch topologico, progress callback
    │   ├── ToolRegistry.swift            ← Registro plugin
    │   ├── Transaction.swift             ← Backup + rollback (Codable)
    │   ├── HistoryStore.swift            ← Cronologia persistente (JSON)
    │   └── UndoManager.swift             ← Gestione ⌘⇧Z
    ├── Plugins/
    │   ├── Plugin.swift                  ← Protocolli: AtlasPlugin, ActionExecutor
    │   ├── ImagePlugin/ImagePlugin.swift ← image.convert
    │   ├── PDFPlugin/PDFPlugin.swift     ← pdf.merge/split/compress
    │   ├── VideoPlugin/VideoPlugin.swift ← video.extractAudio/convert
    │   └── FilePlugin/FilePlugin.swift   ← file.rename/zip/compress
    └── Overlay/
        ├── OverlayWindowController.swift ← NSPanel, animazioni, focus
        ├── CommandPaletteView.swift      ← UI principale + selettore modello
        ├── PreviewView.swift             ← Anteprima piano prima dell'esecuzione
        ├── HistoryView.swift             ← Cronologia operazioni
        └── DebugContextView.swift        ← Log prompt/risposta
```
