---@diagnostic disable: undefined-global

-- LargerHumidify - UE4SS Lua Mod
-- Increases the Humidify spell collision radius:
--   DominionShape_Capsule_0.Radius: 150 -> 4000
--
-- USD_Humidify is an RF_Standalone data asset (always in memory).
-- Humidify is a Dominion-native projectile spell — the Dominion framework reads
-- DominionShape_Capsule_0.Radius directly, so modifying it here affects gameplay.
-- We apply the change once at ClientRestart (before any casts).

local ModName       = "[LargerHumidify] "
local TARGET_RADIUS = 4000.0

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
    ExecuteInGameThread(function()
        -- SpellModule_Shape_1 is a subobject of USD_Humidify (RF_Standalone).
        local shape1 = StaticFindObject(
            "/Game/Gameplay/UtilityMagic/PerkSpells/Farming/Humidify/USD_Humidify.USD_Humidify:SpellModule_Shape_1"
        )
        if not shape1 or not shape1:IsValid() then
            print(ModName .. "SpellModule_Shape_1 not found\n")
            return
        end

        local ok, capsule = pcall(function() return shape1:GetPropertyValue("Shape") end)
        if not ok or not capsule or not capsule:IsValid() then
            print(ModName .. "DominionShape_Capsule_0 not accessible\n")
            return
        end

        local currentRadius = capsule:GetPropertyValue("Radius")
        capsule:SetPropertyValue("Radius", TARGET_RADIUS)
        print(ModName .. "Radius: " .. tostring(currentRadius) .. " -> " .. TARGET_RADIUS .. "\n")
    end)
end)

print(ModName .. "Loaded.\n")
