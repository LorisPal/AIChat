--[[
    AIChat_MissionWriter.lua  (shared)
    Scrittura del testo delle missioni su fogli, taccuini e diari.
    Scrive sempre il client, come la scrittura normale del gioco; in multiplayer
    W.sync invia poi il foglio aggiornato al server.

    Il testo viene sempre AGGIUNTO in coda alle pagine esistenti, mai sovrascritto.
]]

AIChatMissionWriter = AIChatMissionWriter or {}
local W = AIChatMissionWriter

-- Limiti per pagina, scelti per stare dentro la finestra di scrittura del gioco.
-- Il testo va a capo da solo ogni LINE_WIDTH caratteri.
-- Valori prudenti: quando il giocatore apre un foglio la mod misura la finestra
-- reale e li sostituisce (vedi AIChat_Missions.lua, misuraFinestra).
W.LINE_WIDTH     = 30
W.LINES_PER_PAGE = 8
W.PAGE_CHARS     = 280            -- tetto di sicurezza in caratteri (byte) per pagina
W.TITLE_PREFIX = "Missioni - "  -- nome dato all'oggetto scritto

local function trim(s)
    s = tostring(s or "")
    s = s:gsub("^%s+", "")
    s = s:gsub("%s+$", "")
    return s
end

function W.normName(name)
    local n = trim(name):lower()
    n = n:gsub("%s+", " ")
    return n
end

function W.title(displayName, part)
    local t = W.TITLE_PREFIX .. trim(displayName)
    if part and part > 1 then t = t .. " (" .. tostring(part) .. ")" end
    return t
end

-- È un foglio / taccuino / diario su cui si può scrivere?
function W.isWritable(item)
    if not item then return false end
    local ok, res = pcall(function()
        return instanceof(item, "Literature") and item:canBeWrite()
    end)
    return ok and res == true
end

function W.pageCount(item)
    local ok, n = pcall(function() return item:getNumberOfPages() end)
    if ok and n and n >= 1 then return n end
    return 1
end

function W.getPage(item, i)
    local ok, t = pcall(function() return item:seePage(i) end)
    if ok and t then return tostring(t) end
    return ""
end

-- Bloccato da un altro giocatore (scritto a penna da qualcun altro)?
function W.isLockedFor(item, username)
    local ok, owner = pcall(function() return item:getLockedBy() end)
    if not ok or owner == nil or owner == "" then return false end
    return owner ~= username
end

-- Di chi è questo registro? Restituisce (nome normalizzato, parte) o nil.
-- In multiplayer i dati dell'oggetto scritti dal server possono non arrivare al
-- client: in quel caso il registro si riconosce dal nome "Missioni - Nome (2)".
function W.registryOf(item)
    local md = item:getModData()
    if md.AIChatMissionTarget then
        return md.AIChatMissionTarget, tonumber(md.AIChatMissionPart) or 1
    end
    local ok, name = pcall(function() return item:getName() end)
    if not ok or type(name) ~= "string" then return nil end
    local prefix = W.TITLE_PREFIX
    if name:sub(1, #prefix) ~= prefix then return nil end
    local rest = trim(name:sub(#prefix + 1))
    local who, part = rest:match("^(.-)%s*%((%d+)%)$")
    if who and who ~= "" then return W.normName(who), tonumber(part) end
    if rest ~= "" then return W.normName(rest), 1 end
    return nil
end

-- Nessuna pagina scritta e non già usato come registro missioni
function W.isBlank(item)
    if not W.isWritable(item) then return false end
    if W.registryOf(item) then return false end
    for i = 1, W.pageCount(item) do
        if trim(W.getPage(item, i)) ~= "" then return false end
    end
    return true
end

-- Divide il testo in righe di al massimo W.LINE_WIDTH caratteri (a capo sulle parole)
function W.wrapLines(text, width)
    width = width or W.LINE_WIDTH
    local out = {}
    text = tostring(text or ""):gsub("\r", "")
    for para in (text .. "\n"):gmatch("(.-)\n") do
        if para == "" then
            table.insert(out, "")
        else
            local line = ""
            for w in para:gmatch("%S+") do
                local word = w
                while #word > width do               -- parola lunghissima: spezzala
                    if line ~= "" then table.insert(out, line); line = "" end
                    table.insert(out, word:sub(1, width))
                    word = word:sub(width + 1)
                end
                if line == "" then
                    line = word
                elseif #line + 1 + #word <= width then
                    line = line .. " " .. word
                else
                    table.insert(out, line)
                    line = word
                end
            end
            if line ~= "" then table.insert(out, line) end
        end
    end
    return out
end

-- Dimensioni della pagina: quelle misurate in gioco (se plausibili) o i valori prudenti
local function layout(opts)
    local width = tonumber(opts and opts.lineWidth)
    local lines = tonumber(opts and opts.lines)
    local chars = tonumber(opts and opts.pageChars)
    if not width or width < 15 or width > 120 then width = W.LINE_WIDTH end
    if not lines or lines < 3 or lines > 60 then lines = W.LINES_PER_PAGE end
    if not chars or chars < 80 then chars = 100000 end
    -- il tetto in caratteri non può superare righe x larghezza
    chars = math.min(chars, lines * (width + 1))
    return math.floor(width), math.floor(lines), math.floor(chars)
end

-- Riunisce le righe spezzate dall'a capo automatico, così il testo può essere
-- rimpaginato con una larghezza diversa. Una voce nuova inizia con "[data]",
-- con "(" o con le righe d'intestazione; una riga vuota separa i blocchi.
local function isHeader(line)
    return line:find("^REGISTRO MISSIONI") ~= nil or line:find("^Tenuto da") ~= nil
        or line:find("^%(foglio %d+%)$") ~= nil
end

local function startsBlock(line)
    return line:sub(1, 1) == "[" or line:sub(1, 1) == "(" or isHeader(line)
end

function W.unwrap(text)
    local paragraphs = {}
    local current = nil
    for line in (tostring(text or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
        if line == "" then
            if current then table.insert(paragraphs, current); current = nil end
            table.insert(paragraphs, "")
        elseif current == nil or startsBlock(line) or isHeader(current) then
            if current then table.insert(paragraphs, current) end
            current = line
        else
            current = current .. " " .. line
        end
    end
    if current then table.insert(paragraphs, current) end
    -- niente righe vuote doppie
    local out = {}
    for _, p in ipairs(paragraphs) do
        if not (p == "" and out[#out] == "") then table.insert(out, p) end
    end
    return table.concat(out, "\n")
end

-- Numero più alto di missione già scritto sul foglio (per non ripartire da #1)
function W.maxMissionNumber(item)
    local best = 0
    for i = 1, W.pageCount(item) do
        for num in W.getPage(item, i):gmatch("MISSIONE%s*#%s*(%d+)") do
            local n = tonumber(num)
            if n and n > best then best = n end
        end
    end
    return best
end

--[[
    Aggiunge `text` all'oggetto. Se è un foglio vuoto lo trasforma nel registro
    delle missioni del personaggio (nome, intestazione, dati di riconoscimento).

    Tutto il contenuto (vecchio + nuovo) viene impaginato per righe, così ogni
    pagina resta entro i limiti della finestra di scrittura del gioco. I fogli
    scritti con versioni precedenti della mod vengono sistemati qui.

    opts = { target = "Nome Cognome", part = 1, writer = "Nome scrivano", pageChars = n }
    Restituisce il testo che non è entrato (stringa vuota se è entrato tutto).
]]
function W.append(item, text, opts)
    local md = item:getModData()
    text = tostring(text or "")

    -- registro già pieno: non riscrive nulla e restituisce tutto il testo
    if md.AIChatMissionFull and text ~= "" then return text end

    if not md.AIChatMissionTarget then
        -- registro riconosciuto solo dal nome: recupera i dati senza rifare l'intestazione
        local key, part = W.registryOf(item)
        if key then
            md.AIChatMissionTarget = key
            md.AIChatMissionName   = trim(opts.target)
            md.AIChatMissionPart   = part
        end
    end

    if not md.AIChatMissionTarget then
        md.AIChatMissionTarget = W.normName(opts.target)
        md.AIChatMissionName   = trim(opts.target)
        md.AIChatMissionPart   = opts.part or 1
        local header = "REGISTRO MISSIONI DI " .. trim(opts.target):upper()
        if opts.writer and opts.writer ~= "" then
            header = header .. "\nTenuto da " .. opts.writer
        end
        if (opts.part or 1) > 1 then
            header = header .. "\n(foglio " .. tostring(opts.part) .. ")"
        end
        text = header .. "\n\n" .. text
        pcall(function()
            item:setName(W.title(opts.target, opts.part))
            item:setCustomName(true)
        end)
    end

    -- righe già scritte (anche quelle "nascoste" oltre il limite) + righe nuove
    local width, maxLines, limit = layout(opts)
    local pages = W.pageCount(item)
    -- testo completo (vecchio + nuovo), diviso in voci; ogni voce in righe
    local old = {}
    for i = 1, pages do
        local page = W.getPage(item, i)
        if page ~= "" then table.insert(old, page) end
    end
    local full = W.unwrap(table.concat(old, "\n"))   -- riunisce le righe spezzate in precedenza
    if text ~= "" then                                 -- testo vuoto = solo reimpaginazione
        full = (full ~= "" and (full .. "\n") or "") .. text
    end

    local lines, blockEnd = {}, {}
    for para in (full .. "\n"):gmatch("(.-)\n") do
        local first = #lines + 1
        for _, l in ipairs(W.wrapLines(para, width)) do table.insert(lines, l) end
        for i = first, #lines do blockEnd[i] = #lines end
    end

    -- distribuisce le righe sulle pagine; una voce che non entra nello spazio
    -- rimasto passa intera alla pagina successiva (se sta in una pagina)
    local idx = 1
    for i = 1, pages do
        local pageLines, bytes = {}, 0
        while idx <= #lines and #pageLines < maxLines do
            local l = lines[idx]
            if #pageLines == 0 and l == "" then
                idx = idx + 1                       -- niente righe vuote in cima alla pagina
            else
                local isStart = (idx == 1) or (blockEnd[idx - 1] ~= blockEnd[idx])
                if isStart and #pageLines > 0 then
                    local last = blockEnd[idx]
                    local blockLines, blockBytes = last - idx + 1, 0
                    for j = idx, last do blockBytes = blockBytes + #lines[j] + 1 end
                    local fitsHere = #pageLines + blockLines <= maxLines and bytes + blockBytes <= limit
                    local fitsPage = blockLines <= maxLines and blockBytes <= limit
                    if not fitsHere and fitsPage then break end
                end
                local add = #l + ((#pageLines > 0) and 1 or 0)
                if bytes + add > limit then break end
                table.insert(pageLines, l)
                bytes = bytes + add
                idx = idx + 1
            end
        end
        local content = table.concat(pageLines, "\n")
        if content ~= W.getPage(item, i) then
            item:addPage(i, content)
        end
    end

    local rest = {}
    for i = idx, #lines do table.insert(rest, lines[i]) end
    local remaining = W.unwrap(table.concat(rest, "\n")):gsub("^%s+", "")
    -- pieno solo se qualcosa non è davvero entrato (una reimpaginazione può liberare spazio)
    md.AIChatMissionFull = (remaining ~= "") or nil
    return remaining
end

-- Sincronizzazione in multiplayer (chiamata dal client dopo la scrittura):
-- syncItemFields invia al server nome, pagine e dati dell'oggetto, come fa il gioco
function W.sync(player, item)
    local ok, err = pcall(syncItemFields, player, item)
    if not ok then print("[AIChat] sincronizzazione del foglio non riuscita: " .. tostring(err)) end
end
