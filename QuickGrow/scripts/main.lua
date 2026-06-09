-- ============================================================
--  QuickGrow v4.3 (diagnostic) — UE4SS Lua Mod for RS: Dragonwilds
--
--  v4.2 log findings:
--   * The working physical night-sleep calls EXACTLY
--     BedComponent:Sleep(player) — same self, same param, nothing
--     before it. Our call signature is correct.
--   * Therefore Sleep() no-ops during the day because of its
--     INTERNAL time-of-day check (native CanSleep), which we
--     cannot override. The fix must come from the time system.
--   * SetRestingArea takes exactly 1 param (an Actor). Passing a
--     BedComponent CRASHED the game natively. All blind probing
--     with guessed object params is removed.
--
--  v4.3 behavior on Oculus cast:
--   1. Call bedComp:Sleep(player) — works if it's night.
--   2. If IsSleeping is still false (daytime), run a one-time
--     READ-ONLY discovery sweep to find the time-of-day system:
--       - scan all actors for time/day/night/sky/clock classes
--         and dump their time-related property values
--       - dump time-related props on GameMode/GameState
--       - probe /Script/Dominion time-class and function names
--         (RegisterHook registration only — nothing is called
--         with guessed params)
--   Send UE4SS.log back after one daytime cast.
-- ============================================================

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"
local BED_CLASS  = "BP_BaseBuilding_Bed_C"

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
    local full = try(function() return v:GetFullName() end)
    if full then return tostring(full) end
    return string.format("%s (%s)", tostring(v), type(v))
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

-- ── Time-system discovery (READ-ONLY) ────────────────────────
local discovered = false

local TIME_PATTERNS = { "time", "day", "night", "sky", "sun", "moon",
                        "clock", "weather", "season", "morning" }
-- Engine-level noise we don't care about
local NOISE = {
    CustomTimeDilation = true, CreationTime = true, LastRenderTime = true,
    TimerHandle_LifeSpanExpired = true, UnpausedTimeSeconds = true,
    AudioTimeSeconds = true, DeltaRealTimeSeconds = true,
    RealTimeSeconds = true, TimeSeconds = true, PauseDelay = true,
}

local function nameMatches(name)
    local l = string.lower(name)
    for _, p in ipairs(TIME_PATTERNS) do
        if string.find(l, p, 1, true) then return true end
    end
    return false
end

local function classNameOf(obj)
    return try(function() return obj:GetClass():GetFName():ToString() end) or "?"
end

local function dumpTimeProps(obj, label)
    local cls = try(function() return obj:GetClass() end)
    local depth = 0
    while cls ~= nil and depth < 8 do
        pcall(function()
            cls:ForEachProperty(function(prop)
                local pname = try(function() return prop:GetFName():ToString() end)
                if pname and not NOISE[pname] and nameMatches(pname) then
                    local val = try(function() return obj[pname] end)
                    local t = type(val)
                    local sval = (t == "number" or t == "boolean" or t == "string")
                        and tostring(val) or describe(val)
                    log(string.format("    %s.%s = %s", label, pname, sval))
                end
            end)
        end)
        cls = try(function() return cls:GetSuperStruct() end)
        depth = depth + 1
    end
end

local function discoverTimeSystem()
    if discovered then return end
    discovered = true
    log("=== TIME SYSTEM DISCOVERY (read-only) ===")

    -- 1. Actor sweep: any actor whose class name smells like time/sky
    local actors = FindAllOf("Actor")
    local seen = {}
    if actors then
        log(string.format("Sweeping %d actors...", #actors))
        for _, a in ipairs(actors) do
            if valid(a) then
                local cname = classNameOf(a)
                if cname ~= "?" and nameMatches(cname) and not seen[cname] then
                    seen[cname] = true
                    log("  ACTOR: " .. cname)
                    log("    " .. describe(a))
                    dumpTimeProps(a, cname)
                end
            end
        end
    else
        log("FindAllOf('Actor') returned nil")
    end

    -- 2. GameMode / GameState property scan
    for _, gname in ipairs({ "DominionGameMode", "DominionGameState",
                             "GameModeBase", "GameStateBase" }) do
        local objs = FindAllOf(gname)
        if objs then
            for _, o in ipairs(objs) do
                if valid(o) then
                    log("  FOUND " .. gname .. ": " .. describe(o))
                    dumpTimeProps(o, gname)
                    break
                end
            end
        end
    end

    -- 3. Native class existence probes
    local classes = {
        "TimeOfDayManager", "TimeOfDaySubsystem", "TimeOfDayComponent",
        "TimeManager", "TimeSubsystem", "GameTimeSubsystem",
        "DayNightManager", "DayNightCycle", "DayNightSubsystem",
        "WorldTimeSubsystem", "WorldClock", "SkyManager",
        "WeatherManager", "EnvironmentManager", "DominionTimeSubsystem",
        "SleepManager", "SleepSubsystem",
    }
    for _, c in ipairs(classes) do
        local path = "/Script/Dominion." .. c
        local cls = try(function() return StaticFindObject(path) end)
        if cls and valid(cls) then
            log("  CLASS EXISTS: " .. path)
        end
    end

    -- 4. Function existence probes on GameMode/GameState
    --    (RegisterHook with empty callbacks — never called by us)
    local fnames = {
        "SkipNight", "SkipToMorning", "SkipToDay", "AdvanceDay",
        "StartNewDay", "StartNextDay", "AdvanceToMorning",
        "SetTimeOfDay", "SetTime", "AdvanceTime", "AddTime",
        "SetDayTime", "SetNightTime",
        "GetTimeOfDay", "GetNormalizedTimeOfDay", "GetCurrentDay",
        "IsNight", "IsNightTime", "IsDayTime",
        "WakeAllPlayers", "OnAllPlayersSlept", "CheckAllPlayersSleeping",
        "OnPlayerSleepStateChanged", "TrySkipNight",
    }
    for _, cp in ipairs({ "/Script/Dominion.DominionGameMode",
                          "/Script/Dominion.DominionGameState" }) do
        for _, f in ipairs(fnames) do
            local ok, res = pcall(function()
                return RegisterHook(cp .. ":" .. f, function() end, function() end)
            end)
            if ok and res ~= nil then
                log("  FN HIT: " .. cp .. ":" .. f)
            end
        end
    end

    log("=== DISCOVERY COMPLETE — send UE4SS.log back ===")
end

-- ── Day-advance entry point ──────────────────────────────────
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

    -- CanSleep signature check (safe: wrong param COUNT only errors in Lua)
    local cs0 = try(function() return bedComp:CanSleep() end)
    local cs1 = try(function() return bedComp:CanSleep(cache.player) end)
    log(string.format("CanSleep()=%s  CanSleep(player)=%s  (0=ok, 4=not night)",
        tostring(cs0), tostring(cs1)))

    -- Known-good call; works when the time check passes (night)
    pcall(function() bedComp:Sleep(cache.player) end)

    if isSleepingNow(restComp) then
        log("SUCCESS: Sleep(player) accepted — day should advance.")
        return true
    end

    log("Sleep(player) blocked (daytime). Running time-system discovery...")
    discoverTimeSystem()
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

-- ── Observer (confirms game-side Sleep calls; read-only) ─────
local function registerObserver(path)
    pcall(function()
        RegisterHook(path, function(self, ...)
            local n = select("#", ...)
            local selfObj = try(function() return self:get() end)
            log(string.format("OBSERVE %s | self=%s | %d param(s)",
                path, describe(selfObj), n))
            for i = 1, n do
                local p = select(i, ...)
                log(string.format("  param %d: %s",
                    i, describe(try(function() return p:get() end))))
            end
        end)
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

        registerObserver("/Script/Dominion.BedComponent:Sleep")

        local ok_main, err_main = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance) onOculusCast() end,
                function(self, Instance) end
            )
        end)

        if ok_main then
            hook_registered = true
            log("v4.3 diagnostic ready.")
        else
            log("ERROR registering Oculus hook: " .. tostring(err_main))
        end
    end)
end)

print("[QuickGrow] v4.3 (diagnostic) loaded.\n")
