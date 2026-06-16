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

-- No autoexec o script pode rodar antes do LocalPlayer existir; espera ele aparecer.
local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait()
    LocalPlayer = Players.LocalPlayer
end

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

-- Retorna nil (nao 0) quando o Data ainda nao replicou, pra nunca sobrescrever
-- um valor bom com 0 transitorio no servidor.
local function readStat(key)
    local node = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
    node = node and node:FindFirstChild("Data")
    for _, name in ipairs(STAT_PATHS[key]) do
        node = node and node:FindFirstChild(name)
    end
    if not node then return nil end
    local ok, num = pcall(function() return tonumber(node.Value) end)
    return ok and num or nil
end

-- Envia heartbeat
local function sendHeartbeat()
    -- Se o Data.Coins ainda nao replicou, nao envia: evita sobrescrever
    -- um mush bom com 0 transitorio (server faz overwrite cego do campo).
    local mush = readStat("mush")
    if mush == nil then
        warn("[CoS-tracker] Data.Coins ainda nao pronto, pulando heartbeat")
        return
    end
    local payload = {
        userId = LocalPlayer.UserId,
        username = LocalPlayer.Name,
        mush          = mush,
        maxGrowth     = readStat("maxGrowth")     or 0,
        partialGrowth = readStat("partialGrowth") or 0,
        reviveToken   = readStat("reviveToken")   or 0,
        deathToken    = readStat("deathToken")    or 0,
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

-- Espera os dados replicarem antes do 1o heartbeat (evita 1o envio com 0)
do
    local pg = LocalPlayer:WaitForChild("PlayerGui", 30)
    local data = pg and pg:WaitForChild("Data", 30)
    if data then data:WaitForChild("Coins", 15) end
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
