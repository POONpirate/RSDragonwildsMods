-- ============================================================
--  HumidifyPlus v15 — UE4SS Lua Mod for RuneScape: Dragonwilds
--
--  When Humidify is cast (regardless of weather):
--    1. Waters plots — Clean Water if Cleansing Rain perk unlocked
--    2. Cures diseased plants (Cleansing Rain perk)
--    3. Applies Compost and deducts 50 charges from bucket
--
--  Performance: all slow lookups (FindAllOf) are cached after the
--  first cast. Plot cache refreshes automatically when a new plot
--  actor is constructed.
-- ============================================================

-- ── Tunables ─────────────────────────────────────────────────
local COMPOST_LEVEL   = 2
local COMPOST_CHARGES = 50
local WATER_CHARGES   = 1
local SCAN_RADIUS_CM  = 1600  -- covers ~15x15 plot area (plots ~150 UU wide)
local DEBUG           = false

local FARM_PLOT_CLASSES = {
    "BP_FarmPlot1x1_Base_C",
    "BP_FarmPlot1x1_T1_C",
    "BP_FarmPlot1x1_T2_C",
    "BP_FarmPlot1x1_T3_C",
}

-- ── Helpers ──────────────────────────────────────────────────
local function dbg(msg)
    if DEBUG then print("[HumidifyPlus] " .. tostring(msg) .. "\n") end
end

local function try(fn)
    local ok, v = pcall(fn)
    return ok and v or nil
end

local function safeCall(obj, method, ...)
    local args = {...}
    try(function() obj[method](obj, table.unpack(args)) end)
end

local function dist2D(a, b)
    local dx = a.X - b.X
    local dy = a.Y - b.Y
    return math.sqrt(dx*dx + dy*dy)
end

-- ── Persistent cache (survives between casts) ─────────────────
local cache = {
    ctrl      = nil,   -- DominionPlayerController
    player    = nil,   -- DominionPlayerCharacter
    cmd       = nil,   -- FarmCommandComponent
    perkComp  = nil,   -- SkillPerkComponent
    perk      = nil,   -- SkillPerkData (Cleansing Rain)
    bucket    = nil,   -- HeldContainerEquipmentItem (compost)
    plots     = nil,   -- list of {actor, loc, slot, plotID}
}

local function valid(obj)
    return obj ~= nil and try(function() return obj:IsValid() end) == true
end

local function refreshCoreCache()
    -- If the controller is gone the whole world has changed (teleport/reload).
    -- Wipe every cache entry so stale actors aren't used for server RPCs.
    if not valid(cache.ctrl) then
        cache.ctrl     = nil
        cache.player   = nil
        cache.cmd      = nil
        cache.perkComp = nil
        cache.plots    = nil   -- forces plot rebuild for the new area
        local ctrls = FindAllOf("DominionPlayerController")
        if ctrls then
            for _, c in ipairs(ctrls) do
                -- IsLocalController not exposed by UE4SS; just use first valid
                if valid(c) then cache.ctrl = c break end
            end
        end
    end

    -- Player
    if not valid(cache.player) then
        local ps = FindAllOf("DominionPlayerCharacter")
        if ps then
            for _, p in ipairs(ps) do
                -- IsLocallyControlled not exposed by UE4SS; just use first valid
                if valid(p) then cache.player = p break end
            end
        end
    end

    -- FarmCommandComponent
    if not valid(cache.cmd) and valid(cache.ctrl) then
        local cmd = try(function() return cache.ctrl.FarmCommandComponent end)
        if valid(cmd) then cache.cmd = cmd end
    end

    -- SkillPerkComponent + perk asset
    if not valid(cache.perkComp) and valid(cache.ctrl) then
        local pc = try(function() return cache.ctrl:GetSkillPerkComponent() end)
        if valid(pc) then cache.perkComp = pc end
    end
    if not valid(cache.perk) then
        local perks = FindAllOf("SkillPerkData")
        if perks then
            for _, p in ipairs(perks) do
                if valid(p) then
                    local name = try(function() return p:GetFullName() end)
                    if type(name) == "string" and name:find("HumidifySpellUpgrade") then
                        cache.perk = p break
                    end
                end
            end
        end
    end
end

local function refreshBucketCache()
    -- Bucket only needs refreshing if invalid or empty
    if valid(cache.bucket) then
        local qty = try(function() return cache.bucket.Contents.Quantity end) or 0
        if qty > 0 then return end  -- still has charges, keep it
    end
    cache.bucket = nil
    local items = FindAllOf("HeldContainerEquipmentItem")
    if not items then return end
    for _, item in ipairs(items) do
        if valid(item) then
            local qty = try(function() return item.Contents.Quantity end) or 0
            if qty > 0 then
                local cd = try(function() return item.Contents.ContentData end)
                if valid(cd) then
                    local name = try(function() return cd:GetFullName() end)
                    if type(name) == "string" and name:find("Compost") then
                        cache.bucket = item
                        return
                    end
                end
            end
        end
    end
end

-- Plot cache: built once, auto-refreshed when new plots are constructed
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

-- Note: the original NotifyOnNewObject("/Script/Engine.Actor") hook that
-- auto-refreshed the plot cache on new plot construction was removed.
-- Hooking all Actor spawns during level load (e.g. on teleport) causes a
-- C++ crash when GetComponentByClass is called on mid-construction actors
-- before Lua pcall can intercept it.  The cache is already cleared in
-- refreshCoreCache() when the controller goes stale (every teleport), and
-- onHumidifyCast() rebuilds it on the next cast — so the hook is not needed.

-- ── Apply effects to one plot ─────────────────────────────────
local function applyToPlot(plot, cmd, player, waterIndex, cleansingRain, done)
    local key = tostring(plot.plotID)
    if done[key] then return end
    done[key] = true

    -- 1. Water
    safeCall(cmd, "Server_TryApplyWateringCharges",
             plot.plotID, waterIndex, WATER_CHARGES, player)

    -- 2. Cure disease
    if cleansingRain and valid(plot.slot) then
        if try(function() return plot.slot:CanHealDisease() end) then
            safeCall(cmd, "Server_TryHealDisease", plot.plotID, player)
        end
    end

    -- 3. Compost
    local fertilized = valid(plot.slot) and
                       (try(function() return plot.slot:IsFullyFertilized() end) or false)
    if not fertilized then
        safeCall(cmd, "Server_TryFertilizePlot",
                 plot.plotID, COMPOST_LEVEL, COMPOST_CHARGES, player)
        dbg("  Composted plot " .. key)
    end
end

-- ── Main cast handler ─────────────────────────────────────────
local function onHumidifyCast()
    ExecuteInGameThread(function()
        -- Refresh only stale cache entries (no FindAllOf if already cached)
        refreshCoreCache()
        refreshBucketCache()

        local cmd    = cache.cmd
        local player = cache.player
        if not valid(cmd) or not valid(player) then return end

        -- Build plot cache on first cast
        if not cache.plots then buildPlotCache() end

        local cleansingRain = valid(cache.perkComp) and valid(cache.perk) and
                              try(function() return cache.perkComp:IsPerkUnlocked(cache.perk) end) == true
        local waterIndex    = cleansingRain and 1 or 0
        local done          = {}

        local playerLoc = try(function() return player:K2_GetActorLocation() end)
        if not playerLoc then return end

        local rotation  = try(function() return player:K2_GetActorRotation() end)
        local fwdX, fwdY = 0, 0
        if rotation then
            local yaw = math.rad(rotation.Yaw)
            fwdX, fwdY = math.cos(yaw), math.sin(yaw)
        end

        local origins = {
            { X = playerLoc.X,
              Y = playerLoc.Y,
              r = SCAN_RADIUS_CM },
            { X = playerLoc.X + fwdX * SCAN_RADIUS_CM * 0.5,
              Y = playerLoc.Y + fwdY * SCAN_RADIUS_CM * 0.5,
              r = SCAN_RADIUS_CM * 0.7 },
        }

        local composted = 0
        for _, plot in ipairs(cache.plots) do
            if valid(plot.actor) then
                -- Refresh location from actor (plot may have moved, unlikely but safe)
                for _, origin in ipairs(origins) do
                    if dist2D(origin, plot.loc) <= origin.r then
                        local before = done[tostring(plot.plotID)]
                        applyToPlot(plot, cmd, player, waterIndex, cleansingRain, done)
                        if not before then composted = composted + 1 end
                        break
                    end
                end
            end
        end

        -- Deduct compost cost once per cast
        if composted > 0 and valid(cache.bucket) then
            safeCall(cache.bucket, "TryDispenseCharge")
            dbg(string.format("Cast complete: %d plot(s), compost deducted", composted))
        end
    end)
end

-- ── Hook ─────────────────────────────────────────────────────
local hooked = try(function()
    NotifyOnNewObject("/Script/Dominion.SpellModule_HumidifyRuntime",
        function(obj)
            if obj and obj:IsValid() then onHumidifyCast() end
        end)
    return true
end)

print(string.format("[HumidifyPlus] v15.0 loaded (hook=%s).\n", tostring(hooked == true)))
