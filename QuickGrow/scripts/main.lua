-- ============================================================
--  QuickGrow v4.9 — UE4SS Lua Mod for RS: Dragonwilds
--
--  v4.8 findings:
--   * TimeOfDawn=24.0 flips CanSleep 4 -> 0 (dusk shift does
--     nothing). Sleep(player) was then ACCEPTED — player got in
--     bed — but:
--     - IsSleeping sets asynchronously (instant check said false)
--     - we restored dawn immediately, so the game's deferred
--       "all sleeping -> advance day" night re-check failed and
--       time never advanced.
--   * CanSleep=3 is a non-time blocker (both shifts left it 3);
--     likely "slept too recently".
--
--  v4.9 result: dawn=24 ALONE does not flip CanSleep (stayed 4).
--  In v4.8 the flip happened with dusk=0.01 AND dawn=24 applied
--  cumulatively — the night check needs BOTH bounds shifted.
--
--  v5.0: shift BOTH bounds until the sleep completes.
--   1. Set dusk=0.01 AND dawn=24 -> CanSleep==0 -> Sleep(player)
--   2. Poll for IsSleeping==true (up to 5s)
--   3. Poll for IsSleeping==false = woke up / day advanced
--      (up to 60s)
--   4. THEN restore dawn/dusk. StoredTime logged at each phase
--      so we can verify the day jump and the wake-up hour.
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

local function storedTime(timeActors)
    return try(function() return timeActors[1].StoredTime end)
end

-- ── Async poll helper ─────────────────────────────────────────
local function poll(checkFn, intervalMs, timeoutMs, onDone)
    local elapsed = 0
    local function step()
        ExecuteWithDelay(intervalMs, function()
            ExecuteInGameThread(function()
                elapsed = elapsed + intervalMs
                if checkFn() then
                    onDone(true)
                elseif elapsed >= timeoutMs then
                    onDone(false)
                else
                    step()
                end
            end)
        end)
    end
    step()
end

-- ── Guard against overlapping casts ──────────────────────────
local busy = false

-- ── Day-advance core ─────────────────────────────────────────
local function advanceWorldDay()
    if busy then
        log("Previous cast still in progress; ignoring.")
        return
    end

    if not valid(cache.player) then
        log("WARNING: Player not ready.")
        return
    end

    local bed = findPlayerBed()
    if not bed then
        log("WARNING: No bed found. Build and claim a bed first.")
        return
    end

    local bedComp = try(function() return bed.Bed end)
    if not valid(bedComp) then
        log("WARNING: BedComponent is nil.")
        return
    end

    local restComp = getRestComp()

    if isSleepingNow(restComp) then
        log("Already sleeping; skipping.")
        return
    end

    local function canSleep()
        return try(function() return bedComp:CanSleep(cache.player) end)
    end

    -- 1. Night already? Just sleep (no bound changes needed).
    if canSleep() == 0 then
        pcall(function() bedComp:Sleep(cache.player) end)
        log("Night: Sleep(player) called.")
        return
    end

    -- 2. Daytime (or blocked).
    local timeActors = findTimeActors()
    if #timeActors == 0 then
        log("WARNING: no " .. TIME_CLASS .. " instances found.")
        return
    end

    local saved = {}
    for i, ta in ipairs(timeActors) do
        saved[i] = {
            dusk = try(function() return ta.TimeOfDusk end),
            dawn = try(function() return ta.TimeOfDawn end),
        }
    end

    local function restoreAll(reason)
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
        busy = false
        log("Bounds restored (" .. reason .. ").")
    end

    local cs0 = canSleep()
    log(string.format("Cast: CanSleep=%s, StoredTime=%s. Shifting dusk+dawn...",
        tostring(cs0), tostring(storedTime(timeActors))))

    busy = true
    for _, ta in ipairs(timeActors) do
        pcall(function() ta.TimeOfDusk = 0.01 end)
        pcall(function() ta.TimeOfDawn = 24.0 end)
    end

    local cs = canSleep()
    if cs ~= 0 then
        log(string.format(
            "Blocked: CanSleep=%s even with both bounds shifted. %s",
            tostring(cs),
            cs == 3 and "(code 3 = non-time blocker, likely 'slept too recently' — wait a bit and recast)" or ""))
        restoreAll("blocked")
        return
    end

    pcall(function() bedComp:Sleep(cache.player) end)
    log("Sleep(player) called. Waiting for sleep state (dawn stays shifted)...")

    -- Phase 1: wait for sleep to engage
    poll(function() return isSleepingNow(restComp) end, 250, 5000, function(engaged)
        if not engaged then
            restoreAll("sleep never engaged")
            return
        end
        log(string.format("Sleeping confirmed (StoredTime=%s). Waiting for day advance / wake...",
            tostring(storedTime(timeActors))))

        -- Phase 2: wait for wake (= day advanced)
        poll(function() return not isSleepingNow(restComp) end, 500, 60000, function(woke)
            log(string.format("%s StoredTime=%s.",
                woke and "Woke up — day should have advanced." or "Timeout (60s) — still sleeping?",
                tostring(storedTime(timeActors))))
            restoreAll(woke and "woke" or "timeout")
        end)
    end)
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
            log("v5.0 ready.")
        else
            log("ERROR registering Oculus hook: " .. tostring(err_main))
        end
    end)
end)

print("[QuickGrow] v5.0 loaded.\n")
