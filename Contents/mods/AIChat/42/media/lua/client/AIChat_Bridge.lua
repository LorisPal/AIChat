--[[
    AIChat_Bridge.lua
    Comunicazione con il programma ponte esterno (ai_bridge.py) tramite file.

    Il Lua di Project Zomboid non può fare richieste HTTP, quindi:
      1. la mod scrive la richiesta in  Zomboid/Lua/AIChat_request.txt
      2. ai_bridge.py la legge, chiama l'API (Claude, ChatGPT o Gemini) e scrive
         la risposta in Zomboid/Lua/AIChat_response.txt
      3. la mod controlla periodicamente il file di risposta.

    Formato richiesta:
        id=<numero>
        provider=claude|openai|gemini
        command=chat|reset
        ---CONTEXT---
        <righe di contesto>
        ---MESSAGE---
        <messaggio>
        ---END---

    Formato risposta:
        id=<numero>
        status=ok|error
        provider=<nome>
        available=<provider configurati, separati da virgola>
        ---MISSIONS---
        assign|complete <TAB> Nome Personaggio <TAB> testo   (zero o più righe)
        ---TEXT---
        <testo>
        ---END---
]]

AIChat = AIChat or {}

AIChat.REQUEST_FILE  = "AIChat_request.txt"
AIChat.RESPONSE_FILE = "AIChat_response.txt"
AIChat.TIMEOUT_MS    = 180000   -- 3 minuti senza risposta = errore (il ponte riprova da solo)
AIChat.POLL_TICKS    = 20       -- controlla il file ogni ~20 tick
AIChat.RESUME_TIMEOUT_MS = 10000 -- la ripresa della storia è locale: se il ponte tace, lascia perdere

AIChat.provider   = AIChat.provider or "claude"
AIChat.pending    = nil         -- { id = n, sentAt = ms }
AIChat.lastId     = AIChat.lastId or 0
AIChat.listeners  = AIChat.listeners or {}

local tickCounter = 0

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

local function nowMs()
    local ok, v = pcall(getTimestampMs)
    if ok and v then return v end
    return 0
end

local function safe(fn, default)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return v end
    return default
end

local function notify(kind, text, extra)
    for _, fn in ipairs(AIChat.listeners) do
        pcall(fn, kind, text, extra)
    end
end

AIChat.notify = notify

function AIChat.addListener(fn)
    table.insert(AIChat.listeners, fn)
end

function AIChat.setProvider(name)
    AIChat.provider = name
end

-- Provider con la chiave configurata nel ponte (nil = non ancora noti)
function AIChat.isAvailable(name)
    if not AIChat.available or #AIChat.available == 0 then return true end
    for _, p in ipairs(AIChat.available) do
        if p == name then return true end
    end
    return false
end

-- Se il modello scelto non è configurato passa al primo disponibile
local function useProvider(name)
    if not name or name == "" or name == AIChat.provider then return end
    AIChat.provider = name
    notify("provider", name)
end

local function setAvailable(csv)
    if csv == nil then return end   -- ponte vecchio: non lo dice
    local list = {}
    for p in csv:gmatch("[^,%s]+") do table.insert(list, p) end
    AIChat.available = list
    if #list > 0 and not AIChat.isAvailable(AIChat.provider) then
        useProvider(list[1])
    end
end

function AIChat.isBusy()
    return AIChat.pending ~= nil
end

-- ---------------------------------------------------------------------------
-- Contesto di gioco (ogni campo è protetto da pcall: se un'API cambia in una
-- versione futura della B42 il campo viene semplicemente saltato)
-- ---------------------------------------------------------------------------

function AIChat.buildContext()
    local lines = {}
    local player = getPlayer()
    if not player then return lines end

    local function add(label, value)
        if value ~= nil and value ~= "" then
            table.insert(lines, label .. ": " .. tostring(value))
        end
    end

    add("Nome personaggio", safe(function()
        local d = player:getDescriptor()
        return d:getForename() .. " " .. d:getSurname()
    end))
    add("Professione", safe(function()
        local prof = player:getDescriptor():getProfession()
        if type(prof) == "string" then return prof end
        return tostring(prof)
    end))

    local gt = safe(getGameTime)
    if gt then
        add("Data in gioco", safe(function()
            return string.format("giorno %d/%d/%d, ore %02d:%02d",
                gt:getDay() + 1, gt:getMonth() + 1, gt:getYear(),
                gt:getHour(), gt:getMinutes())
        end))
        add("Giorni sopravvissuti", safe(function()
            return math.floor(gt:getWorldAgeHours() / 24)
        end))
    end

    add("Temperatura esterna (C)", safe(function()
        return string.format("%.1f", getClimateManager():getTemperature())
    end))
    add("Salute generale (0-100)", safe(function()
        return math.floor(player:getBodyDamage():getOverallBodyHealth())
    end))
    add("Fame (0-1)", safe(function()
        return string.format("%.2f", player:getStats():getHunger())
    end))
    add("Sete (0-1)", safe(function()
        return string.format("%.2f", player:getStats():getThirst())
    end))
    add("Stanchezza (0-1)", safe(function()
        return string.format("%.2f", player:getStats():getFatigue())
    end))
    add("Al chiuso", safe(function()
        local sq = player:getCurrentSquare()
        if sq then return sq:isOutside() and "no" or "si" end
    end))
    add("Veicolo", safe(function()
        local v = player:getVehicle()
        if v then return v:getScript():getName() end
    end))
    add("Mano primaria", safe(function()
        local it = player:getPrimaryHandItem()
        if it then return it:getDisplayName() end
    end))
    add("Mano secondaria", safe(function()
        local it = player:getSecondaryHandItem()
        if it then return it:getDisplayName() end
    end))

    -- Inventario principale: conteggio per nome, massimo 40 voci
    local inv = safe(function()
        local items = player:getInventory():getItems()
        local counts, order = {}, {}
        for i = 0, items:size() - 1 do
            local name = items:get(i):getDisplayName()
            if not counts[name] then
                counts[name] = 0
                table.insert(order, name)
            end
            counts[name] = counts[name] + 1
        end
        local parts = {}
        for i, name in ipairs(order) do
            if i > 40 then
                table.insert(parts, "...")
                break
            end
            if counts[name] > 1 then
                table.insert(parts, name .. " x" .. counts[name])
            else
                table.insert(parts, name)
            end
        end
        return table.concat(parts, ", ")
    end)
    add("Inventario", inv)

    return lines
end

-- ---------------------------------------------------------------------------
-- Scrittura richiesta
-- ---------------------------------------------------------------------------

-- Identità della storia: salvataggio + personaggio che chatta.
-- Ogni personaggio ha la sua storia, che il ponte salva e ricarica.
function AIChat.sessionInfo()
    local world = safe(function() return getWorld():getWorld() end, "mondo")
    local player = getPlayer()
    local name = player and safe(function()
        local d = player:getDescriptor()
        return d:getForename() .. " " .. d:getSurname()
    end) or "Sopravvissuto"
    local stamp = safe(function()
        local gt = getGameTime()
        return string.format("%02d/%02d/%d %02d:%02d",
            gt:getDay() + 1, gt:getMonth() + 1, gt:getYear(), gt:getHour(), gt:getMinutes())
    end, "")
    return {
        session = tostring(world) .. "__" .. tostring(name),
        player = tostring(name),
        gametime = stamp,
    }
end

local function oneLine(s)
    s = tostring(s or ""):gsub("[\r\n]", " ")
    return s
end

local function writeRequest(command, message, contextLines)
    AIChat.lastId = AIChat.lastId + 1
    -- id univoco anche tra riavvii del gioco (contatore + timestamp)
    local id = tostring(AIChat.lastId) .. "-" .. tostring(nowMs())

    local w = getFileWriter(AIChat.REQUEST_FILE, true, false)
    if not w then
        notify("error", "Impossibile scrivere il file di richiesta.")
        return nil
    end
    w:writeln("id=" .. id)
    w:writeln("provider=" .. AIChat.provider)
    w:writeln("command=" .. command)
    local info = AIChat.sessionInfo()
    w:writeln("session=" .. oneLine(info.session))
    w:writeln("player=" .. oneLine(info.player))
    w:writeln("gametime=" .. oneLine(info.gametime))
    w:writeln("---CONTEXT---")
    for _, l in ipairs(contextLines or {}) do
        w:writeln(l)
    end
    w:writeln("---MESSAGE---")
    w:writeln(message or "")
    w:writeln("---END---")
    w:close()
    return id
end

function AIChat.send(message, includeContext)
    -- la richiesta di ripresa della storia non deve bloccare il primo messaggio
    if AIChat.pending and AIChat.pending.resume then
        AIChat.pending = nil
    end
    if AIChat.pending then
        notify("error", "Attendi la risposta precedente.")
        return false
    end
    local ctx = includeContext and AIChat.buildContext() or {}
    -- giocatori online e missioni attive: servono sempre all'IA per assegnarle
    if AIChatMissions and AIChatMissions.contextLines then
        local ok, extra = pcall(AIChatMissions.contextLines)
        if ok and extra then
            for _, l in ipairs(extra) do table.insert(ctx, l) end
        end
    end
    local id = writeRequest("chat", message, ctx)
    if not id then return false end
    AIChat.pending = { id = id, sentAt = nowMs() }
    notify("pending", "")
    return true
end

-- Chiede al ponte gli ultimi scambi della storia salvata (all'apertura della chat)
function AIChat.resume()
    if AIChat.pending then return false end
    local id = writeRequest("resume", "", {})
    if not id then return false end
    AIChat.pending = { id = id, sentAt = nowMs(), resume = true }
    return true
end

function AIChat.reset()
    AIChat.pending = nil
    writeRequest("reset", "", {})
    notify("system", "Nuova storia iniziata. La precedente è archiviata nella cartella \"storie\" del ponte.")
end

-- ---------------------------------------------------------------------------
-- Lettura risposta
-- ---------------------------------------------------------------------------

local function readResponse()
    local r = getFileReader(AIChat.RESPONSE_FILE, false)
    if not r then return nil end

    local header, text, missions = {}, {}, {}
    local section = "header"
    local complete = false
    local line = r:readLine()
    while line ~= nil do
        if line == "---TEXT---" then
            section = "text"
        elseif line == "---MISSIONS---" then
            section = "missions"
        elseif line == "---END---" then
            complete = true
            break
        elseif section == "header" then
            local k, v = line:match("^([%w_]+)=(.*)$")
            if k then header[k] = v end
        elseif section == "missions" then
            local kind, name, body, num = line:match("^(%a+)\t([^\t]+)\t([^\t]+)\t?(%d*)%s*$")
            if kind then
                table.insert(missions, { kind = kind, name = name, text = body, n = tonumber(num) })
            end
        else
            table.insert(text, line)
        end
        line = r:readLine()
    end
    r:close()

    if not complete then return nil end
    header.text = table.concat(text, "\n")
    header.missions = missions
    return header
end

local function onTick()
    if not AIChat.pending then return end
    tickCounter = tickCounter + 1
    if tickCounter < AIChat.POLL_TICKS then return end
    tickCounter = 0

    local resp = readResponse()
    -- accetta solo la risposta alla richiesta in attesa (ignora file vecchi)
    if resp and resp.id == AIChat.pending.id then
        local wasResume = AIChat.pending.resume
        AIChat.pending = nil
        setAvailable(resp.available)
        if resp.status == "ok" and resp.type ~= "resume" and not wasResume then
            -- il ponte ha risposto con un altro modello perché quello scelto non ha la chiave
            useProvider(resp.provider)
        end
        if resp.status == "ok" and (resp.type == "resume" or wasResume) then
            notify("history", resp.text)
        elseif resp.status == "ok" then
            notify("reply", resp.text, resp.provider)
            if #resp.missions > 0 then
                notify("missions", "", resp.missions)
            end
        else
            notify("error", resp.text)
        end
        return
    end

    local sentAt = AIChat.pending.sentAt
    local limit = AIChat.pending.resume and AIChat.RESUME_TIMEOUT_MS or AIChat.TIMEOUT_MS
    if sentAt > 0 and nowMs() - sentAt > limit then
        local wasResume = AIChat.pending.resume
        AIChat.pending = nil
        if wasResume then
            notify("system", "Il ponte non risponde: avvia ai_bridge.py per riprendere la storia salvata.")
        else
            notify("error", "Nessuna risposta dal ponte. Controlla che ai_bridge.py sia avviato.")
        end
    end
end

Events.OnTick.Add(onTick)
