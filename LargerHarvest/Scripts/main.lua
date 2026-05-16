---@diagnostic disable: undefined-global

-- LargerHarvest - UE4SS Lua Mod
-- Increases the Harvest spell cast radius by 2.5x:
--   Base radius    : 750  -> 1875
--   Upgraded radius: 1250 -> 3125
--
-- The Harvest actor (BP_Magic_LiftAndSummonItems_C) is spawned fresh on each cast.
-- Its NiagaraComponent SCS fires before BeginPlay, giving us a window to scale
-- DefaultRadius and UpgradedRadius before GetNearbyHarvestablePlots reads them.
-- SetupSpellColliderSize (also in BeginPlay) then applies those scaled values to
-- the SpellCollider CapsuleComponent automatically.

local ModName         = "[LargerHarvest] "
local BASE_RADIUS     = 1875   -- was 750
local UPGRADED_RADIUS = 3125   -- was 1250

NotifyOnNewObject("/Script/Niagara.NiagaraComponent", function(comp)
    if not comp:IsValid() then return end

    local ok, ownerClass = pcall(function() return comp:GetOuter():GetClass():GetFullName() end)
    if not ok or not ownerClass:find("BP_Magic_LiftAndSummonItems") then return end

    local actor = comp:GetOuter()
    if not actor or not actor:IsValid() then return end

    -- Synchronous write: fires during SCS construction, before BeginPlay.
    -- Both GetNearbyHarvestablePlots and SetupSpellColliderSize will read these.
    pcall(function() actor:SetPropertyValue("DefaultRadius",  BASE_RADIUS) end)
    pcall(function() actor:SetPropertyValue("UpgradedRadius", UPGRADED_RADIUS) end)

    print(ModName .. "Radius scaled on new Harvest actor.\n")
end)

print(ModName .. "Loaded.\n")
