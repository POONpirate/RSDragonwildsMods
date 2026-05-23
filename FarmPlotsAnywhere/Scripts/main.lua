---@diagnostic disable: undefined-global

-- FarmPlotsAnywhere - UE4SS Lua Mod
-- Allows all three farm plot tiers to be placed anywhere, including in the air.
--
-- KEY LESSONS LEARNED (from reading Architect mod source):
--   1. Use dot notation (obj.Property) — NOT GetPropertyValue/SetPropertyValue
--   2. NotifyOnNewObject works with NATIVE class paths (/Script/Dominion.BaseBuildingActor)
--      NOT Blueprint paths like /Game/Gameplay/.../BP_FarmPlot1x1_T1_C
--   3. Farm plots use BuildingStabilityProfileRowHandle (DataTable row) instead of a
--      direct BuildingStabilityProfile ref — Architect's patch silently skips them
--   4. Working hooks: BuildModeComponent:OnValidityStateChange, etc.

local MOD = "[FarmPlotsAnywhere] "
local function log(msg) print(MOD .. msg .. "\n") end

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

    log("  Done patching " .. label)
end

-- ============================================================================
-- PATCH DT_StabilityProfile — the DataTable with "FarmPlot" row
-- This is the restriction Architect misses (it only checks PlacementProfile tables)
-- ============================================================================

-- FindAllOf("DataTable") doesn't work in this build — use safeFindObject directly.
local knownStabilityTables = {
    "/Game/Gameplay/BaseBuilding_New/DT_StabilityProfile.DT_StabilityProfile",
}

local patchedTables = {}

local function safeFindObject(path)
    local ok, r = pcall(StaticFindObject, path)
    return (ok and r and r:IsValid()) and r or nil
end

local function patchDataTableRows(dt, dtname)
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
            pcall(function()
                row.MinStability   = -1.0
                row.MaxStability   = 100.0
                row.VerticalLoss   = 0.0
                row.HorizontalLoss = 0.0
                row.bCanOnlyBePlacedOnGround                  = false
                row.bRequiresGround                           = false
                row.bCanOnlyBePlacedOnDefinedSurface          = false
                row.bCanOnlyBePlacedOnCertainPhysicalSurfaces = false
                row.bCanOnlyBeSnapped                         = false
                row.bGroundOnly                               = false
                row.bRequiresFoundation                       = false
            end)
            count = count + 1
        end
    end
    log("  Patched " .. count .. " rows in " .. dtname)
end

local function patchStabilityProfileTables()
    for _, path in ipairs(knownStabilityTables) do
        if not patchedTables[path] then
            local dt = safeFindObject(path)
            if dt then
                log("Found DataTable: " .. path)
                patchDataTableRows(dt, path)
                patchedTables[path] = true
            else
                log("DataTable not in memory yet: " .. path)
            end
        end
    end
end

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
-- HOOKS — same ones Architect confirms work, but filtered to farm plots only
-- ============================================================================

-- OnValidityStateChange: fires when the ghost preview's validity changes (red/green)
-- We intercept it for farm plots and force state = 0 (valid)
local hookOk1 = pcall(function()
    RegisterHook("/Script/Dominion.BuildModeComponent:OnValidityStateChange", function(Context, State)
        local comp = Context:get()
        if not comp or not comp:IsValid() then return end
        local ppOk, pp = pcall(function() return comp.PreviewPiece end)
        if ppOk and pp and pp:IsValid() and isFarmPlotActor(pp) then
            if State and State.set then State:set(0) end
            pcall(function() pp.StabilityValue = 1.0 end)
            pcall(function() pp:OnValiditySpawnStateChanged(0) end)
        end
    end)
end)
log("OnValidityStateChange hook: " .. (hookOk1 and "OK" or "FAILED"))

-- OnValiditySpawnStateChanged: fires on the actor when its validity state is set
local hookOk2 = pcall(function()
    RegisterHook("/Script/Dominion.BaseBuildingActor:OnValiditySpawnStateChanged", function(Context, State)
        local actor = Context:get()
        if actor and actor:IsValid() and isFarmPlotActor(actor) then
            if State and State.set then State:set(0) end
            pcall(function() actor.StabilityValue = 1.0 end)
        end
    end)
end)
log("OnValiditySpawnStateChanged hook: " .. (hookOk2 and "OK" or "FAILED"))

-- OnRep_StabilityValue: keep farm plot stability at 1.0 when it replicates
local hookOk3 = pcall(function()
    RegisterHook("/Script/Dominion.BaseBuildingActor:OnRep_StabilityValue", function(Context)
        local actor = Context:get()
        if actor and actor:IsValid() and isFarmPlotActor(actor) then
            pcall(function() actor.StabilityValue = 1.0 end)
        end
    end)
end)
log("OnRep_StabilityValue hook: " .. (hookOk3 and "OK" or "FAILED"))

-- TrySpawnPieceAtLocation: force return value = 0 (success) for farm plots
-- Note: we can't easily filter here without more context, so we check PreviewPiece
local hookOk4 = pcall(function()
    RegisterHook("/Script/Dominion.BuildModeComponent:TrySpawnPieceAtLocation", function(Context, _, _, _, ReturnValue)
        local comp = Context:get()
        if not comp or not comp:IsValid() then return end
        local ppOk, pp = pcall(function() return comp.PreviewPiece end)
        if ppOk and pp and pp:IsValid() and isFarmPlotActor(pp) then
            if ReturnValue and ReturnValue.set then ReturnValue:set(0) end
        end
    end)
end)
log("TrySpawnPieceAtLocation hook: " .. (hookOk4 and "OK" or "FAILED"))

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
        patchedActors = setmetatable({}, { __mode = "k" })

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
