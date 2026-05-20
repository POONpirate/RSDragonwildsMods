-- =============================================================================
-- PersonalInventoryMod — main.lua
-- Hooks the Eye of Oculus spell to open a second personal inventory (40 slots).
-- The regular bank/Personal Chest is left completely untouched.
-- Item data persists in a per-character JSON file so it survives mod removal.
-- JSON is written whenever the game itself saves, keeping mod data in sync with
-- the game's own save state.
-- =============================================================================

local json = require("json")

-- -----------------------------------------------------------------------------
-- Config
-- -----------------------------------------------------------------------------

local MOD_NAME         = "PersonalInventoryMod"
local SECOND_INV_SLOTS = 40

local SPELL_HOOK = "/Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded"

local GAME_SAVE_HOOKS = {
    "/Script/Dominion.DominionPlayerController:ServerSaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveCharacter",
    "/Script/Dominion.DominionPlayerController:SaveGame",
    "/Script/Dominion.DominionGameMode:SaveGame",
    "/Script/Dominion.DominionGameMode:AutoSave",
    "/Script/Dominion.DominionGameMode:SaveWorld",
    "/Script/Engine.GameplayStatics:SaveGameToSlot",
}

-- Confirmed empty inventory format (observed from real InventoryComponent instances).
-- Seeded before first open so OpenPersonalInventory initializes the slot array.
local EMPTY_INV_JSON = '{"Version":67,"MaxSlotIndex":-1,"AllowAdds":false}'

local SAVE_DIR = nil

-- -----------------------------------------------------------------------------
-- Runtime state
-- -----------------------------------------------------------------------------
-- All tables are keyed by GUID (stable string), NOT by ctrl (Lua proxy object).
-- FindAllOf returns a new Lua proxy object each call even for the same underlying
-- UObject, so using ctrl as a table key always misses on subsequent casts.

local SecondInventories  = {}  -- guid → PersonalInventoryComponent
local ControllersByGuid  = {}  -- guid → ctrl  (kept for open/save calls)
local CachedInventoryJson = {} -- guid → json string (captured from component between casts)

-- -----------------------------------------------------------------------------
-- Logging helpers
-- -----------------------------------------------------------------------------

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
end

local function log_err(msg)
    print(string.format("[%s] ERROR: %s\n", MOD_NAME, msg))
end

-- -----------------------------------------------------------------------------
-- Save directory resolution
-- -----------------------------------------------------------------------------

local function get_save_dir()
    if SAVE_DIR then return SAVE_DIR end
    SAVE_DIR = "ue4ss/Mods/" .. MOD_NAME .. "/"
    log("Save directory set to: " .. SAVE_DIR)
    return SAVE_DIR
end

local function json_path(guid)
    return get_save_dir() .. MOD_NAME .. "_" .. guid .. ".json"
end

-- -----------------------------------------------------------------------------
-- JSON persistence
-- -----------------------------------------------------------------------------

local function load_inventory_data(guid)
    local path = json_path(guid)
    local file = io.open(path, "r")
    if not file then
        log("No save file found for GUID " .. guid .. ".")
        return nil
    end
    local content = file:read("*a")
    file:close()
    if content == "" then return nil end
    log("Loaded saved inventory for GUID " .. guid)
    return content
end

local function save_inventory_data(guid, inv_comp, fallback_json)
    if not inv_comp or not inv_comp:IsValid() then return end

    local path = json_path(guid)
    local file = io.open(path, "w")
    if not file then
        log_err("Could not open save file for writing: " .. path)
        return
    end

    local ok_json, json_str = pcall(function()
        return inv_comp:GetPropertyValue("JsonInventory"):ToString()
    end)

    if ok_json and json_str and json_str ~= "" and json_str ~= EMPTY_INV_JSON then
        file:write(json_str)
        file:close()
        log("Saved inventory (live) for GUID " .. guid)
        return
    end

    if fallback_json and fallback_json ~= "" and fallback_json ~= EMPTY_INV_JSON then
        file:write(fallback_json)
        file:close()
        log("Saved inventory (cached) for GUID " .. guid)
        return
    end

    file:close()
    log("Inventory is empty — nothing written for GUID " .. guid)
end

local function save_all_inventories()
    local count = 0
    for guid, inv in pairs(SecondInventories) do
        if inv:IsValid() then
            save_inventory_data(guid, inv, CachedInventoryJson[guid])
            count = count + 1
        end
    end
    if count > 0 then
        log("Game save — wrote " .. count .. " second inventor" .. (count == 1 and "y." or "ies."))
    end
end

-- -----------------------------------------------------------------------------
-- Inventory population
-- -----------------------------------------------------------------------------

local function populate_inventory(inv_comp, data)
    if not data or data == "" then return end
    local ok, err = pcall(function()
        inv_comp:SetPropertyValue("JsonInventory", data)
    end)
    if ok then
        log("Set JsonInventory on component.")
        pcall(function() inv_comp.OnInventoryLoadedFromSave:Broadcast() end)
    else
        log_err("Failed to set JsonInventory: " .. tostring(err))
    end
end

-- -----------------------------------------------------------------------------
-- Second inventory component construction
-- -----------------------------------------------------------------------------

local function get_or_create_second_inventory(guid, ctrl)
    -- Check existing Lua reference first.
    if SecondInventories[guid] and SecondInventories[guid]:IsValid() then
        log("Reusing existing second inventory component.")
        return SecondInventories[guid]
    end

    -- Lua reference may be stale even if the UObject is still alive (GC hasn't
    -- collected it because ctrl is still its outer). Search by component name.
    local ok_fa, all_pics = pcall(function() return FindAllOf("PersonalInventoryComponent") end)
    if ok_fa and all_pics then
        for _, pic in ipairs(all_pics) do
            if pic:IsValid() then
                local ok_nm, nm = pcall(function() return pic:GetName() end)
                if ok_nm and nm and nm:find("SecondPersonalInventory") then
                    log("Re-found SecondPersonalInventory by name — storing reference.")
                    SecondInventories[guid] = pic
                    return pic
                end
            end
        end
    end

    -- Construct a new component.
    local ok, second_inv = pcall(function()
        return StaticConstructObject(
            StaticFindObject("/Script/Dominion.PersonalInventoryComponent"),
            ctrl,
            FName("SecondPersonalInventory")
        )
    end)

    if not ok or not second_inv or not second_inv:IsValid() then
        log_err("StaticConstructObject failed: " .. tostring(second_inv))
        return nil
    end

    local ok2, err2 = pcall(function()
        second_inv:SetPropertyValue("MaxSlotCount", SECOND_INV_SLOTS)
    end)
    if not ok2 then
        log_err("Failed to set MaxSlotCount: " .. tostring(err2))
    else
        log("Second inventory constructed with " .. SECOND_INV_SLOTS .. " slots.")
    end

    -- NOTE: RegisterComponent(), InitializeComponent(), BeginPlay() all fail with
    -- "UObject instance is nullptr" in this UE4SS build. ctrl+click is handled
    -- via EMPTY_INV_JSON seed before first open.

    SecondInventories[guid] = second_inv
    return second_inv
end

-- -----------------------------------------------------------------------------
-- UI open logic
-- -----------------------------------------------------------------------------

local function open_second_inventory_ui(ctrl, second_inv, char_obj)
    local ok, err = pcall(function()
        second_inv:OpenPersonalInventory(34, char_obj)
    end)
    if ok then
        log("Second inventory UI opened (p1=34).")
    else
        log_err("OpenPersonalInventory(34) failed: " .. tostring(err))
        local ok2, err2 = pcall(function()
            second_inv:OpenPersonalInventory(ctrl, char_obj)
        end)
        if ok2 then
            log("OpenPersonalInventory fallback (p1=ctrl) succeeded.")
        else
            log_err("OpenPersonalInventory fallback also failed: " .. tostring(err2))
        end
    end
end

-- -----------------------------------------------------------------------------
-- Game-save hooks
-- -----------------------------------------------------------------------------

log("Registering game-save hooks...")
for _, hook_path in ipairs(GAME_SAVE_HOOKS) do
    local ok = pcall(function()
        RegisterHook(hook_path,
            function() end,
            function() ExecuteInGameThread(save_all_inventories) end
        )
    end)
    if ok then log("Save hook registered: " .. hook_path) end
end

-- -----------------------------------------------------------------------------
-- Eye of Oculus hook
-- -----------------------------------------------------------------------------

log("Waiting for player controller to register Eye of Oculus hook...")

local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    if hook_registered then return end

    ExecuteInGameThread(function()
        if hook_registered then return end

        log("Player controller ready — registering hooks...")

        local ok_oa = pcall(function()
            RegisterHook("/Script/Dominion.OculusComponent:ActivateOculus",
                function(self) end,
                function(self)
                    local ok_get, comp = pcall(function() return self:get() end)
                    if not ok_get or not comp then return end
                    local ok_d, err_d = pcall(function() comp:DeactivateOculus() end)
                    if ok_d then
                        log("Build menu closed via DeactivateOculus.")
                    else
                        log_err("DeactivateOculus failed: " .. tostring(err_d))
                    end
                end
            )
        end)
        if ok_oa then log("OculusComponent:ActivateOculus hook registered.")
        else log_err("Could not hook ActivateOculus.") end

        local reg_ok, reg_err = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance)
                    ExecuteInGameThread(function()
                        log("Eye of Oculus cast — finding local player controller...")

                        local all_ctrls = FindAllOf("DominionPlayerController")
                        if not all_ctrls or #all_ctrls == 0 then
                            log_err("FindAllOf returned no DominionPlayerController instances.")
                            return
                        end

                        local ctrl = nil
                        for _, c in ipairs(all_ctrls) do
                            if c:IsValid() then
                                local ok_local, is_local = pcall(function() return c:IsLocalController() end)
                                if ok_local and is_local then ctrl = c break end
                            end
                        end
                        if not ctrl then
                            for _, c in ipairs(all_ctrls) do
                                if c:IsValid() then ctrl = c break end
                            end
                        end
                        if not ctrl then
                            log_err("No valid DominionPlayerController found.")
                            return
                        end

                        -- Resolve GUID.
                        local ok_guid, guid_struct = pcall(function() return ctrl:GetCharacterGuid() end)
                        if not ok_guid or not guid_struct then
                            log_err("GetCharacterGuid failed: " .. tostring(guid_struct))
                            return
                        end
                        local ig = guid_struct.InnerGuid
                        local guid
                        if type(ig) == "string" then
                            guid = ig
                        else
                            local ok_ts, ts = pcall(function() return ig:ToString() end)
                            if ok_ts and ts and ts ~= "" then
                                guid = ts
                            else
                                guid = string.format("%08X%08X%08X%08X",
                                    ig.A or 0, ig.B or 0, ig.C or 0, ig.D or 0)
                            end
                        end
                        if not guid or guid == "" then
                            log_err("Could not resolve GUID.")
                            return
                        end
                        log("Controller found, GUID=" .. guid)
                        ControllersByGuid[guid] = ctrl

                        local char_obj = nil
                        local ok_ch, chars = pcall(function() return FindAllOf("DominionPlayerCharacter") end)
                        if ok_ch and chars then
                            for _, ch in ipairs(chars) do
                                if ch:IsValid() then char_obj = ch break end
                            end
                        end
                        if not char_obj then
                            log_err("Could not find DominionPlayerCharacter — UI may not open.")
                        end

                        local second_inv = get_or_create_second_inventory(guid, ctrl)
                        if not second_inv then return end

                        -- Decide what JSON to present to OpenPersonalInventory.
                        -- OpenPersonalInventory reloads from JsonInventory on every call,
                        -- wiping anything placed since the last open. We must set
                        -- JsonInventory to the correct state immediately before calling it.
                        --
                        -- Priority:
                        --   1. Current live JsonInventory on the component — if it's already
                        --      non-empty (items placed this session and JsonInventory updated
                        --      by the engine), just re-set it so OpenPersonalInventory sees it.
                        --   2. CachedInventoryJson — captured at close time if close hook works.
                        --   3. Disk save — items from a previous game session.
                        --   4. EMPTY_INV_JSON seed — very first open ever.

                        local ok_live, live_json = pcall(function()
                            return second_inv:GetPropertyValue("JsonInventory"):ToString()
                        end)
                        local has_live = ok_live and live_json and
                                         live_json ~= "" and live_json ~= EMPTY_INV_JSON

                        if has_live then
                            -- Re-set so OpenPersonalInventory definitely sees it.
                            pcall(function() second_inv:SetPropertyValue("JsonInventory", live_json) end)
                            log("Re-applied live JsonInventory (len=" .. #live_json .. ").")
                            CachedInventoryJson[guid] = live_json  -- keep cache in sync

                        elseif CachedInventoryJson[guid] then
                            populate_inventory(second_inv, CachedInventoryJson[guid])
                            log("Restored from session cache (len=" .. #CachedInventoryJson[guid] .. ").")

                        else
                            local saved = load_inventory_data(guid)
                            if saved then
                                populate_inventory(second_inv, saved)
                                log("Restored from disk.")
                            else
                                -- First ever open.
                                local ok_seed = pcall(function()
                                    second_inv:SetPropertyValue("JsonInventory", EMPTY_INV_JSON)
                                end)
                                if ok_seed then log("Seeded empty inventory (first open).") end
                            end
                        end

                        open_second_inventory_ui(ctrl, second_inv, char_obj)
                    end)
                end,

                function(self, Instance) end
            )
        end)

        if not reg_ok then
            log_err("Failed to register Eye of Oculus hook: " .. tostring(reg_err))
        else
            hook_registered = true
            log("All hooks registered. Waiting for Eye of Oculus cast.")
        end
    end)
end)
