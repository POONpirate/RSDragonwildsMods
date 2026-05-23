-- ============================================================
--  QuickGrow v1 — UE4SS Lua Mod for RuneScape: Dragonwilds
--
--  When the Eye of Oculus is cast:
--    1. Closes the build menu (suppresses default Oculus behaviour)
--    2. Fires the growth-advance RPC on every farming plot — the
--       server's own Try* logic rejects plots with no active plant
--
--  Performance: farming plot actors are cached after the first
--  cast. The cache refreshes automatically when a new plot
--  actor is constructed (via FarmSlotComponent hook).
-- ============================================================

-- ── Tunables ─────────────────────────────────────────────────
local DEBUG         = false
local DISCOVER_MODE = true   -- set false once the correct RPC name is known

local FARM_PLOT_CLASSES = {
    "BP_FarmPlot1x1_Base_C",
    "BP_FarmPlot1x1_T1_C",
    "BP_FarmPlot1x1_T2_C",
    "BP_FarmPlot1x1_T3_C",
}

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"

-- ── Helpers ──────────────────────────────────────────────────
local function dbg(msg)
    if DEBUG then print("[QuickGrow] " .. tostring(msg) .. "\n") end
end

local function try(fn)
    local ok, v = pcall(fn)
    return ok and v or nil
end

local function valid(obj)
    return obj ~= nil and try(function() return obj:IsValid() end) == true
end

-- ── Persistent cache ──────────────────────────────────────────
local cache = {
    ctrl   = nil,   -- DominionPlayerController
    player = nil,   -- DominionPlayerCharacter
    cmd    = nil,   -- FarmCommandComponent
    plots  = nil,   -- list of {actor, loc, slot, plotID}
}

local function refreshCoreCache()
    -- If the controller is gone the whole world has changed (teleport/reload).
    -- Wipe every cache entry so stale actors aren't used for server RPCs.
    if not valid(cache.ctrl) then
        cache.ctrl   = nil
        cache.player = nil
        cache.cmd    = nil
        cache.plots  = nil

        local ctrls = FindAllOf("DominionPlayerController")
        if ctrls then
            for _, c in ipairs(ctrls) do
                if valid(c) then cache.ctrl = c break end
            end
        end
    end

    if not valid(cache.player) then
        local ps = FindAllOf("DominionPlayerCharacter")
        if ps then
            for _, p in ipairs(ps) do
                if valid(p) then cache.player = p break end
            end
        end
    end

    if not valid(cache.cmd) and valid(cache.ctrl) then
        local cmd = try(function() return cache.ctrl.FarmCommandComponent end)
        if valid(cmd) then cache.cmd = cmd end
    end
end

-- ── Plot cache ───────────────────────────────────────────────
local function buildPlotCache()
    local plots = {}
    local seen  = {}
    for _, className in ipairs(FARM_PLOT_CLASSES) do
        local actors = FindAllOf(className)
        if actors then
            for _, actor in ipairs(actors) do
                if valid(actor) then
                    local addr = tostring(actor)
                    if not seen[addr] then
                        seen[addr] = true
                        local loc  = try(function() return actor:K2_GetActorLocation() end)
                        local slot = try(function()
                            return actor:GetComponentByClass(
                                StaticFindObject("/Script/Dominion.FarmSlotComponent"))
                        end)
                        local plotID = (valid(slot) and
                                       try(function() return slot:GetPlotID() end)) or nil
                        if loc and plotID then
                            table.insert(plots, {
                                actor  = actor,
                                loc    = loc,
                                slot   = slot,
                                plotID = plotID,
                            })
                        end
                    end
                end
            end
        end
    end
    cache.plots = plots
    dbg(string.format("Plot cache built: %d plots", #plots))
end

-- Invalidate the plot cache whenever a new farm plot is placed.
-- We only nil the flag here — no methods are called on the mid-construction
-- component to avoid the C++ crash that occurs during level load.
-- The actual rebuild happens safely and lazily on the next cast.
try(function()
    NotifyOnNewObject("/Script/Dominion.FarmSlotComponent",
        function(_newComp)
            cache.plots = nil
            dbg("FarmSlotComponent constructed — plot cache invalidated")
        end)
end)

-- ── Function discovery ───────────────────────────────────────
-- Uses RegisterHook to probe which Server_* UFunctions actually exist on
-- FarmCommandComponent. RegisterHook succeeds if the path is valid and errors
-- if not — no game state is touched. Runs once, then self-disables.
local discoveryDone = false

local DISCOVER_TARGETS = {
    {
        label = "FarmSlotComponent",
        base  = "/Script/Dominion.FarmSlotComponent:",
        fns   = {
            "TickGrowth",
            "GrowthTick",
            "ProcessGrowthTick",
            "UpdateGrowth",
            "AdvanceGrowthStage",
            "SetGrowthStage",
            "OnGrowthTick",
            "TryAdvanceStage",
            "UpdatePlantGrowth",
            "OnPlantTick",
            "ProgressGrowth",
            "ForceGrowthTick",
        },
    },
    {
        label = "BP_FarmPlot1x1_Base_C (actor)",
        base  = "/Game/Gameplay/BaseBuilding_New/BuildingPieces/Tier1_Brynmoor/Farming/BP_FarmPlot1x1_Base.BP_FarmPlot1x1_Base_C:",
        fns   = {
            "TickGrowth",
            "UpdatePlantGrowth",
            "OnGrowthTick",
            "ReceiveTick",
        },
    },
}

local function runDiscovery()
    if discoveryDone then return end
    discoveryDone = true

    print("[QuickGrow] DISCOVER_MODE: probing UFunctions for growth tick...\n")

    for _, target in ipairs(DISCOVER_TARGETS) do
        local hits, misses = {}, {}
        for _, fn in ipairs(target.fns) do
            local ok = pcall(function()
                RegisterHook(target.base .. fn, function() end, function() end)
            end)
            if ok then hits[#hits + 1] = fn else misses[#misses + 1] = fn end
        end

        print(string.format("[QuickGrow] [%s] FOUND (%d): %s\n",
            target.label, #hits, #hits > 0 and table.concat(hits, ", ") or "none"))
        print(string.format("[QuickGrow] [%s] NOT FOUND (%d): %s\n",
            target.label, #misses, table.concat(misses, ", ")))
    end

    print("[QuickGrow] DISCOVER_MODE: done.\n")
end

-- ── Growth stage advance ──────────────────────────────────────
-- Ordered list of FarmCommandComponent RPC names to attempt.
-- The server's own Try* logic silently rejects plots with no active plant,
-- so we fire on every plot and let the server do the filtering.
-- The first name that succeeds is cached in resolvedGrowFn for fast subsequent calls.
local GROW_FN_CANDIDATES = {
    "Server_TryAdvanceGrowthStage",
    "Server_TryGrowPlant",
    "Server_TickPlantGrowth",
    "Server_AdvancePlantGrowth",
    "Server_TryTickGrowth",
    "Server_TryAdvancePlantStage",
    "Server_GrowPlant",
}
local resolvedGrowFn = nil  -- caches the first working RPC name

local function advancePlotGrowth(plot, cmd, player, done)
    local key = tostring(plot.plotID)
    if done[key] then return false end
    done[key] = true

    -- If we've already resolved a working RPC, use it directly.
    if resolvedGrowFn then
        local ok = try(function()
            cmd[resolvedGrowFn](cmd, plot.plotID, player)
            return true
        end)
        if ok then
            dbg("  Fired growth RPC on plot " .. key)
            return true
        end
        -- Resolved function stopped working (e.g., world reload) — reset and rediscover.
        resolvedGrowFn = nil
    end

    -- Discover which RPC is available by trying each candidate in order.
    for _, fn in ipairs(GROW_FN_CANDIDATES) do
        local ok = try(function()
            cmd[fn](cmd, plot.plotID, player)
            return true
        end)
        if ok then
            resolvedGrowFn = fn
            print(string.format("[QuickGrow] Resolved growth RPC: %s\n", fn))
            dbg("  Fired growth RPC on plot " .. key)
            return true
        end
    end

    print("[QuickGrow] WARNING: No growth RPC succeeded for plot " .. key
        .. ". Run the PropertyDumper against FarmCommandComponent for the correct RPC name.\n")
    return false
end

-- ── Main cast handler ─────────────────────────────────────────
local function onOculusCast()
    ExecuteInGameThread(function()
        if DISCOVER_MODE then runDiscovery() end

        refreshCoreCache()

        local cmd    = cache.cmd
        local player = cache.player
        if not valid(cmd) or not valid(player) then
            dbg("Core cache not ready — skipping cast")
            return
        end

        if not cache.plots then buildPlotCache() end

        local done  = {}
        local fired = 0
        local failed = 0

        for _, plot in ipairs(cache.plots) do
            if valid(plot.actor) then
                local ok = advancePlotGrowth(plot, cmd, player, done)
                if ok then fired = fired + 1 else failed = failed + 1 end
            end
        end

        print(string.format("[QuickGrow] Cast complete: RPC fired on %d plot(s)%s.\n",
            fired, failed > 0 and (", " .. failed .. " failed (no RPC found)") or ""))
    end)
end

-- ── Hooks ─────────────────────────────────────────────────────
local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if hook_registered then return end

    ExecuteInGameThread(function()
        if hook_registered then return end

        -- Suppress the Oculus build menu so it doesn't open alongside our effect.
        local ok_deact = pcall(function()
            RegisterHook("/Script/Dominion.OculusComponent:ActivateOculus",
                function(self) end,
                function(self)
                    local ok_get, comp = pcall(function() return self:get() end)
                    if not ok_get or not comp then return end
                    pcall(function() comp:DeactivateOculus() end)
                    dbg("Build menu suppressed via DeactivateOculus.")
                end
            )
        end)
        if ok_deact then
            dbg("OculusComponent:ActivateOculus hook registered.")
        else
            print("[QuickGrow] WARNING: Could not hook ActivateOculus — build menu may still open.\n")
        end

        -- Main Eye of Oculus cast hook.
        local ok_main, err_main = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance)
                    onOculusCast()
                end,
                function(self, Instance) end
            )
        end)

        if not ok_main then
            print(string.format("[QuickGrow] ERROR: Failed to register Oculus hook: %s\n",
                tostring(err_main)))
        else
            hook_registered = true
            print("[QuickGrow] All hooks registered. Waiting for Eye of Oculus cast.\n")
        end
    end)
end)

print("[QuickGrow] v1.0 loaded.\n")
