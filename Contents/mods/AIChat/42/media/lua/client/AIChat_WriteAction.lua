--[[
    AIChat_WriteAction.lua
    Azione a tempo: il personaggio scrive la missione sul foglio.
    Scrive direttamente sull'oggetto; in multiplayer il foglio viene poi
    sincronizzato con il server (vedi AIChat_MissionWriter.lua, W.sync).
]]

require "TimedActions/ISBaseTimedAction"
require "AIChat_MissionWriter"

AIChatWriteAction = ISBaseTimedAction:derive("AIChatWriteAction")
AIChatWriteAction.Type = "AIChatWriteAction"

function AIChatWriteAction:isValid()
    local inv = self.character:getInventory()
    return inv:contains(self.item) and inv:contains(self.pen)
end

function AIChatWriteAction:waitToStart()
    return false
end

function AIChatWriteAction:start()
    pcall(function() self:setActionAnim("Loot") end)
end

function AIChatWriteAction:update()
    pcall(function() self.item:setJobDelta(self:getJobDelta()) end)
end

function AIChatWriteAction:stop()
    pcall(function() self.item:setJobDelta(0.0) end)
    AIChatMissions.onWriteInterrupted(self.job)
    ISBaseTimedAction.stop(self)
end

function AIChatWriteAction:perform()
    pcall(function() self.item:setJobDelta(0.0) end)
    AIChatMissions.doWrite(self.job, self.item)
    ISBaseTimedAction.perform(self)
end

function AIChatWriteAction:getDuration()
    -- più testo = più tempo (con un minimo e un massimo)
    local len = #(self.job and self.job.text or "")
    return math.max(150, math.min(900, math.floor(len * 1.5)))
end

function AIChatWriteAction:new(character, item, pen, job)
    local o = ISBaseTimedAction.new(self, character)
    o.item = item
    o.pen = pen
    o.job = job
    o.stopOnWalk = true
    o.stopOnRun = true
    o.maxTime = o:getDuration()
    local ok, instant = pcall(function() return character:isTimedActionInstant() end)
    if ok and instant then o.maxTime = 1 end
    return o
end
