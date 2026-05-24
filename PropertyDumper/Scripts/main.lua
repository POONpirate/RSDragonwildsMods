-- =============================================================================
-- PropertyDumper — main.lua
-- Phase 5: RPC existence probing + FModel-guided bed hunt.
--
-- Uses RegisterHook as an existence test: if it doesn't throw, the UFunction
-- path exists in the game. We probe:
--   A) PlayerRestComponent for any sleep server RPCs
--   B) DominionGameMode for any day/sleep/advance functions
--   C) Common bed/interactable class paths for their server RPCs
--   D) GameplayAbilities / Effects related to sleep or day-advance
-- Also hooks BP_ClientDoWakeTransition (alternative to SleepTransition).
-- =============================================================================

local function log(msg)
    print("[PropertyDumper] " .. msg .. "\n")
end

local function try(fn)
    local ok, v = pcall(fn)
    return ok and v or nil
end

local function valid(obj)
    return obj ~= nil and try(function() return obj:IsValid() end) == true
end

-- ── Existence probe via RegisterHook ──────────────────────────────────────
-- RegisterHook succeeds (returns two IDs) if the UFunction path exists.
-- We hook with no-op callbacks and immediately unregister — just testing existence.
local existsCount = 0
local function probeExists(path)
    local ok, id1, id2 = pcall(function()
        return RegisterHook(path, function() end, function() end)
    end)
    if ok and id1 then
        log("  EXISTS: " .. path)
        existsCount = existsCount + 1
        -- Unregister so we don't accumulate stale hooks
        pcall(function() UnregisterHook(path, id1, id2) end)
        return true
    end
    return false
end

log("============================================================")
log("Phase 5 — probing UFunction existence via RegisterHook...")
log("")

-- ── A) PlayerRestComponent sleep RPCs ─────────────────────────────────────
log("--- PlayerRestComponent candidates ---")
local restBase = "/Script/Dominion.PlayerRestComponent:"
local restCandidates = {
    "Server_RequestSleep",
    "Server_StartSleeping",
    "Server_SetSleeping",
    "Server_BeginResting",
    "Server_SetRestingArea",
    "Server_TryStartSleeping",
    "Server_ConfirmSleep",
    "Server_NotifyPlayerSleeping",
    "Server_AddSleepingPlayer",
    "ServerStartSleeping",
    "ServerSetSleeping",
    "ServerBeginResting",
    "ServerSetRestingArea",
    "Server_RequestWakeUp",   -- we know this one exists (sanity check)
    "StartSleeping",          -- known
    "StopSleeping",
    "AdvanceWorldDay",
    "Server_AdvanceWorldDay",
}
for _, fn in ipairs(restCandidates) do
    probeExists(restBase .. fn)
end

-- Also probe the BP subclass path
log("--- BP_Components_Rest_C candidates ---")
local bpRestBase = "/Game/Gameplay/Character/Components/BP_Components_Rest.BP_Components_Rest_C:"
local bpRestCandidates = {
    "Server_RequestSleep",
    "Server_StartSleeping",
    "Server_SetSleeping",
    "Server_SetRestingArea",
    "Server_AdvanceDay",
    "Server_RequestWakeUp",   -- known
}
for _, fn in ipairs(bpRestCandidates) do
    probeExists(bpRestBase .. fn)
end

-- ── B) DominionGameMode day/sleep functions ────────────────────────────────
log("--- DominionGameMode candidates ---")
local gmBase = "/Script/Dominion.DominionGameMode:"
local gmCandidates = {
    "AdvanceDay",
    "AdvanceWorldDay",
    "OnAllPlayersSleeping",
    "SetAllPlayersSleeping",
    "TriggerDayAdvance",
    "Server_AdvanceDay",
    "StartNewDay",
    "BeginNewDay",
    "SkipToMorning",
    "SetDayCount",
    "IncrementDay",
    "HandleAllPlayersSleeping",
}
for _, fn in ipairs(gmCandidates) do
    probeExists(gmBase .. fn)
end

-- ── C) Bed actor Server RPC probes — confirmed class path ─────────────────
log("--- BP_BaseBuilding_Bed_C candidates ---")
local BED_BASE = "/Game/Gameplay/BaseBuilding/Actors/Props/Cosiness/BP_BaseBuilding_Bed.BP_BaseBuilding_Bed_C:"
local bedFns = {
    "Server_RequestSleep",
    "Server_StartSleeping",
    "Server_SetPlayerSleeping",
    "Server_InteractSleep",
    "Server_BeginResting",
    "Server_AddSleepingPlayer",
    "Server_SetRestingArea",
    "Server_ActivateBed",
    "Server_Interact",
    "Server_RegisterSleepingPlayer",
    "Server_NotifySleeping",
    "Server_Sleep",
    "Server_UseBed",
    "Server_TrySleep",
    "Server_RequestRest",
    "Interact",
    "OnInteract",
    "ActivateBed",
    "StartResting",
}
for _, fn in ipairs(bedFns) do
    probeExists(BED_BASE .. fn)
end

-- Also try FindFirstOf now that we know the class name
log("--- FindFirstOf BP_BaseBuilding_Bed_C ---")
pcall(function()
    local bed = FindFirstOf("BP_BaseBuilding_Bed_C")
    if valid(bed) then
        log("  Found bed instance!")
        local fp = try(function() return bed:GetFullName() end)
        log("  Full path: " .. (fp or "?"))
        -- Dump all its blueprint functions
        pcall(function()
            local cls = bed:GetClass()
            if valid(cls) then
                local count = 0
                cls:ForEachFunction(function(fn)
                    local n = try(function() return fn:GetFName():ToString() end)
                    log("  Bed.fn: " .. (n or "?"))
                    count = count + 1
                end)
                log("  Bed: " .. count .. " functions total")
            end
        end)
    else
        log("  No BP_BaseBuilding_Bed_C instance in world yet (load a world first)")
    end
end)

-- ── D) GameplayAbility / Effect sleep probes ──────────────────────────────
log("--- GameplayAbility sleep candidates ---")
local gaCandidates = {
    "/Game/Gameplay/Abilities/GA_Sleep.GA_Sleep_C:K2_ActivateAbility",
    "/Game/Gameplay/Abilities/GA_AdvanceDay.GA_AdvanceDay_C:K2_ActivateAbility",
    "/Game/Gameplay/GameplayEffects/GE_AdvanceDay.GE_AdvanceDay_C:OnGameplayEffectAdded",
    "/Game/Gameplay/Sleep/GA_Sleep.GA_Sleep_C:K2_ActivateAbility",
}
for _, path in ipairs(gaCandidates) do
    probeExists(path)
end

log("")
log("Probe complete. " .. existsCount .. " function(s) found.")
log("============================================================\n")

-- ── Hook BP_ClientDoWakeTransition (fires when waking up) ─────────────────
-- If this fires, we can capture in-world state at wake time.
pcall(function()
    RegisterHook("/Script/Dominion.PlayerRestComponent:BP_ClientDoWakeTransition",
        function(self)
            local rest = try(function() return self:get() end)
            ExecuteInGameThread(function()
                log("[BP_ClientDoWakeTransition] FIRED — waking up")
                if valid(rest) then
                    local sleeping = try(function() return rest.IsSleeping end)
                    log("  IsSleeping at wake: " .. tostring(sleeping))
                    local bed = try(function() return rest.CurrentRestingAreaActor end)
                    if valid(bed) then
                        local bn = try(function() return bed:GetClass():GetFullName() end)
                        local fp = try(function() return bed:GetFullName() end)
                        log("  Bed class: " .. (bn or "?"))
                        log("  Bed path:  " .. (fp or "?"))
                    else
                        log("  Bed: nil at wake time too")
                    end
                end
            end)
        end,
        function(self) end
    )
    log("Hooked: BP_ClientDoWakeTransition")
end)

-- ── Also keep OnFullyRested ────────────────────────────────────────────────
pcall(function()
    RegisterHook("/Script/Dominion.PlayerRestComponent:OnFullyRested",
        function(self)
            local rest = try(function() return self:get() end)
            ExecuteInGameThread(function()
                log("[OnFullyRested] FIRED")
                if valid(rest) then
                    local bed = try(function() return rest.CurrentRestingAreaActor end)
                    log("  Bed at OnFullyRested: " .. (valid(bed) and
                        (try(function() return bed:GetClass():GetFullName() end) or "?") or "nil"))
                end
            end)
        end,
        function(self) end
    )
    log("Hooked: OnFullyRested")
end)

log("Phase 5 ready. Sleep in a bed to trigger wake/rested hooks.")
