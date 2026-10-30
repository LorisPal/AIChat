--[[
    AIChat_Window.lua
    Finestra di chat in gioco. Premi F8 per aprirla/chiuderla.
]]

require "ISUI/ISCollapsableWindow"
require "ISUI/ISRichTextPanel"
require "ISUI/ISTextEntryBox"
require "ISUI/ISButton"
require "ISUI/ISTickBox"
require "AIChat_Bridge"

AIChatWindow = ISCollapsableWindow:derive("AIChatWindow")
AIChatWindow.instance = nil
AIChatWindow.TOGGLE_KEY = Keyboard.KEY_F8
AIChatWindow.MAX_LOG = 60   -- messaggi conservati nella finestra

local PROVIDERS = {
    { id = "claude", label = "Claude" },
    { id = "openai", label = "ChatGPT" },
    { id = "gemini", label = "Gemini" },
}

local function providerLabel(id)
    for _, p in ipairs(PROVIDERS) do
        if p.id == id then return p.label end
    end
    return id
end

-- Il pannello rich text interpreta "<...>" come tag: neutralizziamoli
local function sanitize(text)
    text = tostring(text or "")
    text = text:gsub("<", "(")
    text = text:gsub(">", ")")
    text = text:gsub("\r", "")
    text = text:gsub("\n", " <LINE> ")
    return text
end

-- ---------------------------------------------------------------------------
-- Costruzione
-- ---------------------------------------------------------------------------

function AIChatWindow:new(x, y, w, h)
    local o = ISCollapsableWindow:new(x, y, w, h)
    setmetatable(o, self)
    self.__index = self
    o.title = "AI Chat"
    o.resizable = false
    o.log = {}
    return o
end

function AIChatWindow:createChildren()
    ISCollapsableWindow.createChildren(self)

    local pad = 8
    local th = self:titleBarHeight()
    local btnH = 24
    local entryH = 26

    -- Riga superiore: provider, contesto, reset
    local topY = th + pad
    self.providerBtn = ISButton:new(pad, topY, 140, btnH, "", self, AIChatWindow.onToggleProvider)
    self.providerBtn:initialise()
    self:addChild(self.providerBtn)

    self.contextBox = ISTickBox:new(pad + 150, topY + 2, 20, 20, "", nil, nil)
    self.contextBox:initialise()
    self.contextBox:addOption("Invia contesto del personaggio")
    self.contextBox:setSelected(1, true)
    self:addChild(self.contextBox)

    self.resetBtn = ISButton:new(self.width - pad - 90, topY, 90, btnH, "Nuova chat", self, AIChatWindow.onReset)
    self.resetBtn:initialise()
    self:addChild(self.resetBtn)

    -- Area messaggi
    local logY = topY + btnH + pad
    local logH = self.height - logY - entryH - pad * 2
    self.logPanel = ISRichTextPanel:new(pad, logY, self.width - pad * 2, logH)
    self.logPanel:initialise()
    self.logPanel.autosetheight = false
    self.logPanel.clip = true
    self.logPanel.background = true
    self.logPanel.backgroundColor = { r = 0, g = 0, b = 0, a = 0.6 }
    self.logPanel:addScrollBars()
    self:addChild(self.logPanel)

    -- Campo di testo + invio
    local entryY = self.height - entryH - pad
    self.entry = ISTextEntryBox:new("", pad, entryY, self.width - pad * 3 - 80, entryH)
    self.entry:initialise()
    self.entry:instantiate()
    self.entry.window = self
    self.entry.onCommandEntered = AIChatWindow.onEntryEnter
    self:addChild(self.entry)

    self.sendBtn = ISButton:new(self.width - pad - 80, entryY, 80, entryH, "Invia", self, AIChatWindow.onSend)
    self.sendBtn:initialise()
    self:addChild(self.sendBtn)

    self:updateProviderButton()
    self:addLine("system", "Scrivi una domanda e premi Invio. Il ponte ai_bridge.py deve essere in esecuzione.")
end

-- ---------------------------------------------------------------------------
-- Log messaggi
-- ---------------------------------------------------------------------------

function AIChatWindow:addLine(kind, text, extra)
    local prefix
    if kind == "user" then
        prefix = "<RGB:0.6,0.85,1> Tu: <RGB:1,1,1> "
    elseif kind == "reply" then
        prefix = "<RGB:0.6,1,0.6> " .. providerLabel(extra or AIChat.provider) .. ": <RGB:1,1,1> "
    elseif kind == "error" then
        prefix = "<RGB:1,0.45,0.45> Errore: "
    elseif kind == "history" then
        prefix = "<RGB:0.85,0.8,0.55> Storia salvata: <LINE> <RGB:0.75,0.75,0.75> "
    elseif kind == "pending" then
        prefix = "<RGB:0.7,0.7,0.7> "
        text = providerLabel(AIChat.provider) .. " sta scrivendo..."
    else
        prefix = "<RGB:0.75,0.75,0.75> "
    end

    -- rimuove l'eventuale riga "sta scrivendo..."
    if self.log[#self.log] and self.log[#self.log].pending then
        table.remove(self.log)
    end

    table.insert(self.log, { text = prefix .. sanitize(text), pending = (kind == "pending") })
    while #self.log > AIChatWindow.MAX_LOG do
        table.remove(self.log, 1)
    end
    self:refreshLog()
end

function AIChatWindow:refreshLog()
    local parts = {}
    for _, entry in ipairs(self.log) do
        table.insert(parts, entry.text)
    end
    self.logPanel.text = table.concat(parts, " <LINE> <LINE> ")
    self.logPanel:paginate()
    -- scorre fino in fondo
    pcall(function()
        local overflow = self.logPanel:getScrollHeight() - self.logPanel:getHeight()
        if overflow > 0 then self.logPanel:setYScroll(-overflow) end
    end)
end

-- ---------------------------------------------------------------------------
-- Azioni
-- ---------------------------------------------------------------------------

function AIChatWindow:updateProviderButton()
    self.providerBtn:setTitle("Modello: " .. providerLabel(AIChat.provider))
end

function AIChatWindow:onToggleProvider()
    if AIChat.isBusy() then return end
    -- solo i modelli con la chiave configurata nel ponte
    local usable = {}
    for _, p in ipairs(PROVIDERS) do
        if AIChat.isAvailable(p.id) then table.insert(usable, p) end
    end
    if #usable <= 1 then
        self:addLine("system", "È configurato solo " .. providerLabel(AIChat.provider) ..
            ": aggiungi altre chiavi API in config.json per cambiare modello.")
        return
    end
    local nextId = usable[1].id
    for i, p in ipairs(usable) do
        if p.id == AIChat.provider then
            nextId = usable[(i % #usable) + 1].id
        end
    end
    AIChat.setProvider(nextId)
    self:updateProviderButton()
    self:addLine("system", "Ora stai parlando con " .. providerLabel(nextId) .. ".")
end

-- "Nuova chat" archivia la storia: serve un secondo clic entro 4 secondi per confermare
function AIChatWindow:onReset()
    local now = getTimestampMs()
    if self.resetArmedAt and now - self.resetArmedAt < 4000 then
        self.resetArmedAt = nil
        self.resetBtn:setTitle("Nuova chat")
        AIChat.reset()
    else
        self.resetArmedAt = now
        self.resetBtn:setTitle("Conferma?")
        self:addLine("system", "Clicca di nuovo su \"Conferma?\" per chiudere questa storia e iniziarne una nuova.")
    end
end

function AIChatWindow:update()
    ISCollapsableWindow.update(self)
    if self.resetArmedAt and getTimestampMs() - self.resetArmedAt >= 4000 then
        self.resetArmedAt = nil
        self.resetBtn:setTitle("Nuova chat")
    end
end

function AIChatWindow:onSend()
    local text = self.entry:getText()
    if not text or text:match("^%s*$") then return end
    if AIChat.isBusy() then
        self:addLine("error", "Attendi la risposta precedente.")
        return
    end
    local withContext = self.contextBox:isSelected(1)
    self:addLine("user", text)
    if AIChat.send(text, withContext) then
        self.entry:setText("")
    end
end

-- chiamata dal campo di testo quando si preme Invio (self = campo di testo)
function AIChatWindow.onEntryEnter(entry)
    if entry.window then entry.window:onSend() end
end

function AIChatWindow:close()
    self:setVisible(false)
    self:removeFromUIManager()
    AIChatWindow.instance = nil
end

-- ---------------------------------------------------------------------------
-- Apertura / chiusura
-- ---------------------------------------------------------------------------

function AIChatWindow.toggle()
    if AIChatWindow.instance then
        AIChatWindow.instance:close()
        return
    end
    local w, h = 520, 420
    local x = getCore():getScreenWidth() - w - 40
    local y = 80
    local win = AIChatWindow:new(x, y, w, h)
    win:initialise()
    win:addToUIManager()
    win:setVisible(true)
    AIChatWindow.instance = win
    -- ripristina i messaggi della sessione precedente
    if AIChatWindow.savedLog then
        win.log = AIChatWindow.savedLog
        win:refreshLog()
    end
    win.entry:focus()
    -- alla prima apertura dopo il caricamento recupera la storia salvata dal ponte
    if not AIChatWindow.resumeRequested then
        AIChatWindow.resumeRequested = true
        AIChat.resume()
    end
end

-- conserva la cronologia anche quando la finestra viene chiusa
local originalClose = AIChatWindow.close
function AIChatWindow:close()
    AIChatWindow.savedLog = self.log
    originalClose(self)
end

AIChat.addListener(function(kind, text, extra)
    if kind == "missions" then return end   -- gestite da AIChat_Missions.lua
    local win = AIChatWindow.instance
    if kind == "provider" then
        if win then
            win:updateProviderButton()
            win:addLine("system", "Il modello scelto non ha la chiave API configurata: uso " .. providerLabel(text) .. ".")
        end
        return
    end
    if win then
        win:addLine(kind, text, extra)
    elseif kind == "reply" or kind == "error" then
        -- finestra chiusa: salva il messaggio e avvisa sopra la testa del personaggio
        AIChatWindow.savedLog = AIChatWindow.savedLog or {}
        local tmp = { log = AIChatWindow.savedLog, refreshLog = function() end }
        AIChatWindow.addLine(tmp, kind, text, extra)
        local player = getPlayer()
        if player then
            pcall(function() player:Say("[AI] Nuova risposta - premi F8") end)
        end
    end
end)

local function onKeyPressed(key)
    if key == AIChatWindow.TOGGLE_KEY and getPlayer() then
        AIChatWindow.toggle()
    end
end

Events.OnKeyPressed.Add(onKeyPressed)
