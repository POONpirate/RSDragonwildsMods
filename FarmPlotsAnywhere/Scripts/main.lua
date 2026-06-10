---@diagnostic disable: undefined-global

-- FarmPlotsAnywhere - UE4SS Lua Mod
-- Allows all three farm plot tiers to be placed anywhere, including in the air.
--
-- KEY LESSONS LEARNED:
--   1. Use dot notation (obj.Property) — NOT GetPropertyValue/SetPropertyValue
--   2. NotifyOnNewObject works with NATIVE class paths (/Script/Dominion.BaseBuildingActor)
--   3. Farm plots use BuildingStabilityProfileRowHandle (DataTable row) — no direct profile ptr
--   4. OnValidityStateChange / TrySpawnPieceAtLocation register OK but NEVER FIRE —
--      they are pure native C++ calls, bypassing UE4SS ProcessEvent hooks entirely.
--   5. The ONLY reliable trigger is NotifyOnNewObject. Each farm plot ghost re-spawns
--      constantly while in build mode, so we use that to keep the cheat flag live.
--   6. bCheatAlwaysAllowBuilding on BuildingSubsystem bypasses placement validation globally.
--      We turn it on when a farm plot ghost spawns, and poll every 1 s to keep it alive.
--   7. EValiditySpawnState::Floating (2) is the ACTUAL blocker for air placement.
--      It is a native C++ physics check in BuildPlacementComponent — completely separate
--      from PlacementProfile.bCanOnlyBePlacedOnGround. Patching the DataTable rows does
--      NOT prevent the Floating check from firing.
--   8. OnValiditySpawnStateChanged on BaseBuildingActor has f: ProcessInternal (Blueprint
--      bytecode) and IS hookable via RegisterHook. Intercepting it for farm plot actors and
--      forcing state=0 (Valid) is the correct fix for the "can't place in air" restriction.

local MOD = "[FarmPlotsAnywhere] "
local function log(msg) print(MOD .. msg .. "\n") end

-- ============================================================================
-- BuildingSubsystem — bCheatAlwaysAllowBuilding bypasses all placement checks
-- (defined first because patchFarmPlotActor calls keepCheatAlive)
-- ============================================================================

local cheatEnabled = false

local function setBuildingCheat(enabled)
    if cheatEnabled == enabled then return end
    local ok, subs = pcall(function() return FindAllOf("BuildingSubsystem") end)
    if ok and subs and #subs > 0 then
        for _, sub in ipairs(subs) do
            pcall(function() sub.bCheatAlwaysAllowBuilding = enabled end)
        end
        cheatEnabled = enabled
        log("bCheatAlwaysAllowBuilding = " .. tostring(enabled) .. " (applied to " .. #subs .. " subsystem(s))")
    else
        log("setBuildingCheat: BuildingSubsystem not found!")
    end
end

-- Track every farm plot actor we've ever patched (weak so GC'd actors disappear).
-- Used by the poll to decide whether to keep the cheat alive.
local activeFarmPlots = setmetatable({}, { __mode = "k" })

local pollRunning = false

local function startFarmPlotPoll()
    if pollRunning then return end
    pollRunning = true
    log("Farm plot poll started")

    local function doPoll()
        -- Check if any previously-patched farm plot actor is still alive
        local anyLive = false
        for actor, _ in pairs(activeFarmPlots) do
            local ok, valid = pcall(function() return actor:IsValid() end)
            if ok and valid then
                anyLive = true
                break
            end
        end

        if anyLive then
            setBuildingCheat(true)
            ExecuteWithDelay(1000, doPoll)   -- check again in 1 s
        else
            setBuildingCheat(false)
            pollRunning = false
            log("Farm plot poll stopped — no live farm plot actors")
        end
    end

    ExecuteWithDelay(1000, doPoll)
end

-- ============================================================================
-- FARM PLOT DETECTION
-- ============================================================================

local function isFarmPlotActor(actor)
    if not actor or not actor:IsValid() then return false end
    local ok, name = pcall(function() return actor:GetClass():GetName() end)
    if ok and name and name:find("FarmPlot") then return true end
    -- Also check via BuildingPieceData name
    local pok, pd = pcall(function() return actor.BuildingPieceData end)
    if pok and pd then
        local nok, pdname = pcall(function() return pd:GetFullName() end)
        if nok and pdname and pdname:find("FarmPlot") then return true end
    end
    return false
end

-- ============================================================================
-- PATCH FARM PLOT ACTOR (ghost preview or placed)
-- ============================================================================

local patchedActors = setmetatable({}, { __mode = "k" })

local function patchFarmPlotActor(actor, label)
    if not actor or not actor:IsValid() then return end
    if patchedActors[actor] then return end
    patchedActors[actor] = true

    label = label or "FarmPlot"
    log("Patching: " .. label)

    -- Force stability value high so all stability checks pass
    pcall(function() actor.StabilityValue = 1.0 end)

    -- Patch direct StabilityProfile if present (may be nil for farm plots)
    local spOk, sp = pcall(function() return actor.StabilityProfile end)
    if spOk and sp then
        pcall(function()
            sp.MinStability  = -1.0
            sp.MaxStability  = 100.0
            sp.VerticalLoss  = 0.0
            sp.HorizontalLoss = 0.0
        end)
        log("  Patched StabilityProfile on actor")
    end

    -- Patch BuildingPieceData's stability profile if accessible
    local pdOk, pd = pcall(function() return actor.BuildingPieceData end)
    if pdOk and pd and pd:IsValid() then
        local bspOk, bsp = pcall(function() return pd.BuildingStabilityProfile end)
        local bspValid = false
        if bspOk and bsp then pcall(function() bspValid = bsp:IsValid() end) end
        if bspValid then
            pcall(function()
                bsp.MinStability  = -1.0
                bsp.MaxStability  = 100.0
                bsp.VerticalLoss  = 0.0
                bsp.HorizontalLoss = 0.0
            end)
            log("  Patched BuildingPieceData.BuildingStabilityProfile")
        else
            log("  BuildingPieceData.BuildingStabilityProfile is nullptr (uses DataTable row)")
        end

        -- Try ground/surface restriction flags on PieceData directly
        for _, p in ipairs({
            "bCanOnlyBePlacedOnGround", "bRequiresGround", "bGroundOnly",
            "bRequiresFoundation", "bRequiresSurface",
        }) do
            pcall(function() pd[p] = false end)
        end
    end

    -- Force the validity spawn state to valid (0 = valid in this game's enum)
    pcall(function() actor:OnValiditySpawnStateChanged(0) end)

    -- Register this actor so the poll knows it exists, then ensure the poll is running.
    -- The poll checks IsValid() every second; while ANY farm plot actor is live the cheat
    -- stays on. It turns off automatically once all farm plot actors are destroyed.
    activeFarmPlots[actor] = true
    startFarmPlotPoll()

    log("  Done patching " .. label)
end

-- ============================================================================
-- DATATABLE PATCHING
-- Two separate systems:
--   DT_StabilityProfile  — structural stability (does the building collapse)
--   DT_PlacementProfile  — WHERE placement is allowed (ground-only, surface checks)
-- The "can't place in air" error comes from PlacementProfile, NOT StabilityProfile.
-- BaseBuildingActor.PlacementProfileRowHandle (offset 0x6A0) references DT_PlacementProfile.
-- ============================================================================

local patchedTables = {}

local function safeFindObject(path)
    local ok, r = pcall(StaticFindObject, path)
    return (ok and r and r:IsValid()) and r or nil
end

-- Patch every row in a PlacementProfile DataTable.
-- PlacementProfile struct fields (confirmed from object dump):
--   bCanOnlyBeSnapped, bCanOnlyBePlacedOnDefinedSurface,
--   bCanOnlyBePlacedOnCertainPhysicalSurfaces, bCanOnlyBePlacedOnGround
local function patchPlacementProfileRows(dt, dtname)
    if not dt or not dt:IsValid() then return end
    local rok, rows = pcall(function() return dt:GetRowNames() end)
    if not rok or not rows then
        log("  GetRowNames() failed on " .. dtname)
        return
    end
    local count = 0
    for _, rowName in ipairs(rows) do
        local row = nil
        pcall(function() row = dt:FindRow(rowName) end)
        if row then
            pcall(function() row.bCanOnlyBePlacedOnGround                  = false end)
            pcall(function() row.bCanOnlyBePlacedOnDefinedSurface          = false end)
            pcall(function() row.bCanOnlyBePlacedOnCertainPhysicalSurfaces = false end)
            pcall(function() row.bCanOnlyBeSnapped                         = false end)
            pcall(function() row.bRequiresGround                           = false end)
            pcall(function() row.bGroundOnly                               = false end)
            pcall(function() row.bRequiresFoundation                       = false end)
            -- Read back first row to verify writes are sticking
            if count == 0 then
                local v = "?"
                pcall(function() v = tostring(row.bCanOnlyBePlacedOnGround) end)
                log("  Readback row[" .. tostring(rowName) .. "] bCanOnlyBePlacedOnGround=" .. v)
            end
            count = count + 1
        end
    end
    log("  Patched " .. count .. " PlacementProfile rows in " .. dtname)
end

-- Patch every row in a StabilityProfile DataTable (keep for completeness).
local function patchStabilityProfileRows(dt, dtname)
    if not dt or not dt:IsValid() then return end
    local rok, rows = pcall(function() return dt:GetRowNames() end)
    if not rok or not rows then return end
    local count = 0
    for _, rowName in ipairs(rows) do
        local row = nil
        pcall(function() row = dt:FindRow(rowName) end)
        if row then
            pcall(function() row.MinStability   = -1.0 end)
            pcall(function() row.MaxStability   = 100.0 end)
            pcall(function() row.VerticalLoss   = 0.0 end)
            pcall(function() row.HorizontalLoss = 0.0 end)
            count = count + 1
        end
    end
    log("  Patched " .. count .. " StabilityProfile rows in " .. dtname)
end

-- All known DataTables with their patch function
local knownTables = {
    -- THE KEY TABLE: placement validation ("can't place in air" comes from here)
    { path = "/Game/Gameplay/BaseBuilding_New/DT_PlacementProfile.DT_PlacementProfile",              fn = patchPlacementProfileRows },
    { path = "/Game/Gameplay/BaseBuilding/PlacementProfileDataTable.PlacementProfileDataTable",       fn = patchPlacementProfileRows },
    -- Stability table (structural integrity — secondary, keep patching for completeness)
    { path = "/Game/Gameplay/BaseBuilding_New/DT_StabilityProfile.DT_StabilityProfile",              fn = patchStabilityProfileRows },
}

local function patchAllKnownTables()
    for _, entry in ipairs(knownTables) do
        if not patchedTables[entry.path] then
            local dt = safeFindObject(entry.path)
            if dt then
                log("Found DataTable: " .. entry.path)
                entry.fn(dt, entry.path)
                patchedTables[entry.path] = true
            else
                log("DataTable not in memory yet: " .. entry.path)
            end
        end
    end
end

-- Keep the old name so ClientRestart / Initial sweep calls still work
local function patchStabilityProfileTables() patchAllKnownTables() end

-- ============================================================================
-- PATCH ALL BuildingPieceData that belong to farm plots
-- ============================================================================

local patchedPieceData = setmetatable({}, { __mode = "k" })

local function patchFarmPieceData(pd)
    if not pd or not pd:IsValid() then return end
    if patchedPieceData[pd] then return end

    local nok, name = pcall(function() return pd:GetFullName() end)
    if not nok or not name or not name:find("FarmPlot") then return end

    patchedPieceData[pd] = true
    log("Patching BuildingPieceData: " .. name)

    local bspOk, bsp = pcall(function() return pd.BuildingStabilityProfile end)
    local bspValid = false
    if bspOk and bsp then pcall(function() bspValid = bsp:IsValid() end) end
    if bspValid then
        pcall(function()
            bsp.MinStability  = -1.0
            bsp.MaxStability  = 100.0
            bsp.VerticalLoss  = 0.0
            bsp.HorizontalLoss = 0.0
        end)
        log("  Patched BuildingStabilityProfile on PieceData")
    else
        log("  BuildingStabilityProfile is nullptr (uses DataTable row handle)")
    end

    -- Try ground flags directly on PieceData
    for _, p in ipairs({
        "bCanOnlyBePlacedOnGround", "bRequiresGround", "bGroundOnly",
        "bRequiresFoundation", "bCanOnlyBePlacedOnDefinedSurface",
    }) do
        pcall(function() pd[p] = false end)
    end
end

local function patchAllFarmPieceData()
    local allPD = FindAllOf("BuildingPieceData")
    if not allPD then return end
    for _, pd in ipairs(allPD) do
        patchFarmPieceData(pd)
    end
end

-- ============================================================================
-- HOOKS (informational — these register OK but are pure-native and never fire)
-- Left here so if a game update makes them Blueprint-callable, they start working.
-- ============================================================================

local hookOk1 = pcall(function()
    RegisterHook("/Script/Dominion.BuildModeComponent:OnValidityStateChange", function(Context, State)
        local comp = Context:get()
        if not comp or not comp:IsValid() then return end
        local ppOk, pp = pcall(function() return comp.PreviewPiece end)
        if ppOk and pp then
            local valid = false
            pcall(function() valid = pp:IsValid() end)
            if valid and isFarmPlotActor(pp) then
                if State and State.set then State:set(0) end
                pcall(function() pp.StabilityValue = 1.0 end)
                activeFarmPlots[pp] = true
                startFarmPlotPoll()
            end
        end
    end)
end)
log("OnValidityStateChange hook: " .. (hookOk1 and "OK (note: may not fire — pure native)" or "FAILED"))

local hookOk2 = pcall(function()
    RegisterHook("/Script/Dominion.BaseBuildingActor:OnRep_StabilityValue", function(Context)
        local actor = Context:get()
        if actor and actor:IsValid() and isFarmPlotActor(actor) then
            pcall(function() actor.StabilityValue = 1.0 end)
        end
    end)
end)
log("OnRep_StabilityValue hook: " .. (hookOk2 and "OK" or "FAILED"))

-- OnValiditySpawnStateChanged — HAS ProcessInternal address, IS hookable.
-- EValiditySpawnState: Valid=0, Overlapping=1, Floating=2, NeedsFoundation=3,
--   NeedsSnapping=4, Unstable=5, MissingMaterials=6, WrongPhysicalSurface=7,
--   InsideVault=8, InsideProtectedArea=9, ReachedCountLimit=10,
--   ShelterCheckFailed=11, None=12
-- Floating (2) is the native physics check that blocks air placement.
-- We intercept it here and force Valid (0) for any farm plot actor.
local hookOk3 = pcall(function()
    RegisterHook("/Script/Dominion.BaseBuildingActor:OnValiditySpawnStateChanged", function(Context, NewValiditySpawnState)
        local actor = Context:get()
        if not actor or not actor:IsValid() then return end
        if not isFarmPlotActor(actor) then return end
        local state = nil
        pcall(function() state = NewValiditySpawnState:get() end)
        if state ~= nil and state ~= 0 then
            log("  OnValiditySpawnStateChanged: intercepted state=" .. tostring(state) .. " -> forcing 0 (Valid)")
            pcall(function() NewValiditySpawnState:set(0) end)
            activeFarmPlots[actor] = true
            startFarmPlotPoll()
        end
    end)
end)
log("OnValiditySpawnStateChanged hook: " .. (hookOk3 and "OK" or "FAILED"))

-- ============================================================================
-- NotifyOnNewObject — use NATIVE class path (works; BP paths don't work)
-- ============================================================================

-- Catch farm plots when they spawn (ghost preview or placed)
NotifyOnNewObject("/Script/Dominion.BaseBuildingActor", function(actor)
    ExecuteWithDelay(50, function()
        if actor and actor:IsValid() and isFarmPlotActor(actor) then
            patchFarmPlotActor(actor, "BaseBuildingActor (notify)")
        end
    end)
end)

-- Catch new BuildingPieceData (farm plot data assets loading)
NotifyOnNewObject("/Script/Dominion.BuildingPieceData", function(pd)
    ExecuteWithDelay(100, function()
        patchFarmPieceData(pd)
    end)
end)

-- ============================================================================
-- ClientRestart — full sweep on every map load
-- ============================================================================

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
    ExecuteInGameThread(function()
        log("=== ClientRestart sweep ===")
        patchedActors    = setmetatable({}, { __mode = "k" })
        activeFarmPlots  = setmetatable({}, { __mode = "k" })
        pollRunning      = false

        -- Patch DataTables first
        patchStabilityProfileTables()

        -- Patch all farm BuildingPieceData in memory
        patchAllFarmPieceData()

        -- Patch any live farm plot actors
        for _, className in ipairs({
            "BP_FarmPlot1x1_Base_C", "BP_FarmPlot1x1_T1_C",
            "BP_FarmPlot1x1_T2_C",   "BP_FarmPlot1x1_T3_C",
        }) do
            local ok, actors = pcall(function() return FindAllOf(className) end)
            if ok and actors and #actors > 0 then
                log("FindAllOf " .. className .. ": " .. #actors)
                for _, actor in ipairs(actors) do
                    patchFarmPlotActor(actor, className)
                end
            end
        end

        log("=== ClientRestart done ===")
    end)
end)

-- ============================================================================
-- Initial delayed sweep (in case ClientRestart already fired before we loaded)
-- ============================================================================

ExecuteWithDelay(3000, function()
    log("=== Initial sweep ===")
    patchStabilityProfileTables()
    patchAllFarmPieceData()
    log("=== Initial sweep done ===")
end)

log("Loaded. Using native class hooks + DataTable patching.")
