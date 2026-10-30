# AI Chat per Project Zomboid (Build 42)

Chatta con **Claude**, **ChatGPT** o **Gemini** direttamente in gioco, senza tenere aperto il browser.
Gemini ha un piano **gratuito**: non serve nessun abbonamento né carta di credito.

## Come funziona

Il Lua di Project Zomboid non può fare richieste internet, quindi la mod usa un piccolo programma "ponte" che gira accanto al gioco:

```
[Gioco: finestra F8] --scrive--> Zomboid/Lua/AIChat_request.txt
                                         |
                                  ai_bridge.py --> API Claude / OpenAI / Gemini
                                         |
[Gioco: finestra F8] <--legge--- Zomboid/Lua/AIChat_response.txt
```

## Installazione

### 1. La mod
Copia la cartella `Contents/mods/AIChat` in:
- **Windows:** `C:\Users\<nome>\Zomboid\mods\`
- **Linux / macOS:** `~/Zomboid/mods/`

Struttura finale: `Zomboid/mods/AIChat/42/mod.info` e `Zomboid/mods/AIChat/common/`.
Poi attivala dal menu **Mod** del gioco.

### 2. Il programma ponte
La cartella `companion` può stare **dove vuoi** (ad esempio in Documenti): il ponte trova da solo la cartella `Zomboid/Lua`.

Serve [Python 3.8+](https://www.python.org/downloads/) (su Windows spunta "Add Python to PATH" durante l'installazione). Nessuna libreria aggiuntiva.

1. Copia `config.example.json` in `config.json` (nella stessa cartella).
2. Inserisci **almeno una** chiave API (vedi sotto). Lascia vuote quelle che non usi.
3. Avvia il ponte dal terminale aperto in quella cartella e lascialo aperto mentre giochi:
   ```
   python ai_bridge.py
   ```

Per provare tutto senza usare nessuna API: `python ai_bridge.py --test`.

### 3. Le chiavi API

| IA | Costo | Dove si crea la chiave |
|---|---|---|
| **Gemini** | Gratis (con limiti giornalieri) | https://aistudio.google.com/apikey |
| **ChatGPT** | A consumo, credito prepagato | https://platform.openai.com/api-keys |
| **Claude** | A consumo, credito prepagato | https://console.anthropic.com |

- **Gemini gratis:** accedi con un account Google, clicca *Create API key* e incollala in `"gemini_api_key"`. Sul piano gratuito Google può usare le conversazioni per migliorare i suoi prodotti. Se superi il limite di richieste, la chat te lo segnala: basta aspettare qualche minuto, e il limite giornaliero si azzera alle 9 del mattino (ora italiana).
- **ChatGPT e Claude:** l'API è separata dagli abbonamenti ChatGPT Plus / Claude Pro. Serve caricare un po' di credito; pochi euro bastano per molte ore di chat.
- In alternativa al file puoi usare le variabili d'ambiente `GEMINI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`.

## In gioco
- **F8** apre e chiude la chat.
- **Modello:** clicca il pulsante in alto per passare tra Claude, ChatGPT e Gemini (la conversazione resta condivisa).
- **Invia contesto del personaggio:** allega salute, fame, sete, ora, meteo, oggetti in mano e inventario, così puoi chiedere "con quello che ho, cosa posso fare?".
- **Nuova chat:** chiude la storia attuale e ne inizia una nuova (serve un secondo clic su "Conferma?").
- Se chiudi la finestra mentre aspetti, il personaggio ti avvisa quando arriva la risposta.

## La storia viene salvata

Pensata per il gioco di ruolo: la storia non si perde quando chiudi il gioco o il ponte.

- Ogni storia è legata al **salvataggio e al personaggio** che usa la chat: personaggi diversi hanno storie diverse.
- Quando apri la chat (F8), in grigio compaiono gli **ultimi scambi** della storia salvata, così sai dove eri rimasto. L'IA ricorda tutto e riprende da lì.
- Nella cartella `companion/storie/` il ponte tiene due file per ogni storia:
  - **`<salvataggio>__<personaggio>.txt`**: la trascrizione completa, con data reale e data in gioco, comprese le missioni assegnate. Non viene mai accorciata e puoi aprirla con qualsiasi editor di testo.
  - **`<salvataggio>__<personaggio>.json`**: la memoria che il ponte ricarica a ogni avvio.
- Quando la storia diventa lunga, i fatti più vecchi vengono condensati in un **riassunto** che l'IA riceve sempre. Così ricorda nomi, luoghi ed eventi importanti anche dopo molte sessioni, senza far crescere i costi.
- **Nuova chat** non cancella niente: la memoria viene archiviata (`..._archivio_<data>.json`) e la trascrizione continua nello stesso file con la riga "Nuova storia".
- Per spostare le storie altrove, imposta `"stories_dir"` in `config.json`.

## Registro delle missioni

Durante la chat l'IA può assegnare missioni ai personaggi del server (anche a quelli degli altri giocatori). Chi usa la chat fa da **scrivano**: ogni missione viene trascritta a mano, con la sua carta e la sua penna, sul foglio del personaggio che la riceve.

**Cosa serve:** un foglio, un taccuino o un diario **vuoto** e una **penna o matita**. Possono stare nell'inventario, negli zaini o in un contenitore a portata di mano: il personaggio li prende da solo.

**Come funziona:**
- L'IA vede i giocatori online e le missioni ancora aperte. Quando assegna un compito, in chat compare "Missione #1 per Mario Rossi registrata".
- Il personaggio scrive per qualche secondo. Il foglio viene rinominato **"Missioni - Mario Rossi"**: uno per ogni personaggio.
- Ogni nuova missione o completamento viene **aggiunto in fondo**, con data e ora di gioco. Il testo già scritto non viene mai cancellato.
- Per chiudere una missione basta dirlo all'IA (es. "Mario ha portato la benzina"): sul foglio compare "COMPLETATA #1".
- Se manca carta o penna, la chat lo segnala e la missione resta in attesa: viene trascritta appena trovi l'occorrente. Le missioni in attesa restano salvate con il personaggio.
- Quando un foglio è pieno, la trascrizione continua su un nuovo foglio "Missioni - Mario Rossi (2)".
- **Impaginazione:** il testo va a capo da solo e ogni voce resta intera sulla stessa pagina. Quando apri un foglio o un diario, la mod **misura la finestra di scrittura** (quante righe entrano e quanto sono larghe) e da lì in poi scrive su quella misura. Finché non ne apri uno usa valori prudenti (8 righe da 30 caratteri, modificabili in cima a `AIChat_MissionWriter.lua`).
- **Testo tagliato o nascosto?** Apri il foglio una volta, così la mod misura la finestra. Alla prossima missione assegnata il registro viene ricompattato in automatico; quello che non entra passa su un nuovo foglio, quindi serve un foglio vuoto e la penna.
- **Numerazione:** ogni personaggio ha la sua numerazione (#1, #2, #3...). Il numero è salvato dal ponte nel file della storia e controllato anche sui fogli già scritti, quindi continua anche dopo un riavvio o una "Nuova chat". Se l'IA scrive il nome in modo diverso ("Cody" invece di "Cody Smith"), viene ricondotto allo stesso personaggio.
- Se manca la carta per un personaggio, aspettano solo le sue missioni: quelle degli altri vengono trascritte normalmente.
- Un personaggio analfabeta non può tenere il registro.

## Problemi comuni

Prima di tutto lancia **`python ai_bridge.py --check`**: prova ogni chiave configurata e spiega in chiaro cosa non va. Per Gemini elenca anche i modelli che la tua chiave può usare.

- **"Nessuna chiave API configurata" anche se il file è compilato.** Quasi sempre Windows ha salvato il file come `config.json.json` o `config.json.txt` (le estensioni sono nascoste). Il ponte ora lo trova lo stesso e te lo segnala, ma conviene rinominarlo: in Esplora file attiva *Visualizza > Estensioni nomi file* e lascia solo `config.json`.
- **"config.json non valido alla riga X".** Manca una virgoletta o una virgola. Ogni valore di testo va tra "virgolette" e ogni riga, tranne l'ultima prima della `}`, finisce con una virgola.
- **Gemini: "HTTP 401" con una chiave che inizia con `AQ.`.** È il nuovo formato di chiave di Google, ed è normale. Alcuni modelli però la rifiutano. Il ponte prova da solo i modelli disponibili per la tua chiave e ti dice quale funziona, da scrivere in `"gemini_model"`. Se Google rifiuta la chiave con tutti i modelli, creane una nuova.
- **Non condividere mai la tua chiave** (nemmeno in uno screenshot): chi la vede può usarla a tuo nome. Se è successo, eliminala su aistudio.google.com/apikey e creane una nuova.

## Note
- Le chiavi API restano solo nel `config.json` sul tuo PC: la mod non le vede mai.
- **Se un'IA è lenta o sovraccarica** (succede soprattutto con Gemini gratuito nelle ore di punta), il ponte riprova da solo una volta. Con Gemini il secondo tentativo usa il modello più leggero `gemini-flash-lite-latest`. Se fallisce anche quello, in chat compare un messaggio chiaro: basta riprovare dopo qualche minuto o cambiare IA.
- Modelli predefiniti: `gemini-flash-latest`, `gpt-5-mini`, `claude-haiku-5-5`. Si cambiano in `config.json`.
- In multiplayer la mod va attivata sul server, come ogni mod. Il ponte, invece, lo avvia solo chi usa la chat (ad esempio il coordinatore): gli altri giocatori non hanno bisogno di Python né di chiavi API.
- In multiplayer la scrittura del foglio viene fatta dal server, così resta salvata e visibile a tutti.
