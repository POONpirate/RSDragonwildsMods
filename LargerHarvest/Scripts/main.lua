---@diagnostic disable: undefined-global

-- LargerHarvest - UE4SS Lua Mod
-- Increases the Harvest (Uproot) spell radius by 2.5x:
--   Base radius    : 750  -> 1875
--   Upgraded radius: 1250 -> 3125
--
-- USD_Harvest is RF_Standalone (always in memory).
-- SpellModule_Shape_0 holds two DominionShape_Sphere sub-objects that the
-- Dominion framework reads for the harvest area. We patch their Radius via
-- StaticFindObject on ClientRestart, exactly like LargerHumidify does.

local ModName         = "[LargerHarvest] "
local BASE_RADIUS     = 1875.0   -- was 750
local UPGRADED_RADIUS = 3125.0   -- was 1250

local SPHERE_BASE     = "/Game/Gameplay/UtilityMagic/PerkSpells/Farming/USD_Harvest.USD_Harvest:SpellModule_Shape_0.DominionShape_Sphere_0"
local SPHERE_UPGRADED = "/Game/Gameplay/UtilityMagic/PerkSpells/Farming/USD_Harvest.USD_Harvest:SpellModule_Shape_0.DominionShape_Sphere_1"

local function patchSphere(path, targetRadius)
    local sphere = StaticFindObject(path)
    if not sphere or not sphere:IsValid() then
        print(ModName .. "Sphere not found: " .. path .. "\n")
        return
    end
    local ok, prev = pcall(function() return sphere:GetPropertyValue("Radius") end)
    if not ok then
        print(ModName .. "Could not read Radius from: " .. path .. "\n")
        return
    end
    sphere:SetPropertyValue("Radius", targetRadius)
    print(ModName .. "Radius: " .. tostring(prev) .. " -> " .. targetRadius .. "\n")
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
    ExecuteInGameThread(function()
        patchSphere(SPHERE_BASE,     BASE_RADIUS)
        patchSphere(SPHERE_UPGRADED, UPGRADED_RADIUS)
    end)
end)

print(ModName .. "Loaded.\n")
