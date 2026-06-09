-- ============================================================
--  QuickGrow v4.6 — UE4SS Lua Mod for RS: Dragonwilds
--
--  v4.5 findings:
--   * NIGHT cast WORKS: Sleep(player) -> sleep + day advance.
--   * DAY cast: 30x StoredTime bumps never changed CanSleep
--     (3 or 4). Either the write doesn't stick or CanSleep reads
--     time elsewhere. Also: 0/45 name hits on native
--     /Script/Dominion.InGameTimeActor.
--   * CanSleep codes seen: 0=ok, 3=? (maybe too-early), 4=not night.
--
--  v4.6:
--   * Registers throttled OBSERVERS at startup across the time
--     actor (BP + native), DominionGameMode and DominionGameState
--     (~60 candidate names each, RegisterHook probe — safe).
--     A working NIGHT cast will reveal the real day-advance call.
--   * Day cast: verifies whether the StoredTime write actually
--     sticks (read-back logging), then runs the hop loop.
--
--  TEST: cast once at night (works; captures the call chain),
--  once during day, then send UE4SS.log back.
-- ============================================================

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"
local BED_CLASS  = "BP_BaseBuilding_Bed_C"
local TIME_CLASS = "BP_InGameTimeActor_C"

local GAME_HOUR = 3600
local MAX_HOPS  = 30
local OBS_LIMIT = 5     -- max logged calls per observed function

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

-- ── Probe + observe (safe RegisterHook technique) ────────────
local obsCounts = {}

local function registerProbeObserver(path)
    local ok, res = pcall(function()
        return RegisterHook(path,
            function(self, ...)
                local c = (obsCounts[path] or 0) + 1
                obsCounts[path] = c
                if c > OBS_LIMIT then return end
                local n = select("#", ...)
                local parts = {}
                for i = 1, n do
                    local p = select(i, ...)
                    parts[#parts + 1] = describe(try(function() return p:get() end))
                end
                log(string.format("OBSERVE %s (%s)", path,
                    n > 0 and table.concat(parts, ", ") or ""))
            end,
            function() end)
    end)
    return ok and res ~= nil
end

local CANDIDATE_NAMES = {
    -- sleep flow (GameMode/GameState side)
    "OnAllPlayersSleeping", "AllPlayersSleeping", "HandleAllPlayersSleeping",
    "OnPlayerSleepStateChanged", "PlayerSleepStateChanged",
    "NotifyPlayerSleeping", "RegisterSleepingPlayer", "UnregisterSleepingPlayer",
    "GetNumSleepingPlayers", "AreAllPlayersSleeping", "CheckAllPlayersSleeping",
    "WakeAllPlayers", "WakeUpAllPlayers",
    -- day advance
    "SkipNight", "SkipToMorning", "AdvanceToMorning", "AdvanceDay",
    "StartNewDay", "StartNextDay", "BeginNewDay",
    "OnDayStarted", "OnNightStarted", "OnMorning", "OnNewDay", "OnDayChanged",
    -- time set/advance
    "SetTimeOfDay", "SetTime", "SetInGameTime", "SetCurrentTime",
    "SetTimeOfDayNormalized", "SetNormalizedTimeOfDay",
    "AddTime", "AddHours", "AdvanceTime", "SkipTime", "SkipToTime",
    "SetStoredTime", "SyncTime", "UpdateStoredTime", "UpdateTime",
    "OnRep_StoredTime",
    -- time get/query
    "GetTimeOfDay", "GetCurrentTimeOfDay", "GetInGameTime", "GetCurrentTime",
    "GetNormalizedTimeOfDay", "GetTimeOfDayHours",
    "GetCurrentDay", "GetDayNumber", "GetDayCount",
    "IsNight", "IsNightTime", "IsDayTime",
    "GetTimeOfDawn", "GetTimeOfDusk",
    -- pause / events
    "SetTimePaused", "SetIsTimePaused", "PauseTime", "ResumeTime",
    "OnTimeOfDayChanged", "OnTimeChanged", "TimeOfDayUpdated",
    -- RPC variants
    "ServerSetTimeOfDay", "ServerSkipNight", "ServerSetTime",
    "MulticastSetTime", "MulticastSetTimeOfDay",
}

local CANDIDATE_CLASSES = {
    "/Script/Dominion.InGameTimeActor",
    "/Game/Gameplay/World/Time/BP_InGameTimeActor.BP_InGameTimeActor_C",
    "/Script/Dominion.DominionGameMode",
    "/Script/Dominion.DominionGameState",
}

local probed = false
local function probeAndObserveAll()
    if probed then return end
    probed = true
    local total = 0
    for _, cp in ipairs(CANDIDATE_CLASSES) do
        local hits = {}
        for _, fname in ipairs(CANDIDATE_NAMES) do
            if registerProbeObserver(cp .. ":" .. fname) then
                hits[#hits + 1] = fname
                total = total + 1
            end
        end
        if #hits > 0 then
            log("PROBE HITS on " .. cp .. ": " .. table.concat(hits, ", "))
        end
    end
    log(string.format("Probe/observe registered: %d function(s) total.", total))
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

    -- 2. Daytime: try advancing the in-game clock.
    local timeActor = findTimeActor()
    if not valid(timeActor) then
        log("WARNING: " .. TIME_CLASS .. " not found.")
        return false
    end

    local original = try(function() return timeActor.StoredTime end)
    if type(original) ~= "number" then
        log("WARNING: StoredTime not readable (got " .. tostring(original) .. ").")
        return false
    end

    log(string.format("Daytime (CanSleep=%s). StoredTime=%.0f — advancing clock...",
        tostring(canSleep()), original))

    -- Write verification: does the property write actually stick?
    pcall(function() timeActor.StoredTime = original + GAME_HOUR end)
    local readBack = try(function() return timeActor.StoredTime end)
    log(string.format("Write check: wrote %.0f, read back %s — %s",
        original + GAME_HOUR, tostring(readBack),
        (readBack == original + GAME_HOUR) and "WRITE STICKS" or "WRITE IGNORED"))

    local hops = 1
    local slept = false
    while hops < MAX_HOPS do
        hops = hops + 1
        pcall(function()
            timeActor.StoredTime = timeActor.StoredTime + GAME_HOUR
        end)
        local cs = canSleep()
        if cs == 0 then
            log(string.format("Night reached after +%d game-hour(s).", hops))
            slept = trySleep()
            break
        end
        if hops % 10 == 0 then
            log(string.format("  hop %d: StoredTime=%s CanSleep=%s",
                hops, tostring(try(function() return timeActor.StoredTime end)),
                tostring(cs)))
        end
    end

    if slept then
        log("SUCCESS: clock advanced to night, Sleep accepted.")
        return true
    end

    pcall(function() timeActor.StoredTime = original end)
    log(string.format("FAILED after %d hops (CanSleep=%s). StoredTime restored.",
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

        probeAndObserveAll()

        local ok_main, err_main = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance) onOculusCast() end,
                function(self, Instance) end
            )
        end)

        if ok_main then
            hook_registered = true
            log("v4.6 ready.")
        else
            log("ERROR registering Oculus hook: " .. tostring(err_main))
        end
    end)
end)

print("[QuickGrow] v4.6 loaded.\n")
