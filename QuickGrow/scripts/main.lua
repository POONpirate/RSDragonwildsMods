-- ============================================================
--  QuickGrow v4.1 — UE4SS Lua Mod for RuneScape: Dragonwilds
--
--  When the Eye of Oculus is cast:
--    1. Suppress the build menu (DeactivateOculus)
--    2. Find the player's claimed bed (BP_BaseBuilding_Bed_C)
--    3. Call BedComponent:Sleep(player) directly — bypasses the
--       CanSleep time-of-day check, advancing the day at any time.
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

-- ── Day-advance via BedComponent:Sleep ───────────────────────
local function advanceWorldDay()
    if not valid(cache.player) then
        print("[QuickGrow] WARNING: Player not ready.\n")
        return false
    end

    local bed = findPlayerBed()
    if not bed then
        print("[QuickGrow] WARNING: No bed found. Build and claim a bed first.\n")
        return false
    end

    local bedComp = try(function() return bed.Bed end)
    if not valid(bedComp) then
        print("[QuickGrow] WARNING: BedComponent is nil.\n")
        return false
    end

    local ok, err = pcall(function()
        bedComp:Sleep(cache.player)
    end)

    if not ok then
        print(string.format("[QuickGrow] ERROR: %s\n", tostring(err)))
        return false
    end

    return true
end

-- ── Cast handler ──────────────────────────────────────────────
local function onOculusCast()
    ExecuteInGameThread(function()
        refreshCache()
        if not valid(cache.player) then dbg("Player not ready"); return end
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
                    dbg("Build menu suppressed.")
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
            dbg("Ready.")
        else
            print(string.format("[QuickGrow] ERROR registering Oculus hook: %s\n", tostring(err_main)))
        end
    end)
end)

print("[QuickGrow] v4.1 loaded.\n")
