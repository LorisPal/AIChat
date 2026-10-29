--[[
    AIChat_Server.lua
    Solo multiplayer: il client chiede al server di scrivere sul foglio, così il
    contenuto viene salvato sul server e sincronizzato con tutti.
    La chiamata all'IA resta sul PC di chi usa la chat: il server non vede
    né usa nessuna chiave API.
]]

require "AIChat_MissionWriter"

local W = AIChatMissionWriter
local MAX_TEXT = 4000

local function reply(player, args)
    sendServerCommand(player, "AIChat", "writeResult", args)
end

local function onClientCommand(module, command, player, args)
    if module ~= "AIChat" or command ~= "writeMission" or not player or type(args) ~= "table" then
        return
    end

    local item = player:getInventory():getItemWithIDRecursiv(args.itemId)
    if not item or not W.isWritable(item) then
        reply(player, { jobId = args.jobId, ok = false, reason = "foglio non trovato nell'inventario" })
        return
    end
    if W.isLockedFor(item, player:getUsername()) then
        reply(player, { jobId = args.jobId, ok = false, reason = "foglio bloccato da un altro giocatore" })
        return
    end

    local text = tostring(args.text or ""):sub(1, MAX_TEXT)
    local remaining = W.append(item, text, {
        target = tostring(args.target or "?"),
        part = tonumber(args.part) or 1,
        writer = tostring(args.writer or ""),
        pageChars = tonumber(args.pageChars),
        lineWidth = tonumber(args.lineWidth),
        lines = tonumber(args.lines),
    })
    W.sync(player, item)
    reply(player, { jobId = args.jobId, ok = true, remaining = remaining })
end

Events.OnClientCommand.Add(onClientCommand)
