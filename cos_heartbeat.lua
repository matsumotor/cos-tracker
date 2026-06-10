--[[
    Creatures of Sonaria - Heartbeat Tracker
    Roda no executor (mesmo modelo do da_heartbeat.lua do Dragon Adventures).

    Envia a cada 30s pro servidor:
      - userId, username
      - mush (Mushrooms), maxGrowth, partialGrowth, reviveToken, deathToken
      - placeId, jobId, sessionStart

    SETUP via loadstring no autoexec de cada conta:

        _G.COS_TRACKER_TOKEN = "SEU_TOKEN_DO_RENDER"
        loadstring(game:HttpGet("https://cos-tracker.onrender.com/heartbeat.lua"))()

    Opcionalmente sobreescreve URL/intervalo:
        _G.COS_TRACKER_URL = "https://outra-url.com/heartbeat"
        _G.COS_TRACKER_INTERVAL = 60
]]

-- ============ CONFIG (le de _G, nunca commita secret) ============
local SERVER_URL   = _G.COS_TRACKER_URL or "https://cos-tracker.onrender.com/heartbeat"
local AUTH_TOKEN   = _G.COS_TRACKER_TOKEN
local INTERVAL_SEC = _G.COS_TRACKER_INTERVAL or 30

if not AUTH_TOKEN or AUTH_TOKEN == "" then
    warn("[CoS-tracker] _G.COS_TRACKER_TOKEN nao setado. Setar antes do loadstring. Abortando.")
    return
end
-- ==================================================================

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

-- http_request varia por executor; tenta os mais comuns
local request = http_request or syn and syn.request or request or (fluxus and fluxus.request) or http and http.request
if not request then
    warn("[CoS-tracker] executor nao suporta http_request, abortando")
    return
end

local sessionStart = os.time() * 1000  -- ms desde epoch

---------------------------------------------------------------
-- Caminhos dos valores no client — VALIDADOS AO VIVO em 2026-06-10
-- via bridge (/exec). Nomes internos do CoS diferem dos nomes da UI:
--   Mush (moeda)        -> PlayerGui.Data.Coins
--   Max Growth Token    -> PlayerGui.Data.Items.FullGrowToken
--   Partial Growth      -> PlayerGui.Data.Items.PartialGrowToken
--   Revive Token        -> PlayerGui.Data.Items.CreatureReviveToken
--   Death Gacha Token   -> PlayerGui.Data.Items.DeathGachaToken
-- (NAO usar busca por nome: "Konomushi" casa com "mush",
--  "PartialMissionUnlockToken" casa com "partial", etc.)
---------------------------------------------------------------
local STAT_PATHS = {
    mush          = { "Coins" },
    maxGrowth     = { "Items", "FullGrowToken" },
    partialGrowth = { "Items", "PartialGrowToken" },
    reviveToken   = { "Items", "CreatureReviveToken" },
    deathToken    = { "Items", "DeathGachaToken" },
}

local function readStat(key)
    local node = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
    node = node and node:FindFirstChild("Data")
    for _, name in ipairs(STAT_PATHS[key]) do
        node = node and node:FindFirstChild(name)
    end
    if not node then return 0 end
    local ok, num = pcall(function() return tonumber(node.Value) end)
    return ok and num or 0
end

-- Envia heartbeat
local function sendHeartbeat()
    local payload = {
        userId = LocalPlayer.UserId,
        username = LocalPlayer.Name,
        mush          = readStat("mush"),
        maxGrowth     = readStat("maxGrowth"),
        partialGrowth = readStat("partialGrowth"),
        reviveToken   = readStat("reviveToken"),
        deathToken    = readStat("deathToken"),
        placeId = game.PlaceId,
        jobId = game.JobId,
        sessionStart = sessionStart,
    }
    local ok, err = pcall(function()
        local res = request({
            Url = SERVER_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["X-Auth-Token"] = AUTH_TOKEN,
            },
            Body = HttpService:JSONEncode(payload),
        })
        if res and res.StatusCode and res.StatusCode >= 400 then
            warn(("[CoS-tracker] heartbeat http %d: %s"):format(res.StatusCode, tostring(res.Body):sub(1,100)))
        end
    end)
    if not ok then
        warn("[CoS-tracker] erro ao enviar: " .. tostring(err))
    end
end

-- Heartbeat inicial e loop
print(("[CoS-tracker] iniciado userId=%d username=%s"):format(LocalPlayer.UserId, LocalPlayer.Name))
sendHeartbeat()

task.spawn(function()
    while true do
        task.wait(INTERVAL_SEC)
        sendHeartbeat()
    end
end)
