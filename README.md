# Atlas

[![CI](https://github.com/P3TERexe/Atlas/actions/workflows/ci.yml/badge.svg)](https://github.com/P3TERexe/Atlas/actions/workflows/ci.yml)

> Natural language interface for your filesystem.

Atlas è una command palette globale per macOS che ti permette di descrivere operazioni sui file in italiano (o in qualsiasi lingua) e le esegue in modo sicuro, con anteprima del piano e undo transazionale.

---

## Descrizione del progetto

Atlas elimina il gap tra **quello che vuoi fare** e **come farlo**. Invece di ricordarti i flag di `sips`, `ffmpeg` o `pandoc`, premi `⌥ Space` e scrivi:

```
converti tutte le immagini in webp
```

Il flusso è:

```
1. Apri Finder su una cartella con file
2. Seleziona i file su cui lavorare (opzionale)
3. Premi ⌥ Space  →  Atlas porta il Finder in primo piano
4. Scrivi cosa vuoi fare in linguaggio naturale
5. Atlas analizza la richiesta (parser locale 0ms o LLM) e mostra un piano
   con anteprima dei comandi e badge di rischio
6. Confermi → esecuzione con barra di progresso in tempo reale
7. Se qualcosa va storto → ⌘⇧Z annulla l'ultima transazione
```

### Architettura

```
⌥ Space (Auto-attiva Finder)
    │
    ▼
OverlayWindowController        ← NSPanel flottante o Finestra macOS Standard
    │
    ▼
FinderContextProvider          ← osascript → cartella corrente + selezione
    │
    ▼
Planner ── InstantActionParser ← parser locale deterministico (0ms)
    │       └──────────────►   AppleModelProvider      (default, @Generable)
                               OpenCodeModelProvider   (Zen API)
                               OllamaModelProvider     (fallback locale)
                               OpenAI / Claude / NVIDIA / Custom
    │
    ▼
ActionGraph                    ← DAG di step tipizzati
    │
    ▼
ExecutorFramework              ← dispatch topologico, progress per file
    ├── ImagePlugin            ← image.convert / resize / rotate / grayscale
    ├── PDFPlugin              ← pdf.merge/split/compress/fromImages (PDFKit)
    ├── VideoPlugin            ← video.extractAudio/convert (ffmpeg)
    ├── FilePlugin             ← file.rename/zip/compress/select/trash/copy
    └── ShellPlugin            ← shell.calc (bc) + shell.run (guardie di sicurezza)
    │
    ▼
Transaction + UndoManager      ← backup, rollback, Cestino
    │
    ▼
HistoryStore                   ← cronologia persistente (history.json)
```

---

## ✅ Feature funzionanti

### Core
- **Overlay globale (`⌥ Space`)** con auto-attivazione del Finder e scorciatoia personalizzabile (`KeyboardShortcuts.Recorder`)
- **Contesto Finder automatico**: cartella corrente, selezione e file visibili letti via `osascript`
- **Instant Actions (0ms)**: parser locale per shorthand diretti (`jpg`, `png`, `webp`, `zip`, `mp3`, `bw`, `immagini in pdf`, `seleziona foto`…) senza latenza LLM
- **Pianificazione LLM** con Apple Foundation Models (default), Ollama locale (fallback), OpenAI, NVIDIA Build, OpenCode AI (Zen) e provider custom OpenAI-compatible
- **Anteprima piano prima dell'esecuzione**: file coinvolti, comando terminale completo multi-linea, badge di rischio (Nullo/Basso/Medio/Alto)
- **Esecuzione istantanea senza anteprima** per operazioni a rischio nullo (`file.select`, `shell.calc`)
- **Undo transazionale (`⌘⇧Z`)**: ogni operazione crea una `Transaction` con backup dei file modificati e tracking dei file creati; rollback verificato e protetto contro doppie annullazioni
- **Cestino macOS sicuro (`file.trash`)** via `trashItem`, ripristinabile con undo
- **Cronologia persistente** (`history.json`, `⌘H`): riesecuzione e rollback selettivo di qualsiasi transazione storica, sincronizzata con l'undo globale

### Plugin
- **ImagePlugin**: conversione formati, resize, rotazione, miniature, rimozione EXIF, bianco e nero
- **PDFPlugin**: merge, split, compressione, generazione PDF da immagini (PDFKit nativo)
- **VideoPlugin**: estrazione audio (m4a/mp3), conversione mp4/mov (richiede ffmpeg installato)
- **FilePlugin**: rinomina batch con template (`vacanza_#.jpg`), zip singolo/per-file, selezione nel Finder (anche migliaia di file), copie multiple in cartella
- **ShellPlugin**: calcolatrice ad alta precisione (`bc`) ed esecuzione comandi shell generici con analisi di sicurezza token-aware (blocco `rm -rf` in ogni variante, `sudo`, pipe-to-shell, command substitution, ecc.)

### UI & Extra
- Barra di progresso granulare in tempo reale (% e nome del file in lavorazione)
- Pipeline multi-step con DAG e dipendenze tra step
- Rules System: regole utente persistenti (`rules.json`) iniettate nel prompt
- API key salvate nel **Keychain** (con write debounced)
- Modalità Finestra standard vs Overlay HUD configurabile
- Navigazione cronologia query con frecce ↑/↓
- Esecuzione CLI asincrona con cancellazione reale dei processi (SIGTERM), timeout e drenaggio concorrente delle pipe

---

## ⚠️ Feature non funzionanti / limitazioni note

### Da verificare dopo l'ultimo refactor
- **Provider Claude**: l'autenticazione era rotta (`x-api-key` malformato) ed è stata corretta, **ma non è ancora stata testata contro l'API reale**
- **Undo del rename batch**: precedentemente non ripristinava il nome originale; corretto nei fix recenti, da validare end-to-end

### Limiti strutturali noti
- **Sicurezza di `shell.run` rafforzata ma non assoluta**: policy allowlist per-binario (`ShellGuard`, interpreti/wrapper esclusi) + esecuzione in `sandbox-exec` con scrittura consentita solo nella cartella di lavoro quando il sistema applica i filtri; sui sistemi che li ignorano si gira solo con l'allowlist
- **Native Tool Calling dove disponibile**: OpenAI/Claude/NVIDIA/Zen/Custom forzano `tools`+`tool_choice` sullo schema del piano e Ollama usa structured output; il fallback prompt-JSON con `ActionGraphParser` resta attivo per endpoint che ignorano i tools
- **PlanValidator euristico**: keyword hardcodate solo italiano/inglese; una parola chiave dentro un nome file può falsare la validazione
- **Anteprima rischio approssimativa** per i tool diversi da `file.rename`/`file.trash`: per gli altri step i percorsi previsti sono ricostruiti e potrebbero differire dalla selezione reale
- **Permessi Automazione (TCC)**: se l'utente nega ad Atlas il controllo di Finder, il fallback silenzioso opera sul Desktop senza avviso esplicito
- **Dipendenze esterne opzionali non rilevate a runtime in modo esaustivo**: `ffmpeg` viene cercato solo in `/opt/homebrew/bin` e `/usr/local/bin`

### Non ancora implementato (roadmap)
- [ ] Plugin SDK pubblico per plugin di terze parti
- [ ] Distribuzione via Homebrew Cask
- [ ] Riconoscimento contenuti immagini nativo Apple per rinomina basata sulla scena (oggi solo OCR via `VNRecognizeTextRequest`)

### Requisiti
- **macOS 26+** (requisito molto restrittivo in `Package.swift`, da valutare l'abbassamento)
- Apple Intelligence disponibile per il provider default; altrimenti configurare Ollama o un provider con API key

---

## Build & Run

```bash
cd Atlas

make build     # solo build release
make run       # build + package + firma adhoc + apri
make install   # build + installa in /Applications/Atlas.app

swift test     # suite di test (parser, plugin, sicurezza, rollback)
```

## Struttura del progetto

```
Atlas/
├── Package.swift
├── Makefile
├── Info.plist
├── Atlas.entitlements
├── Sources/Atlas/
│   ├── AtlasApp.swift                    ← @main, hotkey globali, AppDelegate
│   ├── Context/
│   │   ├── FinderContext.swift           ← Model: cartella, selezione, tools
│   │   └── FinderContextProvider.swift   ← Lettura via osascript
│   ├── Planner/
│   │   ├── ActionGraph.swift             ← DAG di ActionStep
│   │   ├── InstantActionParser.swift     ← Parser locale 0ms
│   │   ├── ModelProvider.swift           ← Provider LLM (Apple/OpenCode/Ollama/OpenAI/Claude/NVIDIA/Custom)
│   │   ├── PlanValidator.swift           ← Validazione aderenza query/formati
│   │   ├── Planner.swift                 ← Coordinatore del piano + retry autocorrezione
│   │   └── PromptBuilder.swift           ← System prompt e compact prompt
│   ├── Executor/
│   │   ├── ExecutorFramework.swift       ← Dispatch topologico, progress per file
│   │   ├── AsyncProcessRunner.swift      ← CLI async, timeout, cancel, drain pipe
│   │   ├── RiskAssessment.swift          ← Livelli di rischio e predizione impatto
│   │   ├── ToolRegistry.swift            ← Registro plugin
│   │   ├── Transaction.swift             ← Backup + rollback (Codable)
│   │   ├── HistoryStore.swift            ← Cronologia persistente
│   │   └── UndoManager.swift             ← ⌘⇧Z globale, coordinato con HistoryStore
│   ├── Plugins/
│   │   ├── Plugin.swift                  ← Protocolli AtlasPlugin / ActionExecutor
│   │   ├── ImagePlugin/ImagePlugin.swift
│   │   ├── PDFPlugin/PDFPlugin.swift
│   │   ├── VideoPlugin/VideoPlugin.swift
│   │   ├── FilePlugin/FilePlugin.swift
│   │   └── ShellPlugin/ShellPlugin.swift ← incl. ShellGuard (sicurezza shell.run)
│   ├── MenuBar/MenuBarView.swift
│   └── Overlay/
│       ├── OverlayWindowController.swift ← NSPanel flottante / Finestra Standard
│       ├── CommandPaletteView.swift      ← UI principale
│       ├── PreviewView.swift             ← Anteprima piano
│       ├── ContextBannerView.swift       ← Banner contesto Finder
│       ├── QuickActionGrid.swift         ← Suggerimenti contestuali
│       ├── HelpSheetView.swift
│       └── HistoryView.swift             ← Cronologia e rollback selettivo
├── Settings/                             ← AppSettings, KeychainStore, RulesStore, SettingsView
└── Tests/AtlasTests/                     ← Parser, plugin, sicurezza, rollback
```
