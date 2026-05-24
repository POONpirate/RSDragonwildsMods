-- ============================================================
--  QuickGrow v3 — UE4SS Lua Mod for RuneScape: Dragonwilds
--
--  When the Eye of Oculus is cast:
--    1. Suppresses the build menu (DeactivateOculus)
--    2. Finds the player's claimed bed (BP_BaseBuilding_Bed_C)
--    3. Calls ToggleRestingOrSleeping(player, controller) on it —
--       the same function the normal bed-interaction path calls.
--       This runs the full BedComponent sleep flow, triggering
--       OnAllPlayersSleeping on the GameMode → day advance → OnFullyRested.
-- ============================================================

local DEBUG = false

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"
local BED_CLASS  = "BP_BaseBuilding_Bed_C"

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

-- ── Cache ─────────────────────────────────────────────────────
local cache = {
    ctrl   = nil,
    player = nil,
}

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
-- Returns the bed claimed by the local player, or any valid bed as fallback.
local function findPlayerBed()
    local beds = FindAllOf(BED_CLASS)
    if not beds then return nil end

    local anyBed = nil
    for _, bed in ipairs(beds) do
        if valid(bed) then
            anyBed = anyBed or bed
            -- Prefer the bed claimed by this player
            local claimed = try(function()
                local bedComp = bed.Bed
                if valid(bedComp) then
                    return bedComp:IsClaimedByPlayer(cache.player)
                end
                return false
            end)
            if claimed then
                dbg("Found claimed bed.")
                return bed
            end
        end
    end

    if anyBed then
        dbg("No claimed bed found — using first available bed.")
    end
    return anyBed
end

-- ── Day-advance via bed ───────────────────────────────────────
local function advanceWorldDay()
    if not valid(cache.player) or not valid(cache.ctrl) then
        print("[QuickGrow] WARNING: Player or controller not ready.\n")
        return false
    end

    local bed = findPlayerBed()
    if not bed then
        print("[QuickGrow] WARNING: No bed found in world. Build and claim a bed first.\n")
        return false
    end

    -- Call ToggleRestingOrSleeping — same entry point as physical bed interaction.
    -- Parameters: Player Character (DominionPlayerCharacter), Player Controller (DominionPlayerController)
    -- Out param:  StartedRestingOrSleeping (bool) — true if sleep/rest began
    -- ToggleRestingOrSleeping has 3 UFunction params:
    --   Player Character, Player Controller, StartedRestingOrSleeping (OutParm bool)
    -- UE4SS requires out params to be passed as a Lua table, which gets filled on return.
    local outParams = {}
    local ok, err = pcall(function()
        bed:ToggleRestingOrSleeping(cache.player, cache.ctrl, outParams)
    end)

    if ok then
        local started = outParams.StartedRestingOrSleeping
        print(string.format("[QuickGrow] ToggleRestingOrSleeping called. StartedRestingOrSleeping=%s\n",
            tostring(started)))
        return true
    else
        print(string.format("[QuickGrow] ERROR calling ToggleRestingOrSleeping: %s\n",
            tostring(err)))
        return false
    end
end

-- ── Cast handler ──────────────────────────────────────────────
local function onOculusCast()
    ExecuteInGameThread(function()
        refreshCache()

        if not valid(cache.player) then
            dbg("Player not ready — skipping cast")
            return
        end

        local ok = advanceWorldDay()
        if ok then
            print("[QuickGrow] Day advance triggered via Eye of Oculus.\n")
        end
    end)
end

-- ── Hooks ─────────────────────────────────────────────────────
local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if hook_registered then return end

    ExecuteInGameThread(function()
        if hook_registered then return end

        -- Suppress the Oculus build menu.
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
        if not ok_deact then
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
            print("[QuickGrow] Ready. Cast Eye of Oculus to skip to morning.\n")
        end
    end)
end)

print("[QuickGrow] v3.0 loaded. Make sure you have a bed built and claimed.\n")
