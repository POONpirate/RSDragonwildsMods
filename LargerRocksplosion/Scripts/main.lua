---@diagnostic disable: undefined-global

-- LargerRocksplosion - UE4SS Lua Mod
-- Triples the Rocksplosion spell damage radius:
--   DominionShape_Sphere_0.Radius: 300 -> 900
--
-- Two-pronged approach:
--   1. Patch the BP_Magic_Rocksplosion_C archetype on ClientRestart so that
--      any future instances inherit the correct radius from the start.
--   2. Also patch each spawned instance directly via NotifyOnNewObject, because
--      the instance is already created from the old archetype by the time the
--      archetype patch runs (ExecuteInGameThread is deferred one tick).
--
-- The NotifyOnNewObject callback never touches `comp` directly — it only
-- passes it to ExecuteInGameThread, avoiding the GetOuter/GetClass crash
-- paths that caused ACCESS_VIOLATION crashes in earlier versions.

local ModName       = "[LargerRocksplosion] "
local TARGET_RADIUS = 900.0   -- was 300

local COMP_PATH = "/Game/Gameplay/UtilityMagic/PerkSpells/Rocksplosion/BP_Magic_Rocksplosion.BP_Magic_Rocksplosion_C:DelayedDamageInfliction_GEN_VARIABLE"

-- ── Archetype patch (affects all future instances) ────────────────────────
local archetypePatched = false

local function tryPatchArchetype()
    if archetypePatched then return end
    local comp = StaticFindObject(COMP_PATH)
    if not comp or not comp:IsValid() then return end  -- BP not loaded yet

    local ok, sphere = pcall(function() return comp:GetPropertyValue("OverlapShape") end)
    if not ok or not sphere or not sphere:IsValid() then
        print(ModName .. "Could not read OverlapShape from archetype.\n")
        return
    end

    local prev = sphere:GetPropertyValue("Radius")
    sphere:SetPropertyValue("Radius", TARGET_RADIUS)
    archetypePatched = true
    print(ModName .. "Archetype radius: " .. tostring(prev) .. " -> " .. TARGET_RADIUS .. "\n")
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
    ExecuteInGameThread(function()
        archetypePatched = false  -- reset so teleport/respawn re-applies
        tryPatchArchetype()
    end)
end)

-- ── Instance patch (fixes the current cast's sphere directly) ─────────────
-- Called for every newly spawned DelayedDamageInflictionComponent.
-- We do NOT touch `comp` here — only inside ExecuteInGameThread on the game
-- thread. This avoids C++ crashes from calling methods on mid-construction
-- objects in the notification callback.
NotifyOnNewObject("/Script/Dominion.DelayedDamageInflictionComponent", function(comp)
    ExecuteInGameThread(function()
        -- Also use this as a trigger to patch the archetype if not done yet
        tryPatchArchetype()

        -- Patch this specific instance
        local ok, sphere = pcall(function()
            if not comp:IsValid() then return nil end
            return comp:GetPropertyValue("OverlapShape")
        end)
        if not ok or not sphere or not sphere:IsValid() then return end

        sphere:SetPropertyValue("Radius", TARGET_RADIUS)
    end)
end)

print(ModName .. "Loaded.\n")
