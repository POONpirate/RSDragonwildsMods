-- =============================================================================
-- PropertyDumper — main.lua v5
-- Probe RegisterHook to discover which C++ functions exist on key classes.
-- RegisterHook throws an error for non-existent function paths, so
-- pcall wrapping it gives us a reliable "exists / doesn't exist" signal.
-- =============================================================================

local function log(msg)
    print("[PropertyDumper] " .. msg .. "\n")
end

local function probeClassFunctions(label, classPath)
    log("=== PROBE " .. label .. " (" .. classPath .. ") ===")

    local names = {
        -- ── known-working (sanity check) ────────────────────────
        "CanSleep", "CanRest", "IsResting", "GetIsSleeping",
        "IsClaimedByPlayer", "IsClaimedByAnyPlayer",
        "GetCurrentRestingPlayer", "GetCurrentRestingAreaActor",
        "GetCurrentRestingAreaComponent", "GetPlayerRestComponent",

        -- ── sleep / rest START ───────────────────────────────────
        "StartSleeping", "StartResting",
        "BeginSleeping", "BeginResting",
        "TrySleep", "TryResting",
        "InitiateSleep", "InitiateRest",
        "DoSleep", "DoRest",
        "Sleep", "Rest",
        "ActivateSleep", "ActivateRest",
        "EnterSleepState", "EnterRestState",
        "SetIsSleeping", "SetIsResting",
        "SetSleeping", "SetResting",
        "ToggleSleeping", "ToggleResting",
        "RequestSleep", "RequestResting",
        "ConfirmSleep", "NotifySleeping",

        -- ── sleep / rest STOP ────────────────────────────────────
        "StopSleeping", "StopResting",
        "EndSleeping", "EndResting",
        "ExitSleepState", "ExitRestState",
        "LeaveSleep", "LeaveRest",

        -- ── callbacks ────────────────────────────────────────────
        "OnStartSleeping", "OnStartResting",
        "OnBeginSleeping", "OnBeginResting",
        "OnSleepStarted", "OnRestStarted",
        "OnSleepEnded", "OnRestEnded",
        "OnPlayerStartedSleeping", "OnPlayerStartedResting",
        "OnFullyRested",

        -- ── server / RPC variants ────────────────────────────────
        "ServerStartSleeping", "ServerStartResting",
        "ServerSetSleeping", "ServerSetResting",
        "ServerConfirmSleep",
        "ClientStartSleeping", "ClientStartResting",
        "MulticastStartSleeping", "MulticastStartResting",
        "ServerPlayerWantsToSleep",

        -- ── area / bed assignment ────────────────────────────────
        "SetRestingArea", "SetCurrentRestingArea",
        "SetRestingAreaActor", "SetRestingAreaComponent",
        "SetCurrentBed", "SetBed", "AssignBed",
        "RegisterAsSleeping", "PlayerWantsToSleep",
        "PlayerStartedSleeping", "PlayerBeginsResting",
    }

    local hits = 0
    for _, fname in ipairs(names) do
        local path = classPath .. ":" .. fname
        local ok, result = pcall(function()
            return RegisterHook(path, function() end, function() end)
        end)
        if ok and result ~= nil then
            log("  HIT  " .. fname)
            hits = hits + 1
        end
    end

    if hits == 0 then
        log("  (no hits — all names returned errors)")
    end
    log("  " .. hits .. " / " .. #names .. " names found")
end

log("============================================================")
log("PropertyDumper v5 — RegisterHook probe scanner")
log("============================================================")

probeClassFunctions("PlayerRestComponent", "/Script/Dominion.PlayerRestComponent")
probeClassFunctions("BedComponent",        "/Script/Dominion.BedComponent")
probeClassFunctions("RestingAreaComponent","/Script/Dominion.RestingAreaComponent")
probeClassFunctions("DominionPlayerChar",  "/Script/Dominion.DominionPlayerCharacter")

log("Probe scan complete.")
log("============================================================")
