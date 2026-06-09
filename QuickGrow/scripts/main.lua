-- ============================================================
--  QuickGrow v4.8 — UE4SS Lua Mod for RS: Dragonwilds
--
--  v4.7 findings (the breakthrough):
--   * COMPLETE InGameTimeActor property list: RealTimeMinutesPer-
--     InGameDay, InitialTime, TimeOfDawn, TimeOfDusk, StoredTime,
--     LastSyncTime, bIsTimePaused. There is NO live-clock property
--     — current time lives in a non-reflected C++ member. That is
--     why StoredTime writes stick but change nothing.
--   * Reflection enumeration (ForEachProperty/ForEachFunction)
--     crashes natively on several classes. Banned permanently.
--
--  v4.8 fix — move the goalposts instead of the clock:
--   CanSleep's night check compares the (unreachable) current time
--   against TimeOfDawn/TimeOfDusk — plain float properties whose
--   writes are PROVEN to stick. On a daytime cast:
--     1. Set TimeOfDusk = 0.01  ("night" starts just after 00:00,
--        so any time of day counts as night)
--     2. CanSleep(player) should now be 0 -> Sleep(player)
--     3. Restore TimeOfDusk immediately (dawn untouched, so the
--        morning wake-up time stays correct)
--   Fallback if still blocked: also push TimeOfDawn to 24.0,
--   re-check, restore both.
-- ============================================================

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"
local BED_CLASS  = "BP_BaseBuilding_Bed_C"
local TIME_CLASS = "BP_InGameTimeActor_C"

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

-- ── Time actors ───────────────────────────────────────────────
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

    -- 2. Daytime: shrink the day instead of moving the clock.
    local timeActors = findTimeActors()
    if #timeActors == 0 then
        log("WARNING: no " .. TIME_CLASS .. " instances found.")
        return false
    end

    local saved = {}
    for i, ta in ipairs(timeActors) do
        saved[i] = {
            dusk = try(function() return ta.TimeOfDusk end),
            dawn = try(function() return ta.TimeOfDawn end),
        }
    end

    local function restoreAll()
        for i, ta in ipairs(timeActors) do
            if saved[i] then
                if type(saved[i].dusk) == "number" then
                    pcall(function() ta.TimeOfDusk = saved[i].dusk end)
                end
                if type(saved[i].dawn) == "number" then
                    pcall(function() ta.TimeOfDawn = saved[i].dawn end)
                end
            end
        end
    end

    log(string.format("Daytime (CanSleep=%s). Trying dusk shift...",
        tostring(canSleep())))

    -- Step A: dusk to 00:00:36 — any time >= dusk counts as night
    for _, ta in ipairs(timeActors) do
        pcall(function() ta.TimeOfDusk = 0.01 end)
    end
    local cs = canSleep()
    log("After TimeOfDusk=0.01: CanSleep=" .. tostring(cs))

    -- Step B (fallback): dawn to 24.0 — any time < dawn counts as night
    if cs ~= 0 then
        for _, ta in ipairs(timeActors) do
            pcall(function() ta.TimeOfDawn = 24.0 end)
        end
        cs = canSleep()
        log("After TimeOfDawn=24.0: CanSleep=" .. tostring(cs))
    end

    local slept = false
    if cs == 0 then
        slept = trySleep()
    end

    -- Restore window bounds immediately; dawn is what the wake-up
    -- time is computed from, and it is back to normal before the
    -- sleep fade finishes.
    restoreAll()

    if slept then
        log("SUCCESS: dusk-shift accepted, sleeping — day should advance. Bounds restored.")
        return true
    end

    log(string.format("FAILED: CanSleep=%s after both shifts (3=likely 'too early/recently slept'). Bounds restored.",
        tostring(canSleep())))
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
            log("v4.8 ready.")
        else
            log("ERROR registering Oculus hook: " .. tostring(err_main))
        end
    end)
end)

print("[QuickGrow] v4.8 loaded.\n")
