-- ============================================================
--  QuickGrow v4.2 (diagnostic) — UE4SS Lua Mod for RS: Dragonwilds
--
--  Implements QuickGrow_Handoff.md next steps 1–5:
--    1. Probe PlayerRestComponent:SetRestingArea signatures,
--       then call BedComponent:Sleep(player)
--    2. Probe PlayerRestComponent:StartSleeping signatures
--    3. Observer hooks on SetRestingArea / StartSleeping /
--       BedComponent:Sleep — physically sleep in a bed at night
--       once to capture the real call signatures in the console
--    4. Logs player HasAuthority() (listen-server check)
--    5. Sleep observer confirms whether our direct call fires
--
--  Each strategy is verified via PlayerRestComponent IsSleeping;
--  probing stops as soon as one works. Console output is verbose
--  on purpose — copy the [QuickGrow] lines back for analysis.
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

-- Describe a value for observer logs
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

-- ── Sleep-state check (verification) ─────────────────────────
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

-- ── Probing strategies (handoff steps 1 & 2) ─────────────────
local function probeCall(label, fn)
    local ok, err = pcall(fn)
    log(string.format("  %s -> %s", label, ok and "OK (no error)" or "ERR: " .. tostring(err)))
    return ok
end

local function attemptSleep(bed, bedComp, restComp)
    -- Step 1: SetRestingArea variants, then Sleep(player)
    log("Step 1: probing SetRestingArea variants...")
    probeCall("SetRestingArea(bed)",          function() restComp:SetRestingArea(bed) end)
    probeCall("SetRestingArea(bed, bedComp)", function() restComp:SetRestingArea(bed, bedComp) end)
    probeCall("SetRestingArea(bedComp)",      function() restComp:SetRestingArea(bedComp) end)

    probeCall("BedComponent:Sleep(player)",   function() bedComp:Sleep(cache.player) end)
    if isSleepingNow(restComp) then
        log("SUCCESS via Step 1: SetRestingArea + Sleep(player)")
        return true
    end
    log("Step 1 did not start sleep (IsSleeping still false).")

    -- Step 2: StartSleeping variants
    log("Step 2: probing StartSleeping variants...")
    local variants = {
        { "StartSleeping(bed)",          function() restComp:StartSleeping(bed) end },
        { "StartSleeping(bed, bedComp)", function() restComp:StartSleeping(bed, bedComp) end },
        { "StartSleeping(bedComp)",      function() restComp:StartSleeping(bedComp) end },
        { "StartSleeping(player)",       function() restComp:StartSleeping(cache.player) end },
        { "StartSleeping()",             function() restComp:StartSleeping() end },
    }
    for _, v in ipairs(variants) do
        probeCall(v[1], v[2])
        if isSleepingNow(restComp) then
            log("SUCCESS via Step 2: " .. v[1])
            return true
        end
    end
    log("Step 2 did not start sleep (IsSleeping still false).")
    return false
end

-- ── Day-advance entry point ──────────────────────────────────
local function advanceWorldDay()
    if not valid(cache.player) then
        log("WARNING: Player not ready.")
        return false
    end

    -- Step 4: authority check
    local auth = try(function() return cache.player:HasAuthority() end)
    log("Player HasAuthority(): " .. tostring(auth))

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
    if not valid(restComp) then
        log("WARNING: PlayerRestComponent is nil.")
        return false
    end

    if isSleepingNow(restComp) then
        log("Already sleeping; skipping.")
        return true
    end

    local canSleep = try(function() return bedComp:CanSleep() end)
    log("CanSleep() before attempts: " .. tostring(canSleep) .. " (0=ok, 4=not nighttime)")

    local ok = attemptSleep(bed, bedComp, restComp)

    -- Delayed status report (sleep may apply asynchronously)
    ExecuteWithDelay(1000, function()
        ExecuteInGameThread(function()
            local sleeping = isSleepingNow(restComp)
            local area = try(function() return restComp:GetCurrentRestingAreaActor() end)
            log(string.format("Status +1s: IsSleeping=%s, RestingArea=%s",
                tostring(sleeping), describe(area)))
        end)
    end)

    return ok
end

-- ── Cast handler ──────────────────────────────────────────────
local function onOculusCast()
    ExecuteInGameThread(function()
        refreshCache()
        if not valid(cache.player) then log("Player not ready"); return end
        advanceWorldDay()
    end)
end

-- ── Observer hooks (handoff steps 3 & 5) ─────────────────────
-- Physically interact with a bed AT NIGHT once; the console will
-- show the real params the game passes. Copy those lines back.
local function registerObserver(path)
    local ok, err = pcall(function()
        RegisterHook(path, function(self, ...)
            local n = select("#", ...)
            local selfObj = try(function() return self:get() end)
            log(string.format("OBSERVE %s | self=%s | %d param(s)",
                path, describe(selfObj), n))
            for i = 1, n do
                local p = select(i, ...)
                local val = try(function() return p:get() end)
                log(string.format("  param %d: %s", i, describe(val)))
            end
        end)
    end)
    log(string.format("Observer %s: %s", path, ok and "registered" or "FAILED: " .. tostring(err)))
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

        -- Step 3 & 5: observers on the real sleep call chain
        registerObserver("/Script/Dominion.PlayerRestComponent:StartSleeping")
        registerObserver("/Script/Dominion.PlayerRestComponent:SetRestingArea")
        registerObserver("/Script/Dominion.BedComponent:Sleep")

        local ok_main, err_main = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance) onOculusCast() end,
                function(self, Instance) end
            )
        end)

        if ok_main then
            hook_registered = true
            log("v4.2 diagnostic ready.")
        else
            log("ERROR registering Oculus hook: " .. tostring(err_main))
        end
    end)
end)

print("[QuickGrow] v4.2 (diagnostic) loaded.\n")
