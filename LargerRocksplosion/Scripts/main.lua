---@diagnostic disable: undefined-global

local ModName = "[LargerRocksplosion] "
local TARGET_RADIUS = 900

NotifyOnNewObject("/Script/Dominion.DelayedDamageInflictionComponent", function(comp)
    if not comp:IsValid() then return end
	
    local ok, ownerClass = pcall(function() return comp:GetOuter():GetClass():GetFullName() end)
    --if not ok or ownerClass ~= "BP_Magic_Rocksplosion_C" then 
	if not ok or not ownerClass:find("BP_Magic_Rocksplosion") then print(ModName .. "hit ownerClass not BP_Magic_Rocksplosion_C and returned \n" .. ownerClass .. "\n") return end
	
    print(ModName .. "New DelayedDamageInflictionComponent object created under BP_Magic_Rocksplosion\n")
    ExecuteInGameThread(function()
        local ok, sphere = pcall(function() return comp:GetPropertyValue("OverlapShape") end)
        if ok and sphere and sphere:IsValid() then
            sphere:SetPropertyValue("Radius", TARGET_RADIUS)
            print(ModName .. "Radius set to " .. TARGET_RADIUS .. "\n")
        else
            print(ModName .. "Could not get OverlapShape: " .. tostring(sphere) .. "\n")
        end
    end)
end)

print(ModName .. "Loaded. One hook registered — cast Rocksplosion and check log.\n")
