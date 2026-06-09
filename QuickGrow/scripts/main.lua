-- ============================================================
--  QuickGrow v4.5 — UE4SS Lua Mod for RS: Dragonwilds
--
--  v4.4 crash finding:
--   * ForEachFunction on /Script/Engine.Actor crashed natively
--     mid-enumeration. NO reflection enumeration of any kind is
--     safe in this game. Removed entirely.
--   * Class chain confirmed: BP_InGameTimeActor_C
--       -> /Script/Dominion.InGameTimeActor -> Actor
--   * The StoredTime clock-advance strategy never got to run.
--
--  v4.5 on Oculus cast:
--   1. Night? Sleep(player) directly.
--   2. Day? Bump InGameTimeActor.StoredTime +1 game-hour at a
--      time (max 30) until CanSleep(player)==0, then Sleep.
--      Restore StoredTime on failure.
--   3. On failure only: RegisterHook name-probe (the proven
--      PropertyDumper technique — registration only, no calls,
--      no enumeration) on /Script/Dominion.InGameTimeActor.
-- ============================================================

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"
local BED_CLASS  = "BP_BaseBuilding_Bed_C"
local TIME_CLASS = "BP_InGameTimeActor_C"

local GAME_HOUR = 3600  -- StoredTime is in game-seconds
local MAX_HOPS  = 30    -- max 1-hour bumps before giving up

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

-- ── Time actor ────────────────────────────────────────────────
local function findTimeActor()
    local actors = FindAllOf(TIME_CLASS)
    if actors then
        for _, a in ipairs(actors) do
            if valid(a) then return a end
        end
    end
    return nil
end

-- ── Fallback: safe RegisterHook name probe (no enumeration) ──
local probed = false
local function probeTimeActorFunctions()
    if probed then return end
    probed = true
    log("Probing /Script/Dominion.InGameTimeActor functions (safe, registration only):")
    local names = {
        "GetInGameTime", "SetInGameTime", "GetTime", "SetTime",
        "GetTimeOfDay", "SetTimeOfDay", "GetCurrentTimeOfDay",
        "GetNormalizedTimeOfDay", "SetNormalizedTimeOfDay",
        "AddTime", "AdvanceTime", "SkipTime", "SkipToTime",
        "SkipNight", "SkipToMorning", "SkipToDay", "SkipToDawn",
        "AdvanceToMorning", "StartNewDay", "StartNextDay",
        "SetStoredTime", "GetStoredTime", "SyncTime", "ForceTimeSync",
        "GetCurrentDay", "GetDayNumber", "GetDayCount",
        "IsNight", "IsNightTime", "IsDayTime", "IsDay",
        "PauseTime", "UnpauseTime", "SetTimePaused", "SetIsTimePaused",
        "OnTimeChanged", "OnDayChanged", "OnNewDay", "OnTimeOfDayChanged",
        "ServerSetTime", "ServerSetTimeOfDay", "MulticastSetTime",
        "OnRep_StoredTime", "GetTimeOfDawn", "GetTimeOfDusk",
    }
    local hits = 0
    for _, fname in ipairs(names) do
        local path = "/Script/Dominion.InGameTimeActor:" .. fname
        local ok, res = pcall(function()
            return RegisterHook(path, function() end, function() end)
        end)
        if ok and res ~= nil then
            log("  FN HIT: " .. fname)
            hits = hits + 1
        end
    end
    log(string.format("Probe done: %d hit(s). Send UE4SS.log back.", hits))
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

    -- 2. Daytime: advance the in-game clock until night.
    local timeActor = findTimeActor()
    if not valid(timeActor) then
        log("WARNING: " .. TIME_CLASS .. " not found.")
        return false
    end

    local original = try(function() return timeActor.StoredTime end)
    if type(original) ~= "number" then
        log("WARNING: StoredTime not readable (got " .. tostring(original) .. ").")
        probeTimeActorFunctions()
        return false
    end

    log(string.format("Daytime (CanSleep=%s). StoredTime=%.0f — advancing clock...",
        tostring(canSleep()), original))

    local hops = 0
    local slept = false
    while hops < MAX_HOPS do
        hops = hops + 1
        local okSet = pcall(function()
            timeActor.StoredTime = timeActor.StoredTime + GAME_HOUR
        end)
        if not okSet then
            log("WARNING: writing StoredTime failed.")
            break
        end
        local cs = canSleep()
        if cs == 0 then
            log(string.format("Night reached after +%d game-hour(s) (StoredTime=%.0f).",
                hops, try(function() return timeActor.StoredTime end) or -1))
            slept = trySleep()
            break
        end
    end

    if slept then
        log("SUCCESS: clock advanced to night, Sleep(player) accepted — day should advance.")
        return true
    end

    -- Failure: restore the clock so we don't leave time corrupted.
    pcall(function() timeActor.StoredTime = original end)
    log(string.format(
        "FAILED after %d hops (CanSleep=%s). StoredTime restored to %.0f.",
        hops, tostring(canSleep()), original))
    probeTimeActorFunctions()
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
            log("v4.5 ready.")
        else
            log("ERROR registering Oculus hook: " .. tostring(err_main))
        end
    end)
end)

print("[QuickGrow] v4.5 loaded.\n")
