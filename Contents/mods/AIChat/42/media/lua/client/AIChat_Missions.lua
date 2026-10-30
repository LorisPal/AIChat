--[[
    AIChat_Missions.lua
    Registro delle missioni assegnate dall'IA e trascrizione sui fogli.

    - L'IA assegna missioni ai personaggi (anche di altri giocatori) con tag che
      il ponte trasforma in eventi "assign" / "complete".
    - Chi usa la chat fa da scrivano: con la SUA carta e la SUA penna tiene un
      foglio per ogni personaggio, chiamato "Missioni - Nome Cognome".
    - Carta (foglio, taccuino o diario vuoto) e penna/matita possono stare
      nell'inventario, negli zaini o nei contenitori a portata di mano.
    - Ogni aggiornamento viene aggiunto in coda al foglio, mai sovrascritto.
    - A ogni scrittura il foglio viene reimpaginato in automatico: anche un
      foglio pieno viene ricompattato prima di passare a un foglio nuovo.
    - Se manca qualcosa la missione resta in attesa e viene trascritta appena
      carta e penna sono disponibili (la coda è salvata con il personaggio).
]]

require "AIChat_Bridge"
require "AIChat_MissionWriter"
require "AIChat_WriteAction"
require "ISUI/ISUIWriteJournal"

AIChatMissions = AIChatMissions or {}
local M = AIChatMissions
local W = AIChatMissionWriter

M.RETRY_TICKS = 300          -- ogni quanto riprovare le trascrizioni in attesa
M.MAX_ACTIVE_IN_CONTEXT = 30 -- missioni attive inviate all'IA

local retryCounter = 0
local nextJobId = 0

local function say(kind, text)
    AIChat.notify(kind, text)
end

local function trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

-- ---------------------------------------------------------------------------
-- Dati salvati con il personaggio dello scrivano
-- ---------------------------------------------------------------------------

function M.data()
    local player = getPlayer()
    if not player then return nil end
    local md = player:getModData()
    md.AIChatMissions = md.AIChatMissions or { targets = {}, queue = {} }
    md.AIChatMissions.targets = md.AIChatMissions.targets or {}
    md.AIChatMissions.queue = md.AIChatMissions.queue or {}
    return md.AIChatMissions
end

local function characterName(p)
    local ok, name = pcall(function()
        local d = p:getDescriptor()
        return trim(d:getForename() .. " " .. d:getSurname())
    end)
    if ok and name and name ~= "" then return name end
    return nil
end

local function username(p)
    local ok, u = pcall(function() return p:getUsername() end)
    if ok and u then return u end
    return ""
end

-- Personaggi conosciuti: online + già presenti nel registro
function M.onlineCharacters()
    local list, seen = {}, {}
    local function addPlayer(p)
        local name = characterName(p)
        if name and not seen[W.normName(name)] then
            seen[W.normName(name)] = true
            table.insert(list, { name = name, user = username(p) })
        end
    end
    local ok, players = pcall(getOnlinePlayers)
    if ok and players and players:size() > 0 then
        for i = 0, players:size() - 1 do addPlayer(players:get(i)) end
    else
        local me = getPlayer()
        if me then addPlayer(me) end
    end
    return list
end

-- Ricollega il nome scritto dall'IA a un personaggio noto (maiuscole, spazi, solo nome)
function M.resolveName(raw)
    local norm = W.normName(raw)
    local data = M.data()
    local candidates = {}
    for _, c in ipairs(M.onlineCharacters()) do table.insert(candidates, c.name) end
    for _, t in pairs(data.targets) do table.insert(candidates, t.name) end

    for _, name in ipairs(candidates) do
        if W.normName(name) == norm then return name end
    end
    -- solo nome o solo cognome, se non ambiguo
    local match
    for _, name in ipairs(candidates) do
        local n = W.normName(name)
        if n:find("^" .. norm .. " ") or n:find(" " .. norm .. "$") then
            if match and match ~= name then return trim(raw) end
            match = name
        end
    end
    return match or trim(raw)
end

local function target(name)
    local data = M.data()
    local key = W.normName(name)
    local t = data.targets[key]
    if not t then
        t = { name = name, next = 1, part = 1, list = {} }
        data.targets[key] = t
    end
    return t
end

local function gameStamp()
    local ok, s = pcall(function()
        local gt = getGameTime()
        return string.format("%02d/%02d/%d %02d:%02d",
            gt:getDay() + 1, gt:getMonth() + 1, gt:getYear(), gt:getHour(), gt:getMinutes())
    end)
    if ok and s then return s end
    return "?"
end

local function log(text)
    print("[AIChat] " .. tostring(text))
end

local function enqueue(name, line)
    -- le missioni già in attesa per questo personaggio avvisano di nuovo
    -- (altrimenti quella nuova resterebbe in coda senza spiegazioni)
    local key = W.normName(name)
    for _, job in ipairs(M.data().queue) do
        if W.normName(job.target) == key then job.warned = nil end
    end
    nextJobId = nextJobId + 1
    table.insert(M.data().queue, {
        id = tostring(nextJobId) .. "-" .. tostring(getTimestampMs and getTimestampMs() or 0),
        target = name,
        text = line,
    })
end

-- ---------------------------------------------------------------------------
-- Eventi dall'IA
-- ---------------------------------------------------------------------------

-- Numero più alto già usato per questo personaggio, guardando registro, coda
-- e fogli raggiungibili (così la numerazione non riparte mai da #1)
function M.highestNumber(name)
    local key = W.normName(name)
    local t = target(name)
    local best = (tonumber(t.next) or 1) - 1
    for _, m in ipairs(t.list) do
        if (tonumber(m.n) or 0) > best then best = tonumber(m.n) end
    end
    local player = getPlayer()
    if player then
        local ok, items = pcall(M.reachableItems, player)
        if ok and items then
            for _, it in ipairs(items) do
                if W.isWritable(it) and W.registryOf(it) == key then
                    local n = W.maxMissionNumber(it)
                    if n > best then best = n end
                end
            end
        end
    end
    return best
end

function M.onAssign(rawName, text, bridgeN)
    local name = M.resolveName(rawName)
    local t = target(name)
    local n = math.max(M.highestNumber(name) + 1, tonumber(bridgeN) or 0)
    t.next = n + 1
    table.insert(t.list, { n = n, text = text, done = false, at = gameStamp() })
    enqueue(name, "[" .. gameStamp() .. "] MISSIONE #" .. n .. ": " .. text)
    say("system", "Missione #" .. n .. " per " .. name .. " registrata: verrà trascritta sul suo foglio.")
end

function M.onComplete(rawName, ref)
    local name = M.resolveName(rawName)
    local t = target(name)
    local mission

    local num = tonumber(tostring(ref):match("#%s*(%d+)") or tostring(ref):match("^%s*(%d+)"))
    if num then
        for _, m in ipairs(t.list) do
            if m.n == num then mission = m end
        end
    else
        -- riferimento testuale: prima missione attiva che lo contiene
        local needle = W.normName(ref)
        for _, m in ipairs(t.list) do
            if not m.done and W.normName(m.text):find(needle, 1, true) then
                mission = m
                break
            end
        end
    end

    local line
    if mission then
        if mission.done then
            say("system", "La missione #" .. mission.n .. " di " .. name .. " era già completata.")
            return
        end
        mission.done = true
        line = "[" .. gameStamp() .. "] COMPLETATA #" .. mission.n .. ": " .. mission.text
        say("system", "Missione #" .. mission.n .. " di " .. name .. " segnata come completata.")
    else
        line = "[" .. gameStamp() .. "] COMPLETATA: " .. tostring(ref)
        say("system", "Completamento per " .. name .. " registrato (missione non trovata nel registro).")
    end
    enqueue(name, line)
end

AIChat.addListener(function(kind, _, events)
    if kind ~= "missions" or type(events) ~= "table" then return end
    for _, ev in ipairs(events) do
        if ev.kind == "assign" then
            M.onAssign(ev.name, ev.text, ev.n)
        elseif ev.kind == "complete" then
            M.onComplete(ev.name, ev.text)
        end
    end
    M.process()
end)

-- Righe di contesto inviate all'IA a ogni messaggio
function M.contextLines()
    local lines = {}
    local me = getPlayer()
    if not me then return lines end

    table.insert(lines, "Personaggio che ti scrive (scrivano del registro): " .. (characterName(me) or "?"))

    local names = {}
    for _, c in ipairs(M.onlineCharacters()) do
        if c.user ~= "" and c.user ~= c.name then
            table.insert(names, c.name .. " (giocatore " .. c.user .. ")")
        else
            table.insert(names, c.name)
        end
    end
    table.insert(lines, "GIOCATORI ONLINE: " .. (#names > 0 and table.concat(names, ", ") or "nessuno"))

    local active, count = {}, 0
    for _, t in pairs(M.data().targets) do
        for _, m in ipairs(t.list) do
            if not m.done and count < M.MAX_ACTIVE_IN_CONTEXT then
                count = count + 1
                table.insert(active, t.name .. " #" .. m.n .. " " .. m.text)
            end
        end
    end
    table.insert(lines, "MISSIONI ATTIVE: " .. (#active > 0 and table.concat(active, "; ") or "nessuna"))
    return lines
end

-- ---------------------------------------------------------------------------
-- Ricerca di carta e penna (inventario, zaini, contenitori vicini)
-- ---------------------------------------------------------------------------

local PEN_TYPES = {
    Pen = true, Pencil = true, BluePen = true, RedPen = true, GreenPen = true,
    PenFancy = true, PenMultiColor = true, PenSpiffo = true, PencilSpiffo = true,
}

function M.isPen(item)
    local ok, res = pcall(function()
        for _, tag in ipairs({ "PEN", "PENCIL", "BLUE_PEN", "RED_PEN", "GREEN_PEN" }) do
            if ItemTag[tag] and item:hasTag(ItemTag[tag]) then return true end
        end
        return false
    end)
    if ok and res then return true end
    local okT, t = pcall(function() return item:getType() end)
    return okT and PEN_TYPES[t] == true
end

-- Tutti gli oggetti raggiungibili, compreso il contenuto di borse e zaini
function M.reachableItems(player)
    local result, seenItems, seenCont = {}, {}, {}

    local function scan(container, depth)
        if not container or seenCont[container] or depth > 3 then return end
        seenCont[container] = true
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local it = items:get(i)
            local id = it:getID()
            if not seenItems[id] then
                seenItems[id] = true
                table.insert(result, it)
            end
            if instanceof(it, "InventoryContainer") then
                pcall(function() scan(it:getInventory(), depth + 1) end)
            end
        end
    end

    scan(player:getInventory(), 0)

    local ok, containers = pcall(ISInventoryPaneContextMenu.getContainers, player)
    if ok and containers then
        for i = 0, containers:size() - 1 do scan(containers:get(i), 0) end
    else
        -- alternativa: contenitori nei quadrati intorno al personaggio
        local sq = player:getCurrentSquare()
        if sq then
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local s = getCell():getGridSquare(sq:getX() + dx, sq:getY() + dy, sq:getZ())
                    if s then
                        local objs = s:getObjects()
                        for i = 0, objs:size() - 1 do
                            local obj = objs:get(i)
                            for c = 0, obj:getContainerCount() - 1 do
                                scan(obj:getContainerByIndex(c), 0)
                            end
                        end
                    end
                end
            end
        end
    end
    return result
end

function M.findTools(player, job)
    local me = username(player)
    local key = W.normName(job.target)
    local pen, sheet, blank, fullFound
    local bestPart = -1

    for _, it in ipairs(M.reachableItems(player)) do
        if not pen and M.isPen(it) then
            pen = it
        elseif W.isWritable(it) and not W.isLockedFor(it, me) then
            local owner, part = W.registryOf(it)
            if owner == key then
                -- sempre l'ultimo foglio, anche se pieno: la scrittura lo ricompatta
                if part > bestPart then sheet, bestPart = it, part end
            elseif not blank and W.isBlank(it) then
                blank = it
            end
        end
    end
    -- ultimo foglio già ricompattato per questo lavoro senza spazio: serve un foglio nuovo
    if sheet and job.fullSheets and job.fullSheets[tostring(sheet:getID())] then
        sheet, fullFound = nil, true
    end
    return pen, sheet, blank, fullFound
end

local function isIlliterate(player)
    local ok, res = pcall(function() return player:hasTrait(CharacterTrait.ILLITERATE) end)
    return ok and res == true
end

-- ---------------------------------------------------------------------------
-- Trascrizione
-- ---------------------------------------------------------------------------

local function removeJob(job)
    local q = M.data().queue
    for i = #q, 1, -1 do
        if q[i].id == job.id then table.remove(q, i) end
    end
end

local function playerIsIdle(player)
    local ok, busy = pcall(ISTimedActionQueue.isPlayerDoingAction, player)
    if ok then return not busy end
    return true
end

local function bringToInventory(player, item)
    local inv = player:getInventory()
    local src = item:getContainer()
    if src == inv then return end
    local action
    if ISInventoryTransferUtil and ISInventoryTransferUtil.newInventoryTransferAction then
        action = ISInventoryTransferUtil.newInventoryTransferAction(player, item, src, inv)
    else
        action = ISInventoryTransferAction:new(player, item, src, inv)
    end
    ISTimedActionQueue.add(action)
end

-- Prova a far partire la trascrizione di un lavoro.
-- Ritorna: "started", "stop" (nessun lavoro può partire), "wait" (manca carta
-- per questo personaggio: si passa al prossimo), "skip" (lavoro scartato)
local function tryJob(player, job)
    if isIlliterate(player) then
        if not job.warned then
            job.warned = true
            say("error", "Il tuo personaggio è analfabeta: non può scrivere il registro delle missioni.")
        end
        return "stop"
    end

    local pen, sheet, blank, fullFound = M.findTools(player, job)
    local paper = sheet or blank
    log("trascrizione per " .. job.target .. ": penna=" .. tostring(pen ~= nil)
        .. " registro=" .. tostring(sheet and sheet:getName()) .. " vuoto=" .. tostring(blank and blank:getName())
        .. " pieno=" .. tostring(fullFound == true))
    if not pen or not paper then
        if not job.warned then
            job.warned = true
            local missing = {}
            if not paper then
                table.insert(missing, (fullFound and "un nuovo foglio, taccuino o diario vuoto (il registro attuale è pieno)")
                    or "un foglio, taccuino o diario vuoto")
            end
            if not pen then table.insert(missing, "una penna o matita") end
            say("error", "Per trascrivere la missione di " .. job.target .. " serve "
                .. table.concat(missing, " e ")
                .. " (in inventario o in un contenitore vicino). La missione resta in attesa.")
        end
        return pen and "wait" or "stop"
    end

    if sheet then
        local _, part = W.registryOf(sheet)
        job.part = part
    else
        local t = target(job.target)
        job.part = t.part or 1
    end

    job.busy = true
    job.warned = nil
    bringToInventory(player, pen)
    bringToInventory(player, paper)
    ISTimedActionQueue.add(AIChatWriteAction:new(player, paper, pen, job))
    return "started"
end

-- Trascrive il prossimo lavoro possibile. Una missione in attesa di carta blocca
-- solo le missioni dello stesso personaggio (l'ordine sul foglio resta giusto).
function M.process()
    local player = getPlayer()
    if not player or player:isDead() then return end
    local queue = M.data().queue
    if #queue == 0 or not playerIsIdle(player) then return end

    for _, job in ipairs(queue) do
        -- personaggio fermo ma lavoro ancora "in corso": l'azione è stata annullata
        -- (es. trasferimento fallito), quindi si riprova
        job.busy = false
    end

    local snapshot = {}
    for i, job in ipairs(queue) do snapshot[i] = job end
    local blocked = {}
    for _, job in ipairs(snapshot) do
        local key = W.normName(job.target)
        if not blocked[key] then
            local result = tryJob(player, job)
            if result == "started" or result == "stop" then return end
            if result == "wait" then blocked[key] = true end
        end
    end
end

local function squash(s)
    return (tostring(s or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function finishJob(job, item, remaining)
    job.busy = false
    if remaining == nil or remaining == "" then
        removeJob(job)
        say("system", "Foglio di " .. job.target .. " aggiornato.")
    else
        -- foglio pieno anche dopo la ricompattazione: il resto andrà su un nuovo foglio
        local t = target(job.target)
        -- job.part è già la parte più alta trovata (o t.part per un foglio vuoto)
        t.part = (job.part or 1) + 1
        job.fullSheets = job.fullSheets or {}
        job.fullSheets[tostring(item:getID())] = true
        -- se non è entrato nulla il testo resta com'era (niente "(segue)")
        if squash(remaining) ~= squash(job.text) then job.text = "(segue) " .. remaining end
        say("system", "Il foglio di " .. job.target .. " è pieno: continuo su un nuovo foglio.")
    end
end

-- Chiamata da AIChatWriteAction:perform()
function M.doWrite(job, item)
    local player = getPlayer()
    local opts = {
        target = job.target,
        part = job.part or 1,
        writer = characterName(player) or "",
    }
    local lay = M.layout()
    opts.lineWidth, opts.lines, opts.pageChars = lay.lineWidth, lay.lines, lay.pageChars
    -- come la scrittura normale del gioco: si scrive sull'oggetto del client e in
    -- multiplayer si invia al server (nome, pagine e dati dell'oggetto)
    local remaining = W.append(item, job.text, opts)
    if isClient() then W.sync(player, item) end
    log("scritto su " .. tostring(item:getName()) .. (remaining ~= "" and " (pieno, resta del testo)" or ""))
    finishJob(job, item, remaining)
end

function M.onWriteInterrupted(job)
    if job then job.busy = false end
end

-- ---------------------------------------------------------------------------
-- Misura della finestra di scrittura del gioco
-- Quando il giocatore apre un foglio o un diario, la mod misura quante righe
-- entrano nel riquadro e quanto sono larghe, e scrive di conseguenza.
-- ---------------------------------------------------------------------------

function M.layout()
    local player = getPlayer()
    local md = player and player:getModData() or {}
    local lay = md.AIChatLayout or {}
    return {
        lineWidth = lay.lineWidth or W.LINE_WIDTH,
        lines = lay.lines or W.LINES_PER_PAGE,
        pageChars = lay.pageChars or md.AIChatPageChars or W.PAGE_CHARS,
    }
end

local SAMPLE = "Recupera tre taniche di benzina dalla stazione di servizio e torna prima di sera. "

local function measureJournal(win)
    local player = getPlayer()
    local entry = win and win.entry
    if not player or not entry then return end
    local lay = {}

    pcall(function()
        local tm = getTextManager()
        local font = entry.font or UIFont.Small
        local fh = tm:getFontHeight(font)
        local h = entry:getHeight()
        local w = entry:getWidth()
        if fh and fh > 0 and h and h > fh then
            -- una riga di margine per bordi e cursore
            lay.lines = math.max(3, math.floor(h / fh) - 1)
        end
        local avg = tm:MeasureStringX(font, SAMPLE) / #SAMPLE
        if avg and avg > 0 and w and w > 60 then
            -- margine per bordi e barra di scorrimento, poi un 10% di sicurezza
            lay.lineWidth = math.max(15, math.floor((w - 30) / avg * 0.9))
        end
    end)
    pcall(function()
        local limit = tonumber(win.maxTextLength)
        if limit and limit >= 80 then lay.pageChars = limit - 10 end
    end)
    pcall(function()
        -- se la finestra limita esplicitamente le righe, vale quel limite
        local maxLines = tonumber(win.lineNumber)
        if maxLines and maxLines >= 3 and (lay.lines == nil or maxLines < lay.lines) then
            lay.lines = maxLines
        end
    end)

    if lay.lines or lay.lineWidth or lay.pageChars then
        local md = player:getModData()
        local old = md.AIChatLayout or {}
        md.AIChatLayout = {
            lines = lay.lines or old.lines,
            lineWidth = lay.lineWidth or old.lineWidth,
            pageChars = lay.pageChars or old.pageChars,
        }
    end
end

if ISUIWriteJournal then
    for _, fname in ipairs({ "initialise", "createChildren" }) do
        local original = ISUIWriteJournal[fname]
        if original then
            ISUIWriteJournal[fname] = function(self, ...)
                local r = original(self, ...)
                measureJournal(self)
                return r
            end
        end
    end
end

-- Al caricamento nessun lavoro è in corso; poi riprova periodicamente
Events.OnGameStart.Add(function()
    local data = M.data()
    if data then
        for _, job in ipairs(data.queue) do job.busy = false end
    end
end)

Events.OnTick.Add(function()
    retryCounter = retryCounter + 1
    if retryCounter < M.RETRY_TICKS then return end
    retryCounter = 0
    pcall(M.process)
end)
