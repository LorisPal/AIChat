#!/usr/bin/env python3
"""
ai_bridge.py - ponte tra la mod "AI Chat" di Project Zomboid (Build 42)
e le API di Claude (Anthropic), ChatGPT (OpenAI) e Gemini (Google).

Nessuna dipendenza esterna: serve solo Python 3.8 o superiore.

Uso:
    python ai_bridge.py                 # usa la cartella Zomboid/Lua predefinita
    python ai_bridge.py --dir PERCORSO  # cartella Zomboid/Lua personalizzata
    python ai_bridge.py --test          # risponde senza chiamare le API (prova)

Le chiavi API si leggono da config.json (accanto a questo file) oppure dalle
variabili d'ambiente ANTHROPIC_API_KEY, OPENAI_API_KEY e GEMINI_API_KEY,
che hanno la precedenza.
"""

import argparse
import http.client
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REQUEST_FILE = "AIChat_request.txt"
RESPONSE_FILE = "AIChat_response.txt"
POLL_SECONDS = 0.5
MAX_HISTORY_TURNS = 20  # oltre queste coppie domanda/risposta i messaggi vecchi vanno nel riassunto
KEEP_RECENT_TURNS = 8   # coppie recenti che restano sempre parola per parola
HARD_HISTORY_LIMIT = 80 # tetto di sicurezza se il riassunto non riesce
RESUME_MESSAGES = 6     # messaggi mostrati in gioco quando si riprende una storia
REQUEST_TIMEOUT = 55    # secondi massimi per singola chiamata all'API
RETRY_PAUSE = 3         # pausa prima del secondo tentativo

DEFAULT_CONFIG = {
    "anthropic_api_key": "",
    "anthropic_model": "claude-haiku-5-5",
    "openai_api_key": "",
    "openai_model": "gpt-5-mini",
    "gemini_api_key": "",
    "gemini_model": "gemini-flash-latest",
    # modello più leggero usato in automatico se quello principale è sovraccarico
    "gemini_fallback_model": "gemini-flash-lite-latest",
    # quanto "ragiona" Gemini prima di rispondere: low = più veloce ("" = predefinito)
    "gemini_thinking": "low",
    "max_tokens": 2048,
    "language": "italiano",
    "stories_dir": "",  # vuoto = cartella "storie" accanto a questo file
}

SYSTEM_PROMPT = """Sei un assistente integrato in Project Zomboid (Build 42), \
un gioco di sopravvivenza in un'apocalisse zombie ambientata nel Kentucky del 1993.
Il giocatore ti scrive da una piccola finestra di chat dentro il gioco.
Regole:
- Rispondi in {language}, salvo che il giocatore scriva in un'altra lingua.
- Sii conciso: poche frasi o un breve elenco con trattini. Niente markdown \
(niente asterischi, cancelletti o tabelle): il testo viene mostrato così com'è.
- Quando ricevi il CONTESTO DEL PERSONAGGIO, usalo per dare consigli concreti \
sulla situazione attuale.
- Se non sei sicuro di una meccanica specifica della Build 42, dillo invece di inventare.

MISSIONI:
Il giocatore con cui parli fa da coordinatore del gruppo e tiene un registro scritto \
delle missioni. Nel messaggio trovi GIOCATORI ONLINE (i personaggi del server) e \
MISSIONI ATTIVE (già registrate, con il loro numero).
- Quando nella conversazione assegni un compito concreto a un personaggio, aggiungi \
in fondo alla risposta una riga con questo formato esatto:
  [MISSIONE: Nome Cognome | descrizione breve e concreta della missione]
  Una riga per ogni missione. Usa il nome del personaggio come appare in GIOCATORI ONLINE \
(o come te lo indica il giocatore).
- Quando il giocatore ti dice che una missione è stata portata a termine, aggiungi:
  [COMPLETATA: Nome Cognome | #numero]
  usando il numero indicato in MISSIONI ATTIVE.
- Usa questi tag solo per missioni vere, mai per semplici consigli o esempi. Il testo \
fuori dai tag deve leggersi bene anche senza di essi."""

MISSION_TAG = re.compile(r"\[\s*(MISSIONE|COMPLETATA)\s*:\s*([^|\]\n]+?)\s*\|\s*([^\]\n]+?)\s*\]", re.IGNORECASE)


def extract_missions(answer):
    """Separa i tag missione dal testo. Restituisce (testo_pulito, eventi)."""
    events = []
    for kind, name, body in MISSION_TAG.findall(answer):
        events.append((
            "assign" if kind.upper() == "MISSIONE" else "complete",
            " ".join(name.split()),
            " ".join(body.split()),
        ))
    clean = MISSION_TAG.sub("", answer)
    clean = re.sub(r"\n{3,}", "\n\n", clean).strip()
    return clean, events


# ---------------------------------------------------------------------------
# Configurazione
# ---------------------------------------------------------------------------

def find_config():
    """Trova config.json, anche quando Windows (estensioni nascoste) l'ha salvato
    come config.json.json o config.json.txt."""
    folder = Path(__file__).parent
    for name in ("config.json", "config.json.json", "config.json.txt", "config.txt"):
        path = folder / name
        if path.exists():
            if name != "config.json":
                print(f"[!] Ho trovato \"{name}\" invece di \"config.json\": lo uso lo stesso.")
                print("    Windows nasconde le estensioni: conviene rinominarlo in config.json")
                print("    (in Esplora file: Visualizza > Estensioni nomi file).")
            return path
    return None


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    path = find_config()
    if path is None:
        print(f"[!] Non trovo config.json nella cartella {Path(__file__).parent}")
    else:
        try:
            # utf-8-sig: accetta anche i file salvati dal Blocco note con BOM
            with path.open(encoding="utf-8-sig") as f:
                data = json.load(f)
            cfg.update({k: v.strip() if isinstance(v, str) else v
                        for k, v in data.items() if v not in (None, "")})
            print(f"[i] Configurazione letta da {path.name}")
        except json.JSONDecodeError as e:
            print(f"[!] {path.name} non valido alla riga {e.lineno}, colonna {e.colno}: {e.msg}")
            print("    Controlla virgolette e virgole: ogni valore di testo va tra \"virgolette\",")
            print("    ogni riga tranne l'ultima finisce con una virgola.")
        except OSError as e:
            print(f"[!] Impossibile leggere {path.name}: {e}")
    env_map = {
        "ANTHROPIC_API_KEY": "anthropic_api_key",
        "ANTHROPIC_MODEL": "anthropic_model",
        "OPENAI_API_KEY": "openai_api_key",
        "OPENAI_MODEL": "openai_model",
        "GEMINI_API_KEY": "gemini_api_key",
        "GOOGLE_API_KEY": "gemini_api_key",
        "GEMINI_MODEL": "gemini_model",
    }
    for env, key in env_map.items():
        if os.environ.get(env):
            cfg[key] = os.environ[env]
    return cfg


def default_lua_dir():
    return Path.home() / "Zomboid" / "Lua"


# ---------------------------------------------------------------------------
# Protocollo su file
# ---------------------------------------------------------------------------

def parse_request(raw):
    """Restituisce un dict o None se il file è incompleto."""
    lines = raw.splitlines()
    if "---END---" not in lines:
        return None
    req = {"context": [], "message": []}
    section = "header"
    for line in lines:
        if line == "---CONTEXT---":
            section = "context"
        elif line == "---MESSAGE---":
            section = "message"
        elif line == "---END---":
            break
        elif section == "header":
            if "=" in line:
                k, v = line.split("=", 1)
                req[k.strip()] = v.strip()
        else:
            req[section].append(line)
    req["context"] = "\n".join(req["context"]).strip()
    req["message"] = "\n".join(req["message"]).strip()
    return req if req.get("id") else None


def write_response(lua_dir, req_id, status, provider, text, missions=(), kind="chat", available=()):
    # righe: tipo <TAB> nome <TAB> testo <TAB> numero missione (se noto)
    mission_lines = "".join(
        "\t".join(str(field).replace("\t", " ") for field in ev) + "\n" for ev in missions
    )
    body = (
        f"id={req_id}\n"
        f"status={status}\n"
        f"provider={provider}\n"
        f"type={kind}\n"
        # provider con la chiave configurata: il gioco salta gli altri
        f"available={','.join(available)}\n"
        "---MISSIONS---\n"
        f"{mission_lines}"
        "---TEXT---\n"
        f"{text.replace('---END---', '- - -END- - -')}\n"
        "---END---\n"
    )
    target = lua_dir / RESPONSE_FILE
    tmp = lua_dir / (RESPONSE_FILE + ".tmp")
    tmp.write_text(body, encoding="utf-8")
    os.replace(tmp, target)  # scrittura atomica: il gioco non legge mai file a metà


# ---------------------------------------------------------------------------
# Provider
# ---------------------------------------------------------------------------

class TransientError(RuntimeError):
    """Errore temporaneo del servizio (sovraccarico, lentezza, rete): ha senso riprovare."""


TRANSIENT_HTTP = {408, 500, 502, 503, 504, 529}


def http_post_json(url, headers, payload, timeout=REQUEST_TIMEOUT):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(detail).get("error", {}).get("message", detail)
        except (json.JSONDecodeError, AttributeError):
            pass
        if e.code in TRANSIENT_HTTP:
            raise TransientError(f"HTTP {e.code}: {detail}") from None
        if e.code == 429:
            raise RuntimeError(
                "Limite di richieste raggiunto (HTTP 429). Sul piano gratuito di Gemini "
                "aspetta qualche minuto, oppure il limite giornaliero si azzera a mezzanotte "
                "ora del Pacifico (le 9 del mattino in Italia). Dettagli: " + str(detail)
            ) from None
        raise RuntimeError(f"HTTP {e.code}: {detail}") from None
    except urllib.error.URLError as e:
        if isinstance(e.reason, (socket.timeout, TimeoutError)):
            raise TransientError(f"nessuna risposta entro {timeout} secondi") from None
        raise RuntimeError(f"Connessione fallita: {e.reason}") from None
    except (socket.timeout, TimeoutError):
        raise TransientError(f"nessuna risposta entro {timeout} secondi") from None
    except (ConnectionError, http.client.HTTPException) as e:
        raise TransientError(f"connessione interrotta ({e})") from None


def ask_claude(cfg, system, history):
    key = cfg.get("anthropic_api_key")
    if not key:
        raise RuntimeError("Manca la chiave API di Anthropic (anthropic_api_key in config.json).")
    result = http_post_json(
        "https://api.anthropic.com/v1/messages",
        {"x-api-key": key, "anthropic-version": "2023-06-01"},
        {
            "model": cfg["anthropic_model"],
            "max_tokens": int(cfg["max_tokens"]),
            "system": system,
            "messages": history,
        },
    )
    return "".join(b.get("text", "") for b in result.get("content", []) if b.get("type") == "text")


def ask_openai(cfg, system, history):
    key = cfg.get("openai_api_key")
    if not key:
        raise RuntimeError("Manca la chiave API di OpenAI (openai_api_key in config.json).")
    result = http_post_json(
        "https://api.openai.com/v1/chat/completions",
        {"Authorization": f"Bearer {key}"},
        {
            "model": cfg["openai_model"],
            # i modelli GPT-5 consumano token di ragionamento dallo stesso budget
            "max_completion_tokens": int(cfg["max_tokens"]) * 2,
            "messages": [{"role": "system", "content": system}] + history,
        },
    )
    return result["choices"][0]["message"].get("content") or ""


_GEMINI_NO_THINKING_LEVEL = set()
GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta"


def http_get_json(url, headers, timeout=20):
    req = urllib.request.Request(url, method="GET")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(detail).get("error", {}).get("message", detail)
        except (json.JSONDecodeError, AttributeError):
            pass
        raise RuntimeError(f"HTTP {e.code}: {detail}") from None
    except (urllib.error.URLError, OSError) as e:
        raise RuntimeError(f"Connessione fallita: {e}") from None


def _version_key(name):
    nums = re.findall(r"\d+(?:\.\d+)?", name)
    return tuple(float(n) for n in nums[:2]) or (0.0,)


def gemini_models(key):
    """Modelli testuali utilizzabili con questa chiave, dal più recente."""
    data = http_get_json(f"{GEMINI_BASE}/models?pageSize=200", {"x-goog-api-key": key})
    names = []
    for m in data.get("models", []):
        name = m.get("name", "")
        if name.startswith("models/"):
            name = name[len("models/"):]
        methods = m.get("supportedGenerationMethods", [])
        if "generateContent" not in methods or "gemini" not in name:
            continue
        if any(x in name for x in ("image", "tts", "audio", "live", "embedding", "robotics", "computer")):
            continue
        names.append(name)
    return sorted(names, key=lambda n: ("preview" in n or "exp" in n, "lite" in n, [-v for v in _version_key(n)]))


def ask_gemini(cfg, system, history):
    key = cfg.get("gemini_api_key")
    if not key:
        raise RuntimeError("Manca la chiave API di Gemini (gemini_api_key in config.json).")
    # Gemini usa i ruoli "user" e "model" invece di "user" e "assistant"
    contents = [
        {"role": "model" if m["role"] == "assistant" else "user", "parts": [{"text": m["content"]}]}
        for m in history
    ]
    model = cfg["gemini_model"]
    if model.startswith("models/"):
        model = model[len("models/"):]
    gen = {
        # margine extra: i modelli Gemini recenti "ragionano" e consumano token prima di rispondere
        "maxOutputTokens": int(cfg["max_tokens"]) * 2,
    }
    thinking = cfg.get("gemini_thinking") or ""
    if thinking and model not in _GEMINI_NO_THINKING_LEVEL:
        gen["thinkingConfig"] = {"thinkingLevel": thinking}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    payload = {
        "systemInstruction": {"parts": [{"text": system}]},
        "contents": contents,
        "generationConfig": gen,
    }
    try:
        result = http_post_json(url, {"x-goog-api-key": key}, payload)
    except TransientError:
        raise
    except RuntimeError as e:
        # alcuni modelli (es. serie 2.5) non accettano thinkingLevel: riprova senza
        if "thinkingConfig" in gen and "HTTP 400" in str(e) and "think" in str(e).lower():
            _GEMINI_NO_THINKING_LEVEL.add(model)
            del gen["thinkingConfig"]
            result = http_post_json(url, {"x-goog-api-key": key}, payload)
        else:
            raise
    candidates = result.get("candidates") or []
    if not candidates:
        reason = (result.get("promptFeedback") or {}).get("blockReason", "nessun motivo indicato")
        raise RuntimeError(f"Gemini non ha risposto (bloccato: {reason}).")
    parts = (candidates[0].get("content") or {}).get("parts") or []
    text = "".join(p.get("text", "") for p in parts if not p.get("thought"))
    if not text and candidates[0].get("finishReason") == "MAX_TOKENS":
        raise RuntimeError("Risposta troncata: aumenta max_tokens in config.json.")
    return text


def ask_test(cfg, system, history):
    last = history[-1]["content"]
    return f"(modalità test) Ho ricevuto:\n{last[:300]}"


PROVIDERS = {"claude": ask_claude, "openai": ask_openai, "gemini": ask_gemini}
PROVIDER_NAMES = {"claude": "Claude", "openai": "ChatGPT", "gemini": "Gemini"}
PROVIDER_KEYS = {"claude": "anthropic_api_key", "openai": "openai_api_key", "gemini": "gemini_api_key"}


def available_providers(cfg, test_mode=False):
    """Provider con una chiave in config.json (in modalità test vanno tutti bene)."""
    if test_mode:
        return list(PROVIDERS)
    return [p for p, k in PROVIDER_KEYS.items() if cfg.get(k)]


def _gemini_model_recovery(first_error, cfg, system, history, max_tries=4):
    print(f"[~] Gemini ha rifiutato il modello {cfg.get('gemini_model')} ({first_error})")
    try:
        models = gemini_models(cfg["gemini_api_key"])
    except RuntimeError as e:
        raise RuntimeError(
            f"Google rifiuta la chiave Gemini ({e}). Crea una nuova chiave su "
            "aistudio.google.com/apikey, copiala per intero in config.json e riavvia il ponte."
        ) from None
    # prima i modelli "flash" (veloci e gratuiti), poi gli altri
    candidates = [m for m in models if "flash" in m] + [m for m in models if "flash" not in m]
    candidates = [m for m in candidates if m != cfg.get("gemini_model")][:max_tries]
    if not candidates:
        raise RuntimeError(f"Nessun modello Gemini disponibile per questa chiave ({first_error}).")

    last = first_error
    for model in candidates:
        print(f"[~] Provo con {model}")
        try:
            answer = ask_gemini(dict(cfg, gemini_model=model), system, history)
        except TransientError as e:
            last = e
            continue
        except RuntimeError as e:
            last = e
            if _model_problem(e):
                continue
            raise
        cfg["gemini_model"] = model  # lo ricorda fino alla chiusura del ponte
        print(f"[i] Funziona con {model}: per non vedere più questo avviso scrivi")
        print(f'    "gemini_model": "{model}" in config.json')
        return answer
    raise RuntimeError(
        f"Google rifiuta la chiave con tutti i modelli provati ({', '.join(candidates)}): {last}. "
        "Crea una nuova chiave su aistudio.google.com/apikey e riavvia il ponte."
    )


def _model_problem(err):
    """401/403/404 di Gemini legati al modello (frequenti con le nuove chiavi AQ.)."""
    text = str(err)
    return any(code in text for code in ("HTTP 401", "HTTP 403", "HTTP 404"))


def ask_with_retry(provider, fn, cfg, system, history):
    """Chiede la risposta gestendo i problemi più comuni:
    - servizio sovraccarico o lento: un secondo tentativo (per Gemini con il modello di riserva);
    - Gemini che rifiuta il modello (401/403/404, tipico delle chiavi AQ.): cerca da solo
      un modello disponibile per la chiave."""
    try:
        return fn(cfg, system, history)
    except TransientError as first:
        transient = first
    except RuntimeError as err:
        if provider == "gemini" and fn is ask_gemini and _model_problem(err):
            return _gemini_model_recovery(err, cfg, system, history)
        raise

    retry_cfg = dict(cfg)
    note = ""
    fallback = cfg.get("gemini_fallback_model")
    if provider == "gemini" and fallback and fallback != cfg.get("gemini_model"):
        retry_cfg["gemini_model"] = fallback
        note = f" con {fallback}"
    print(f"[~] {transient} - riprovo{note} tra {RETRY_PAUSE} secondi")
    time.sleep(RETRY_PAUSE)
    try:
        return fn(retry_cfg, system, history)
    except TransientError as second:
        name = PROVIDER_NAMES.get(provider, provider)
        raise RuntimeError(
            f"{name} è sovraccarico o troppo lento in questo momento ({second}). "
            "Non dipende dalla mod: riprova tra qualche minuto oppure cambia modello "
            "con il pulsante in alto."
        ) from None


# ---------------------------------------------------------------------------
# Storie salvate su file
# ---------------------------------------------------------------------------

SUMMARY_PROMPT = """Sei l'archivista di una storia di gioco di ruolo ambientata in Project Zomboid.
Aggiorna il riassunto della storia unendo il RIASSUNTO ATTUALE con i NUOVI SCAMBI.
Mantieni: nomi dei personaggi e le loro relazioni, luoghi, eventi importanti, oggetti \
chiave, decisioni prese, missioni assegnate o completate (con il loro numero), tono della storia.
Scrivi in {language}, in terza persona, al massimo 300 parole, senza markdown.

RIASSUNTO ATTUALE:
{summary}

NUOVI SCAMBI:
{exchanges}"""


def safe_name(text, fallback="storia"):
    name = re.sub(r"[^\w\-]+", "_", text or "", flags=re.UNICODE).strip("_")
    return name[:80] or fallback


def now_label():
    return time.strftime("%d/%m/%Y %H:%M")


class Story:
    """Una storia = un salvataggio + il personaggio che chatta.
    <nome>.json contiene la memoria per l'IA (riassunto + messaggi recenti),
    <nome>.txt la trascrizione completa, che non viene mai accorciata."""

    def __init__(self, folder, session):
        self.session = session
        self.json_path = folder / f"{session}.json"
        self.log_path = folder / f"{session}.txt"
        self.summary = ""
        self.history = []   # {"role", "content", "name"?}
        self.missions = {}  # nome normalizzato -> {"name", "next", "active": {"n": testo}}
        self.logged_resume = False
        if self.json_path.exists():
            try:
                data = json.loads(self.json_path.read_text(encoding="utf-8"))
                self.summary = data.get("summary", "")
                self.missions = data.get("missions", {}) or {}
                self.history = [m for m in data.get("history", []) if m.get("role") in ("user", "assistant")]
            except (OSError, json.JSONDecodeError) as e:
                print(f"[!] Memoria della storia illeggibile ({e}): ne inizio una nuova")
                self.archive("illeggibile")

    def save(self):
        data = {"session": self.session, "updated": now_label(), "summary": self.summary,
                "missions": self.missions, "history": self.history}
        tmp = self.json_path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        os.replace(tmp, self.json_path)

    def log(self, line):
        if not self.logged_resume:
            self.logged_resume = True
            self._write_log(f"\n===== Sessione del {now_label()} =====")
        self._write_log(line)

    def _write_log(self, line):
        with self.log_path.open("a", encoding="utf-8") as f:
            f.write(line + "\n")

    def archive(self, reason="archivio"):
        """Mette da parte la memoria attuale (la trascrizione resta) e ricomincia."""
        if self.json_path.exists():
            dest = self.json_path.with_name(f"{self.session}_{reason}_{time.strftime('%Y%m%d-%H%M%S')}.json")
            os.replace(self.json_path, dest)
        self.summary = ""
        self.history = []
        # il registro delle missioni NON si azzera: i fogli in gioco restano e la
        # numerazione deve continuare da dove era arrivata

    # --- registro missioni: il numero lo decide il ponte e resta salvato su file ---

    @staticmethod
    def _norm(name):
        return " ".join(name.lower().split())

    def resolve_target(self, name):
        """Riconduce "Cody" o "cody smith" al personaggio già registrato "Cody Smith"."""
        norm = self._norm(name)
        if norm in self.missions:
            return norm
        words = set(norm.split())
        matches = [k for k in self.missions if words and (words <= set(k.split()) or set(k.split()) <= words)]
        return matches[0] if len(matches) == 1 else norm

    def number_missions(self, events):
        """Aggiunge il numero a ogni evento missione e aggiorna il registro."""
        numbered = []
        for kind, name, body in events:
            key = self.resolve_target(name)
            reg = self.missions.setdefault(key, {"name": name, "next": 1, "active": {}})
            if kind == "assign":
                n = int(reg.get("next", 1))
                reg["next"] = n + 1
                reg["active"][str(n)] = body
            else:
                m = re.search(r"#\s*(\d+)", body) or re.match(r"\s*(\d+)\s*$", body)
                n = int(m.group(1)) if m else ""
                if m:
                    reg["active"].pop(str(n), None)
            numbered.append((kind, reg["name"], body, n))
        return numbered

    def api_messages(self, last_user_content=None):
        """Messaggi per l'API: solo ruolo e testo; l'ultimo può includere il contesto di gioco."""
        msgs = [{"role": m["role"], "content": m["content"]} for m in self.history]
        while msgs and msgs[0]["role"] != "user":
            msgs.pop(0)
        if last_user_content is not None and msgs and msgs[-1]["role"] == "user":
            msgs[-1] = {"role": "user", "content": last_user_content}
        return msgs

    def recap(self, n=RESUME_MESSAGES):
        lines = []
        if self.summary:
            lines.append("Finora: " + self.summary)
            lines.append("")
        for m in self.history[-n:]:
            who = "Tu" if m["role"] == "user" else m.get("name", "IA")
            text, _ = extract_missions(m["content"])
            if len(text) > 400:
                text = text[:400].rsplit(" ", 1)[0] + "..."
            lines.append(f"{who}: {text}")
            lines.append("")
        return "\n".join(lines).strip()


# ---------------------------------------------------------------------------
# Ciclo principale
# ---------------------------------------------------------------------------

class Bridge:
    def __init__(self, lua_dir, cfg, test_mode=False):
        self.lua_dir = lua_dir
        self.cfg = cfg
        self.test_mode = test_mode
        self.last_id = None
        self.language = cfg.get("language", "italiano")
        self.system = SYSTEM_PROMPT.format(language=self.language)
        self.available = available_providers(cfg, test_mode)
        folder = cfg.get("stories_dir") or ""
        self.stories_dir = Path(folder) if folder else Path(__file__).with_name("storie")
        self.stories_dir.mkdir(parents=True, exist_ok=True)
        self.story = None

    def get_story(self, req):
        session = safe_name(req.get("session", ""), "storia")
        if self.story is None or self.story.session != session:
            self.story = Story(self.stories_dir, session)
            state = f"{len(self.story.history)} messaggi in memoria" if self.story.history or self.story.summary else "nuova storia"
            print(f"[i] Storia: {session} ({state})")
        return self.story

    def system_for(self, story):
        if not story.summary:
            return self.system
        return self.system + "\n\nRIASSUNTO DELLA STORIA FINORA (dalle sessioni precedenti):\n" + story.summary

    def compact(self, story, provider, fn):
        """Se la memoria è lunga, condensa i messaggi più vecchi nel riassunto."""
        if len(story.history) <= MAX_HISTORY_TURNS * 2:
            return
        keep = KEEP_RECENT_TURNS * 2
        old, recent = story.history[:-keep], story.history[-keep:]
        while recent and recent[0]["role"] != "user":
            old.append(recent.pop(0))
        exchanges = "\n".join(
            f"{'Giocatore' if m['role'] == 'user' else 'Narratore'}: {extract_missions(m['content'])[0]}" for m in old
        )
        prompt = SUMMARY_PROMPT.format(language=self.language, summary=story.summary or "(nessuno)", exchanges=exchanges)
        try:
            summary = ask_with_retry(provider, fn, self.cfg, "Riassumi fedelmente, senza inventare.",
                                     [{"role": "user", "content": prompt}]).strip()
            if summary:
                story.summary = summary
                story.history = recent
                print(f"[i] Memoria condensata: {len(old)} messaggi vecchi aggiunti al riassunto")
        except Exception as e:  # noqa: BLE001
            print(f"[!] Riassunto non riuscito ({e}): riprovo più avanti")
            if len(story.history) > HARD_HISTORY_LIMIT:
                story.history = story.history[-HARD_HISTORY_LIMIT:]

    def handle(self, req):
        command = req.get("command", "chat")
        provider = req.get("provider", "claude")

        story = self.get_story(req)
        who = req.get("player") or "Tu"
        stamp = f"[{now_label()}" + (f" | in gioco {req['gametime']}" if req.get("gametime") else "") + "]"

        if command == "reset":
            story.archive()
            story.save()   # conserva subito il registro missioni nella nuova memoria
            story.log(f"{stamp} ===== Nuova storia: la memoria precedente è stata archiviata =====")
            print("[i] Nuova storia: memoria precedente archiviata")
            return

        if command == "resume":
            if story.history or story.summary:
                text = story.recap()
            else:
                text = "Nessuna storia salvata per questo personaggio: ne inizia una nuova."
            write_response(self.lua_dir, req["id"], "ok", provider, text, kind="resume",
                           available=self.available)
            return

        if provider not in self.available:
            if not self.available:
                write_response(self.lua_dir, req["id"], "error", provider,
                               "Nessuna chiave API configurata: compila config.json e riavvia il ponte.")
                return
            # modello senza chiave: risponde il primo configurato invece di dare errore
            fallback = self.available[0]
            print(f"[i] {PROVIDER_NAMES.get(provider, provider)} non configurato: uso {PROVIDER_NAMES[fallback]}")
            provider = fallback

        message = req["message"]
        content = message
        if req["context"]:
            content = f"CONTESTO DEL PERSONAGGIO:\n{req['context']}\n\nDOMANDA:\n{message}"

        # in memoria resta solo il messaggio; il contesto (che cambia) va solo nell'ultima richiesta
        story.history.append({"role": "user", "content": message, "name": who})
        name = PROVIDER_NAMES.get(provider, provider)
        print(f"[>] {name}: {message[:80]}")
        fn = ask_test if self.test_mode else PROVIDERS[provider]
        try:
            answer = ask_with_retry(provider, fn, self.cfg, self.system_for(story),
                                    story.api_messages(content)).strip() or "(risposta vuota)"
        except Exception as e:  # noqa: BLE001 - qualsiasi errore va mostrato in gioco
            story.history.pop()  # la domanda non ha avuto risposta
            write_response(self.lua_dir, req["id"], "error", provider, str(e), available=self.available)
            print(f"[!] {e}")
            return

        story.history.append({"role": "assistant", "content": answer, "name": name})
        shown, missions = extract_missions(answer)
        missions = story.number_missions(missions)
        if missions and not shown:
            shown = "Missione registrata."
        write_response(self.lua_dir, req["id"], "ok", provider, shown, missions, available=self.available)

        story.log(f"{stamp} {who}: {message}")
        story.log(f"{stamp} {name}: {shown}")
        for kind, target, body, n in missions:
            label = f"Missione #{n} assegnata a" if kind == "assign" else "Missione completata da"
            story.log(f"{stamp} * {label} {target}: {body}")
            print(f"[*] {kind} #{n}: {target} -> {body[:60]}")
        print(f"[<] {shown[:80]}")

        self.compact(story, provider, fn)
        story.save()

    def run(self):
        req_path = self.lua_dir / REQUEST_FILE
        # ignora una richiesta rimasta da una sessione precedente
        if req_path.exists():
            old = parse_request(req_path.read_text(encoding="utf-8", errors="replace"))
            if old:
                self.last_id = old["id"]

        print(f"[i] In ascolto su {self.lua_dir}")
        print(f"[i] Storie e trascrizioni salvate in {self.stories_dir}")
        print("[i] Avvia Project Zomboid e premi F8 in gioco. Ctrl+C per uscire.")
        while True:
            try:
                if req_path.exists():
                    raw = req_path.read_text(encoding="utf-8", errors="replace")
                    req = parse_request(raw)
                    if req and req["id"] != self.last_id:
                        self.last_id = req["id"]
                        self.handle(req)
            except OSError:
                pass  # il gioco sta scrivendo il file: riprova al prossimo giro
            time.sleep(POLL_SECONDS)


def check(cfg):
    """Prova ogni chiave configurata con una richiesta minima e spiega cosa non va."""
    print("\n=== Verifica delle chiavi API ===")
    test = [{"role": "user", "content": "Rispondi solo con la parola OK."}]
    small = dict(cfg, max_tokens=200)
    for provider, key_name in (("gemini", "gemini_api_key"), ("claude", "anthropic_api_key"),
                               ("openai", "openai_api_key")):
        name = PROVIDER_NAMES[provider]
        key = cfg.get(key_name, "")
        if not key:
            print(f"\n[{name}] nessuna chiave configurata: salto.")
            continue
        print(f"\n[{name}] chiave {key[:6]}...{key[-4:]} ({len(key)} caratteri)")
        if key != key.strip() or " " in key:
            print("  ! la chiave contiene spazi: ricopiala senza spazi prima o dopo")
        if provider == "gemini":
            try:
                models = gemini_models(key)
                print(f"  chiave accettata da Google, modelli testuali disponibili: {len(models)}")
                for m in models[:8]:
                    print(f"    - {m}")
            except RuntimeError as e:
                print(f"  ! Google rifiuta la chiave: {e}")
                print("    Crea una nuova chiave su aistudio.google.com/apikey e copiala per intero.")
                continue
        try:
            answer = ask_with_retry(provider, PROVIDERS[provider], small, "Sei un assistente.", test)
            model = small.get({"gemini": "gemini_model", "claude": "anthropic_model",
                               "openai": "openai_model"}[provider])
            print(f"  OK: il modello {model} risponde ({answer.strip()[:40]!r})")
        except RuntimeError as e:
            print(f"  ! errore: {e}")
    print()


def main():
    parser = argparse.ArgumentParser(description="Ponte AI per Project Zomboid")
    parser.add_argument("--dir", type=Path, default=None, help="cartella Zomboid/Lua")
    parser.add_argument("--test", action="store_true", help="risponde senza chiamare le API")
    parser.add_argument("--check", action="store_true", help="verifica le chiavi API ed esce")
    args = parser.parse_args()

    if args.check:
        check(load_config())
        return

    lua_dir = args.dir or default_lua_dir()
    if not lua_dir.exists():
        print(f"[!] Cartella non trovata: {lua_dir}")
        print("    Avvia il gioco almeno una volta oppure indica il percorso con --dir")
        sys.exit(1)

    cfg = load_config()
    if not args.test:
        available = available_providers(cfg)
        if not available:
            print("[!] Nessuna chiave API configurata. Compila config.json (vedi config.example.json).")
            sys.exit(1)
        for p in PROVIDERS:
            if p not in available:
                print(f"[i] {PROVIDER_NAMES[p]} non configurato: in gioco verrà saltato.")

    try:
        Bridge(lua_dir, cfg, test_mode=args.test).run()
    except KeyboardInterrupt:
        print("\n[i] Ponte chiuso.")


if __name__ == "__main__":
    main()
