-- ============================================================
--  QuickGrow v4.7 — UE4SS Lua Mod for RS: Dragonwilds
--
--  v4.6 findings:
--   * StoredTime writes STICK (read-back confirmed) but CanSleep
--     ignores them entirely -> StoredTime is not the live clock.
--   * 0/65 candidate names exist on InGameTimeActor (native+BP),
--     DominionGameMode, DominionGameState. Name-guessing is done.
--
--  v4.7 on a daytime cast:
--   1. List ALL BP_InGameTimeActor_C instances (maybe we wrote to
--      the wrong one / a CDO) and their StoredTime values.
--   2. SAFE property map of time actor + GameMode + GameState:
--      pass 1 = names + types only (no value reads at all);
--      pass 2 = values for numeric/bool/enum types ONLY.
--      (v4.3 crashed reading exotic property values blindly.)
--   3. Hop loop now writes StoredTime on ALL instances.
--  Night cast unchanged: Sleep(player) works.
-- ============================================================

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"
local BED_CLASS  = "BP_BaseBuilding_Bed_C"
local TIME_CLASS = "BP_InGameTimeActor_C"

local GAME_HOUR = 3600
local MAX_HOPS  = 30

-- ── Helpers ──────────────────────────────────────────────────
local function log(msg)
    print("[QuickGrow] " .. tostring(msg) .. "\n")
end

local function try(fn)
    local ok, v = pcall(fn)
    return ok and v or nil
end

local function valid(obj)
    return obj ~= nil and try(function() return obj:IsValid() end) == true
end

local function describe(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "number" or t == "boolean" or t == "string" then return tostring(v) end
    local full = try(function() return v:GetFullName() end)
    if full then return tostring(full) end
    return string.format("%s (%s)", tostring(v), t)
end

-- ── Cache ─────────────────────────────────────────────────────
local cache = { ctrl = nil, player = nil }

local function refreshCache()
    if not valid(cache.ctrl) then
        cache.ctrl   = nil
        cache.player = nil
        local ctrls = FindAllOf("DominionPlayerController")
        if ctrls then
            for _, c in ipairs(ctrls) do
                if valid(c) then cache.ctrl = c; break end
            end
        end
    end
    if not valid(cache.player) then
        local ps = FindAllOf("DominionPlayerCharacter")
        if ps then
            for _, p in ipairs(ps) do
                if valid(p) then cache.player = p; break end
            end
        end
    end
end

-- ── Bed finder ────────────────────────────────────────────────
local function findPlayerBed()
    local beds = FindAllOf(BED_CLASS)
    if not beds then return nil end
    local anyBed = nil
    for _, bed in ipairs(beds) do
        if valid(bed) then
            anyBed = anyBed or bed
            local claimed = try(function()
                local bedComp = bed.Bed
                if valid(bedComp) then
                    return bedComp:IsClaimedByPlayer(cache.player)
                end
                return false
            end)
            if claimed then return bed end
        end
    end
    return anyBed
end

-- ── Sleep-state check ─────────────────────────────────────────
local function getRestComp()
    return try(function() return cache.player:GetPlayerRestComponent() end)
end

local function isSleepingNow(restComp)
    if not valid(restComp) then return false end
    local v = try(function() return restComp:GetIsSleeping() end)
    if v == true then return true end
    v = try(function() return restComp.IsSleeping end)
    return v == true
end

-- ── Time actors (ALL instances) ──────────────────────────────
local function findTimeActors()
    local out = {}
    local actors = FindAllOf(TIME_CLASS)
    if actors then
        for _, a in ipairs(actors) do
            if valid(a) then out[#out + 1] = a end
        end
    end
    return out
end

-- ── Safe property mapping ────────────────────────────────────
-- Pass 1: names + types only. Pass 2: values for safe types only.
local SAFE_VALUE_TYPES = {
    FloatProperty = true, DoubleProperty = true,
    IntProperty = true, Int64Property = true, Int16Property = true,
    UInt32Property = true, UInt64Property = true, UInt16Property = true,
    BoolProperty = true, ByteProperty = true, EnumProperty = true,
    NameProperty = true, StrProperty = true,
}

local function mapProps(obj, label, stopAtEngine)
    local cls = try(function() return obj:GetClass() end)
    local depth = 0
    while cls ~= nil and depth < 8 do
        local cname = try(function() return cls:GetFullName() end) or "?"
        if stopAtEngine and string.find(cname, "/Script/Engine.") then break end
        log("  [" .. label .. "] class: " .. cname)

        -- Pass 1: collect names + types, NO value reads
        local props = {}
        pcall(function()
            cls:ForEachProperty(function(prop)
                local pname = try(function() return prop:GetFName():ToString() end) or "?"
                local ptype = try(function() return prop:GetClass():GetFName():ToString() end) or "?"
                props[#props + 1] = { name = pname, ptype = ptype }
            end)
        end)
        for _, p in ipairs(props) do
            log(string.format("    %s : %s", p.name, p.ptype))
        end

        -- Pass 2: values for safe types only (names are already logged
        -- above, so even a crash here costs us nothing)
        for _, p in ipairs(props) do
            if SAFE_VALUE_TYPES[p.ptype] then
                local val = try(function() return obj[p.name] end)
                log(string.format("    %s = %s", p.name, describe(val)))
            end
        end

        cls = try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
end

local mapped = false
local function mapEverything(timeActors)
    if mapped then return end
    mapped = true
    log("=== SAFE PROPERTY MAP ===")
    for i, ta in ipairs(timeActors) do
        log(string.format("TimeActor %d: %s", i,
            try(function() return ta:GetFullName() end) or "?"))
    end
    if timeActors[1] then mapProps(timeActors[1], "TimeActor", true) end
    for _, gname in ipairs({ "DominionGameState", "DominionGameMode" }) do
        local objs = FindAllOf(gname)
        if objs then
            for _, o in ipairs(objs) do
                if valid(o) then
                    log(gname .. ": " .. (try(function() return o:GetFullName() end) or "?"))
                    mapProps(o, gname, true)
                    break
                end
            end
        end
    end
    log("=== MAP COMPLETE — send UE4SS.log back ===")
end

-- ── Day-advance core ─────────────────────────────────────────
local function advanceWorldDay()
    if not valid(cache.player) then
        log("WARNING: Player not ready.")
        return false
    end

    local bed = findPlayerBed()
    if not bed then
        log("WARNING: No bed found. Build and claim a bed first.")
        return false
    end

    local bedComp = try(function() return bed.Bed end)
    if not valid(bedComp) then
        log("WARNING: BedComponent is nil.")
        return false
    end

    local restComp = getRestComp()

    if isSleepingNow(restComp) then
        log("Already sleeping; skipping.")
        return true
    end

    local function canSleep()
        return try(function() return bedComp:CanSleep(cache.player) end)
    end

    local function trySleep()
        pcall(function() bedComp:Sleep(cache.player) end)
        return isSleepingNow(restComp)
    end

    -- 1. Night already? Just sleep.
    if canSleep() == 0 then
        if trySleep() then
            log("SUCCESS: night — slept directly.")
            return true
        end
    end

    -- 2. Daytime.
    local timeActors = findTimeActors()
    if #timeActors == 0 then
        log("WARNING: no " .. TIME_CLASS .. " instances found.")
        return false
    end

    log(string.format("Daytime (CanSleep=%s). %d time-actor instance(s).",
        tostring(canSleep()), #timeActors))
    for i, ta in ipairs(timeActors) do
        log(string.format("  [%d] StoredTime=%s  %s", i,
            tostring(try(function() return ta.StoredTime end)),
            try(function() return ta:GetFullName() end) or "?"))
    end

    -- Safe one-time property map (the real intel for v5)
    mapEverything(timeActors)

    -- Hop loop across ALL instances
    local originals = {}
    for i, ta in ipairs(timeActors) do
        originals[i] = try(function() return ta.StoredTime end)
    end

    local hops = 0
    local slept = false
    while hops < MAX_HOPS do
        hops = hops + 1
        for _, ta in ipairs(timeActors) do
            pcall(function() ta.StoredTime = ta.StoredTime + GAME_HOUR end)
        end
        local cs = canSleep()
        if cs == 0 then
            log(string.format("Night reached after +%d game-hour(s) (all instances).", hops))
            slept = trySleep()
            break
        end
    end

    if slept then
        log("SUCCESS: clock advanced to night, Sleep accepted.")
        return true
    end

    for i, ta in ipairs(timeActors) do
        if type(originals[i]) == "number" then
            pcall(function() ta.StoredTime = originals[i] end)
        end
    end
    log(string.format("FAILED after %d hops (CanSleep=%s). All StoredTimes restored.",
        hops, tostring(canSleep())))
    return false
end

-- ── Cast handler ──────────────────────────────────────────────
local function onOculusCast()
    ExecuteInGameThread(function()
        refreshCache()
        if not valid(cache.player) then log("Player not ready"); return end
        advanceWorldDay()
    end)
end

-- ── Hooks ─────────────────────────────────────────────────────
local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if hook_registered then return end
    ExecuteInGameThread(function()
        if hook_registered then return end

        pcall(function()
            RegisterHook("/Script/Dominion.OculusComponent:ActivateOculus",
                function(self) end,
                function(self)
                    local ok, comp = pcall(function() return self:get() end)
                    if not ok or not comp then return end
                    pcall(function() comp:DeactivateOculus() end)
                end
            )
        end)

        local ok_main, err_main = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance) onOculusCast() end,
                function(self, Instance) end
            )
        end)

        if ok_main then
            hook_registered = true
            log("v4.7 ready.")
        else
            log("ERROR registering Oculus hook: " .. tostring(err_main))
        end
    end)
end)

print("[QuickGrow] v4.7 loaded.\n")
