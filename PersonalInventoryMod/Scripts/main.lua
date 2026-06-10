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
    -- Client_SaveToDisk is the RPC the game uses to write the character save
    -- (CharacterSave incl. PersonalInventory) to disk — confirmed in the CXX
    -- header dump. Hooking it keeps our JSON snapshot in lock-step with the
    -- game's own save moments, preventing item dupes/losses from out-of-sync
    -- writes. (SaveGameToSlot registers but never fires in this game.)
    -- NOTE: lives on DominionPlayerControllerBase (CXX dump line 8182), not
    -- DominionPlayerController — the derived-class path fails to register.
    "/Script/Dominion.DominionPlayerControllerBase:Client_SaveToDisk",
    -- RequestGameExit fires when leaving via the pause menu (to main menu OR
    -- desktop). Pre-hooked so the save lands before world teardown.
    "/Script/Dominion.DominionNetworkSubsystem:RequestGameExit",
    "/Script/Engine.GameplayStatics:SaveGameToSlot",
}

-- Confirmed format (observed from real InventoryComponent instances).
-- MaxSlotIndex:39 = "slots 0-39 exist" → UI renders 40 slots.
-- MaxSlotIndex:-1 only rendered 1 slot (just enough for the first item in ItemSlots).
-- Item content comes from ItemSlots (in-memory), NOT from this string — so setting
-- this before every OpenPersonalInventory gives us 40 slots without wiping items.
local SLOT_LAYOUT_JSON = '{"Version":67,"MaxSlotIndex":' .. (SECOND_INV_SLOTS - 1) .. ',"AllowAdds":false}'

-- 40-slot empty inventory JSON.  Used ONCE at component construction: setting this as
-- JsonInventory then firing OnInventoryLoadedFromSave:Broadcast() causes the engine to
-- parse the 40 explicit slot entries and pre-populate ItemSlots with 40 empty FItemSlot
-- structs.  Without this, ItemSlots starts at size 0 and only grows one entry per manual
-- drag, making all other slots unusable.
-- Excluded from save checks just like SLOT_LAYOUT_JSON.
local EMPTY_GUID = "00000000000000000000000000000000"
local function _build_empty_inv_json(n)
    local t = { '{"Version":67' }
    for i = 0, n - 1 do
        t[#t + 1] = string.format(',"%d":{"GUID":"%s","ItemData":"","Count":0}', i, EMPTY_GUID)
    end
    t[#t + 1] = string.format(',"MaxSlotIndex":%d,"AllowAdds":false}', n - 1)
    return table.concat(t)
end
local EMPTY_INV_JSON = _build_empty_inv_json(SECOND_INV_SLOTS)

local SAVE_DIR = nil

-- -----------------------------------------------------------------------------
-- Runtime state
-- -----------------------------------------------------------------------------
-- All tables are keyed by GUID (stable string), NOT by ctrl (Lua proxy object).
-- FindAllOf returns a new Lua proxy object each call even for the same underlying
-- UObject, so using ctrl as a table key always misses on subsequent casts.

local SecondInventories   = {}  -- guid → PersonalInventoryComponent
local ControllersByGuid   = {}  -- guid → ctrl  (kept for open/save calls)
local CachedInventoryJson = {}  -- guid → json string (captured from component between casts)
local LoadedFromDisk      = {}  -- guid → true once disk save has been restored this session
local PendingRestoreData  = {}  -- guid → json string; consumed by OPI post-hook after OpenPersonalInventory runs
local FailedRestoreSlots  = {}  -- guid → { [slot_key] = {GUID,ItemData,Count,Durability,Path} }
                                -- slots whose item couldn't be restored this session; preserved
                                -- in every save so the item is never silently deleted

-- -----------------------------------------------------------------------------
-- Logging helpers
-- -----------------------------------------------------------------------------

-- Parallel mod log file with immediate flush. UE4SS buffers print() output,
-- so UE4SS.log copied while the game is running can be truncated mid-write.
-- This file is always complete and safe to copy at any time.
local MOD_LOG_PATH = "ue4ss/Mods/" .. MOD_NAME .. "/" .. MOD_NAME .. ".log"
local mod_log_file = io.open(MOD_LOG_PATH, "w")  -- truncate per session

local function write_mod_log(line)
    local text = os.date("[%H:%M:%S] ") .. line .. "\n"
    -- io write fails SILENTLY (returns nil) if the handle goes bad — e.g. when
    -- an external tool locks the file. Detect and reopen in append mode so the
    -- log never quietly stops mid-session.
    if mod_log_file then
        local ok = pcall(function()
            assert(mod_log_file:write(text))
            mod_log_file:flush()
        end)
        if ok then return end
        pcall(function() mod_log_file:close() end)
        mod_log_file = nil
    end
    mod_log_file = io.open(MOD_LOG_PATH, "a")
    if mod_log_file then
        pcall(function()
            mod_log_file:write("[logger reopened]\n" .. text)
            mod_log_file:flush()
        end)
    end
end

local function log(msg)
    print(string.format("[%s] %s\n", MOD_NAME, msg))
    write_mod_log(msg)
end

local function log_err(msg)
    print(string.format("[%s] ERROR: %s\n", MOD_NAME, msg))
    write_mod_log("ERROR: " .. msg)
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
-- Manual ItemSlots serialization
-- -----------------------------------------------------------------------------
-- The engine never writes item data back into JsonInventory for our dynamic
-- component — only the game's native save system does that, and our component
-- isn't registered with it.  So we iterate ItemSlots ourselves and build the
-- JSON string manually at save time.
--
-- TArray userdata uses 1-based indexing in Lua (sv[0] errors, sv[1] succeeds).
-- FItemSlot property names come from the observed JsonInventory key format:
-- "GUID", "ItemData", "Count".

-- ---------------------------------------------------------------------------
-- GUID helpers
-- ---------------------------------------------------------------------------
-- FGuid has sub-fields A, B, C, D (each uint32).  GetPropertyValue returns an
-- FGuid userdata whose :ToString() often fails, so we read the raw components.
local function read_fguid(gv)
    if gv == nil then return "" end
    if type(gv) == "string" then
        return (gv ~= "" and gv ~= "00000000-00000000-00000000-00000000") and gv or ""
    end
    -- Try :ToString() first (works on some builds).
    local ok_ts, ts = pcall(function() return gv:ToString() end)
    if ok_ts and ts and ts ~= "" and ts ~= "00000000-00000000-00000000-00000000"
       and ts ~= "00000000000000000000000000000000" then
        return ts
    end
    -- Fall back to reading raw A/B/C/D sub-fields.
    local ok_a, a = pcall(function() return gv.A end)
    local ok_b, b = pcall(function() return gv.B end)
    local ok_c, c = pcall(function() return gv.C end)
    local ok_d, d = pcall(function() return gv.D end)
    if ok_a and ok_b and ok_c and ok_d then
        -- Mask to 32 bits: UE4SS may return uint32 as a sign-extended int64.
        -- Without masking, string.format("%08X", -1) → "FFFFFFFFFFFFFFFF" (16 chars)
        -- instead of "FFFFFFFF" (8 chars), producing malformed 40/48-char GUIDs.
        a = (tonumber(a) or 0) & 0xFFFFFFFF
        b = (tonumber(b) or 0) & 0xFFFFFFFF
        c = (tonumber(c) or 0) & 0xFFFFFFFF
        d = (tonumber(d) or 0) & 0xFFFFFFFF
        if a == 0 and b == 0 and c == 0 and d == 0 then return "" end
        return string.format("%08X%08X%08X%08X", a, b, c, d)
    end
    return ""
end

-- Normalize an FGuid string form to bare upper-case 32-hex (strip dashes).
local function norm_guid_hex(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("-", "")):upper()
end

-- Write a 32-hex GUID into a live FGuid userdata via sub-field assignment.
-- Returns ok, detail. Handles uint32 values > INT32_MAX by retrying signed.
local function write_fguid(gv, hex)
    hex = norm_guid_hex(hex)
    if #hex ~= 32 then return false, "bad hex len " .. #hex end
    local vals = {}
    for k = 0, 3 do
        local v = tonumber(hex:sub(k * 8 + 1, k * 8 + 8), 16)
        if not v then return false, "hex parse failed" end
        vals[k + 1] = v
    end
    local fields = { "A", "B", "C", "D" }
    for k = 1, 4 do
        local v = vals[k]
        local ok = pcall(function() gv[fields[k]] = v end)
        if not ok and v >= 0x80000000 then
            -- Retry as signed int32 in case the binding rejects large unsigned.
            ok = pcall(function() gv[fields[k]] = v - 0x100000000 end)
        end
        if not ok then return false, "assign " .. fields[k] .. " failed" end
    end
    local back = norm_guid_hex(read_fguid(gv))
    return back == hex, "read-back=" .. back
end

-- ---------------------------------------------------------------------------
-- base64url (engine save format) helpers
-- The game's PersonalInventory JSON stores GUID and ItemData as unpadded
-- URL-safe base64 of 16 raw bytes (e.g. "aQlAB0Shj4Jxzvef5ZTF-w").
-- ---------------------------------------------------------------------------
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local B64_LOOKUP = {}
for idx = 1, #B64_CHARS do B64_LOOKUP[B64_CHARS:sub(idx, idx)] = idx - 1 end

local function b64url_decode(s)
    if type(s) ~= "string" then return nil end
    local bits, acc, nbits = {}, 0, 0
    for ch in s:gmatch(".") do
        local v = B64_LOOKUP[ch]
        if v == nil then return nil end
        acc = (acc << 6) | v
        nbits = nbits + 6
        if nbits >= 8 then
            nbits = nbits - 8
            bits[#bits + 1] = string.char((acc >> nbits) & 0xFF)
        end
    end
    return table.concat(bits)
end

local function b64url_encode(bytes)
    local out, acc, nbits = {}, 0, 0
    for ch in bytes:gmatch(".") do
        acc = (acc << 8) | ch:byte()
        nbits = nbits + 8
        while nbits >= 6 do
            nbits = nbits - 6
            out[#out + 1] = B64_CHARS:sub(((acc >> nbits) & 0x3F) + 1, ((acc >> nbits) & 0x3F) + 1)
        end
    end
    if nbits > 0 then
        out[#out + 1] = B64_CHARS:sub(((acc << (6 - nbits)) & 0x3F) + 1, ((acc << (6 - nbits)) & 0x3F) + 1)
    end
    return table.concat(out)
end

-- Diagnostic: render a b64url 16-byte GUID as hex two ways so we can match it
-- against read_fguid output offline (byte order unknown until confirmed).
local function b64_guid_hex_views(s)
    local raw = b64url_decode(s)
    if not raw or #raw ~= 16 then return "decode-failed(len=" .. tostring(raw and #raw) .. ")" end
    local straight = (raw:gsub(".", function(c) return string.format("%02X", c:byte()) end))
    -- LE-uint32 view: reverse bytes within each 4-byte group (FGuid A,B,C,D as little-endian).
    local le_parts = {}
    for g = 0, 3 do
        local grp = raw:sub(g * 4 + 1, g * 4 + 4)
        le_parts[#le_parts + 1] = (grp:reverse():gsub(".", function(c) return string.format("%02X", c:byte()) end))
    end
    return "raw=" .. straight .. " le32=" .. table.concat(le_parts)
end

-- Convert a 32-hex FGuid string to the engine save format (unpadded base64url
-- of the same 16 bytes). CONFIRMED: live hex GUIDs match CharacterSave b64
-- values byte-for-byte with no swizzle.
local function guid_hex_to_b64(hex)
    hex = norm_guid_hex(hex)
    if #hex ~= 32 then return nil end
    local bytes = (hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
    return b64url_encode(bytes)
end

-- Sidecar file holding slot-index → asset path, written alongside the main
-- save. The engine ignores it; we use it to resolve assets for the fallback
-- restore path (engine format stores only PersistenceIDs).
local function paths_path(guid)
    return json_path(guid):gsub("%.json$", "_paths.json")
end

-- Resolve an item asset by its PersistenceID (b64 string) by scanning loaded
-- item data assets. Only finds assets already in memory.
local ITEMDATA_CLASSES = {
    "ItemData", "HeldEquipmentData", "HeldContainerEquipmentData",
    "HarvestToolEquipmentData", "EquipmentData",
    -- Container fill contents (compost, water, ...) — resolved for the
    -- ContentItemData attribute of buckets / watering cans.
    "ContainerContentDataAsset",
}
local function find_item_by_persistence_id(pid)
    if not pid or pid == "" then return nil end
    for _, cls in ipairs(ITEMDATA_CLASSES) do
        local ok_all, objs = pcall(FindAllOf, cls)
        if ok_all and objs then
            for _, o in ipairs(objs) do
                local ok_pid, pv = pcall(function() return o:GetPropertyValue("PersistenceID") end)
                if ok_pid and pv ~= nil then
                    local s = ""
                    if type(pv) == "string" then s = pv
                    else pcall(function() s = tostring(pv:ToString()) end) end
                    if s == pid then return o end
                end
            end
        end
    end
    return nil
end

-- Accept either a 32-hex or base64url GUID string; return 32-hex (or nil).
local function guid_any_to_hex(s)
    if type(s) ~= "string" then return nil end
    local n = norm_guid_hex(s)
    if #n == 32 and n:match("^[0-9A-F]+$") then return n end
    local raw = b64url_decode(s)
    if raw and #raw == 16 then
        return (raw:gsub(".", function(c) return string.format("%02X", c:byte()) end))
    end
    return nil
end

-- Find a UFunction by name on a class (walking the super chain).
-- NOTE: StaticFindObject does NOT resolve "Class:Function" paths in this build
-- (run-6: all reflections failed) — but ForEachFunction on the class works.
local function find_ufunction(cls, fname)
    local target = nil
    local depth = 0
    local last_err = nil
    while cls and depth < 6 do
        local ok_fe, fe_err = pcall(function()
            cls:ForEachFunction(function(fn)
                local n = ""
                pcall(function() n = fn:GetFName():ToString() end)
                if n == fname then
                    target = fn
                end
            end)
        end)
        if not ok_fe then last_err = fe_err end
        if target then return target end
        local ok_su, su = pcall(function() return cls:GetSuperStruct() end)
        if not (ok_su and su) then break end
        cls = su
        depth = depth + 1
    end
    return nil, last_err
end

-- Reflect a UFunction's parameter list: { {name=..., type=...}, ... }.
-- UFunction params (incl. out/return) are properties on the function object.
local UFN_PARAM_CACHE = {}  -- successes only — a failure in one context (e.g.
                            -- StaticFindObject class wrapper) must not poison
                            -- later attempts with a real instance class.
local function get_ufunction_params(cls, fname)
    if UFN_PARAM_CACHE[fname] then return UFN_PARAM_CACHE[fname] end
    local fn, find_err = find_ufunction(cls, fname)
    if not fn then
        log("reflect: " .. fname .. " not found"
            .. (find_err and (" (ForEachFunction err: " .. tostring(find_err):sub(-80) .. ")") or ""))
        return nil
    end
    local params = {}
    local ok_fe, fe_err = pcall(function()
        fn:ForEachProperty(function(prop)
            local nm, ty = "?", "?"
            pcall(function() nm = prop:GetFName():ToString() end)
            pcall(function() ty = prop:GetClass():GetFName():ToString() end)
            params[#params + 1] = { name = nm, type = ty }
        end)
    end)
    if not ok_fe then
        log("reflect: " .. fname .. " ForEachProperty err: " .. tostring(fe_err):sub(1, 200))
        return nil
    end
    UFN_PARAM_CACHE[fname] = params
    return params
end

-- Call an InventoryComponent add-function with auto-built args based on the
-- reflected parameter list. Heuristics: ObjectProperty→item asset,
-- "slot"→slot index, "count"/"num"/"amount"→count, StructProperty→FGuid table,
-- BoolProperty→true, everything else→zero values. ReturnValue is skipped.
local function call_inventory_fn(comp, fname, item_obj, slot_idx, count, guid_hex)
    local ok_cls, cls = pcall(function() return comp:GetClass() end)
    if not ok_cls or not cls then return false, "GetClass failed" end
    local params = get_ufunction_params(cls, fname)
    if not params then return false, "reflection unavailable" end
    local args, desc = {}, {}
    for _, p in ipairs(params) do
        local n = p.name:lower()
        if n ~= "returnvalue" then
            local t, v = p.type, nil
            if t:find("ObjectProperty") then v = item_obj
            elseif n:find("slot") or n:find("index") then v = slot_idx
            elseif n:find("count") or n:find("num") or n:find("amount") or n:find("quantity") then v = count
            elseif t == "IntProperty" or t:find("Int") then v = count
            elseif t == "BoolProperty" then v = true
            elseif t == "StructProperty" then
                if guid_hex and #guid_hex == 32 then
                    v = {
                        A = tonumber(guid_hex:sub(1, 8), 16),
                        B = tonumber(guid_hex:sub(9, 16), 16),
                        C = tonumber(guid_hex:sub(17, 24), 16),
                        D = tonumber(guid_hex:sub(25, 32), 16),
                    }
                else
                    v = {}
                end
            elseif t:find("Float") or t:find("Double") then v = 0.0
            elseif t:find("Str") or t:find("Name") or t:find("Text") then v = ""
            else v = 0 end
            args[#args + 1] = v
            desc[#desc + 1] = p.name .. "(" .. t .. ")=" .. tostring(v):sub(1, 24)
        end
    end
    log("call: " .. fname .. " args: " .. table.concat(desc, ", "))
    local ok_call, ret = pcall(function()
        return comp[fname](comp, table.unpack(args))
    end)
    return ok_call, ret
end

-- Class check for container items (buckets, watering cans). Property-presence
-- probing is unreliable (nonexistent properties return garbage userdata), so
-- gate container handling on IsA instead.
local _container_item_class = nil
local function is_container_item(obj)
    if _container_item_class == nil then
        local ok_c, c = pcall(StaticFindObject, "/Script/Dominion.HeldContainerEquipmentItem")
        _container_item_class = (ok_c and c and c:IsValid()) and c or false
    end
    if not _container_item_class then return false end
    local res = false
    pcall(function() res = obj:IsA(_container_item_class) end)
    return res == true
end

-- Read an asset's PersistenceID as the b64 string the save format expects.
local function get_persistence_id(asset)
    local ok_pid, pv = pcall(function() return asset:GetPropertyValue("PersistenceID") end)
    if not ok_pid or pv == nil then return "" end
    if type(pv) == "string" then return pv end
    local s = ""
    pcall(function() s = tostring(pv:ToString()) end)
    return s
end

-- ---------------------------------------------------------------------------
-- Content-attribute cache
-- Container content TYPES can't be read off live items (the ObjectProperty-in-
-- struct read hard-crashes UE4SS) and the persistence mirror fields are stale.
-- Instead we harvest GUID → ContentItemData pairs from the game's OWN character
-- save JSON (handed to us by the Server_ReceiveLoadFromDisk hook) and persist
-- them in a cache file across sessions.
-- ---------------------------------------------------------------------------
local ContentAttrCache  = {}   -- item GUID (b64) → { ContentItemData=..., RemainingFillCharges=... }
local _attr_cache_loaded = false

local function attrs_cache_path()
    return get_save_dir() .. MOD_NAME .. "_ContentAttrs.json"
end

local function load_attr_cache()
    if _attr_cache_loaded then return end
    _attr_cache_loaded = true
    local f = io.open(attrs_cache_path(), "r")
    if not f then return end
    local c = f:read("*a")
    f:close()
    local ok, t = pcall(json.decode, c)
    if ok and type(t) == "table" then
        ContentAttrCache = t
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        log("Content-attr cache loaded (" .. n .. " entries).")
    end
end

local function save_attr_cache()
    local parts = {}
    for g, a in pairs(ContentAttrCache) do
        if type(a) == "table" and a.ContentItemData then
            parts[#parts + 1] = string.format(
                '%s"%s":{"ContentItemData":"%s"%s}',
                (#parts > 0 and "," or ""), g, tostring(a.ContentItemData),
                a.RemainingFillCharges
                    and (',"RemainingFillCharges":' .. tostring(a.RemainingFillCharges)) or "")
        end
    end
    local f = io.open(attrs_cache_path(), "w")
    if f then
        f:write("{" .. table.concat(parts) .. "}")
        f:close()
    end
end

-- Mine an engine character-save JSON string for content attributes.
local function harvest_content_attrs(content_json)
    load_attr_cache()
    local ok, t = pcall(json.decode, content_json)
    if not ok or type(t) ~= "table" then
        log("harvest: could not parse character save JSON: " .. tostring(t):sub(1, 80))
        return
    end
    local found = 0
    for _, v in pairs(t) do
        if type(v) == "table" then
            for k2, entry in pairs(v) do
                if tonumber(k2) and type(entry) == "table"
                   and entry.GUID and entry.ContentItemData then
                    ContentAttrCache[entry.GUID] = {
                        ContentItemData = entry.ContentItemData,
                        RemainingFillCharges = entry.RemainingFillCharges,
                    }
                    found = found + 1
                end
            end
        end
    end
    if found > 0 then
        save_attr_cache()
        log("harvest: cached content attrs for " .. found .. " item(s) from engine save.")
    end
end

-- Read the game's character save straight from disk (the load-RPC hook fires
-- before our hooks register, so it can't be relied on for the first load).
-- Add the correct path here if the default guesses miss.
local CHARACTER_SAVE_PATHS = {
    (os.getenv("LOCALAPPDATA") or "") .. "\\RSDragonwilds\\Saved\\SaveGames\\CharacterSave.json",
    (os.getenv("LOCALAPPDATA") or "") .. "\\RSDragonwilds\\Saved\\CharacterSave.json",
}
local function harvest_from_disk()
    for _, p in ipairs(CHARACTER_SAVE_PATHS) do
        local f = io.open(p, "r")
        if f then
            local c = f:read("*a")
            f:close()
            if c and #c > 2 then
                log("harvest: reading character save from disk: " .. p)
                pcall(harvest_content_attrs, c)
                return true
            end
        end
    end
    log("harvest: no character save found on disk — content-type cache may be stale.")
    return false
end

-- ---------------------------------------------------------------------------
-- Force-JSON helpers — try calling component functions that might serialize
-- ItemSlots back into JsonInventory (the way the game's own save path does).
-- ---------------------------------------------------------------------------
local FORCE_JSON_FNS = {
    "UpdateJsonInventory", "RefreshJsonInventory", "GenerateJsonInventory",
    "SerializeToJson",     "BuildJsonInventory",   "WriteInventoryJson",
    "SyncJsonInventory",   "PackInventory",        "InvalidateJson",
    "ForceJsonUpdate",     "SaveInventoryToJson",  "CommitInventory",
}
local function try_force_json(inv_comp)
    for _, fn in ipairs(FORCE_JSON_FNS) do
        pcall(function() inv_comp[fn](inv_comp) end)
    end
    -- Check if JsonInventory now has real item data.
    local ok_j, j_str = pcall(function()
        return inv_comp:GetPropertyValue("JsonInventory"):ToString()
    end)
    if ok_j and j_str and #j_str > 200
       and j_str ~= EMPTY_INV_JSON and j_str ~= SLOT_LAYOUT_JSON then
        log("force_json: got item data! len=" .. #j_str .. "  preview=" .. j_str:sub(1,80))
        return j_str
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Slot-level probe (runs once per session after items might be present)
-- ---------------------------------------------------------------------------
local _probe_cast = 0
local _dumped_item_props = false  -- one-shot full property dump of an ItemData asset
local _dumped_comp_fns   = false  -- one-shot UFunction dump of PersonalInventoryComponent
local _dumped_fparams    = false  -- one-shot add-function signature dump (live class)
local function probe_slot(sv, label)
    -- GetPropertyValue pass: try reading each known field name.
    local names = { "GUID", "ItemData", "Count", "ItemId", "ItemClass",
                    "ItemType", "ItemName", "Item", "Data", "InstanceId",
                    "UniqueId", "Amount", "Index", "RowHandle" }
    local findings = {}
    for _, n in ipairs(names) do
        local ok_gp, gv = pcall(function() return sv:GetPropertyValue(n) end)
        if ok_gp and gv ~= nil then
            local preview = type(gv)
            local ok_ts, ts = pcall(function() return gv:ToString() end)
            if ok_ts and ts and ts ~= "" then preview = ts:sub(1,30)
            else
                local ok_a, a = pcall(function() return gv.A end)
                if ok_a and tonumber(a) then
                    local ok_b, b = pcall(function() return gv.B end)
                    local ok_c, c = pcall(function() return gv.C end)
                    local ok_d, d = pcall(function() return gv.D end)
                    preview = string.format("FGuid(%s,%s,%s,%s)",
                        tostring(a),tostring(b),tostring(c),tostring(d))
                end
            end
            findings[#findings+1] = n .. "=" .. preview
        end
    end
    log(label .. " GetPropertyValue: " .. (#findings > 0 and table.concat(findings, " | ") or "nothing"))

    -- Direct dot-notation pass (may use a different __index path than GetPropertyValue).
    local dot_findings = {}
    for _, n in ipairs(names) do
        local ok_dn, dv = pcall(function() return sv[n] end)
        if ok_dn and dv ~= nil then
            local t = type(dv)
            local val = t ~= "userdata" and tostring(dv) or "userdata"
            if t == "userdata" then
                local ok_ts, ts = pcall(function() return dv:ToString() end)
                if ok_ts and ts and ts ~= "" then val = ts:sub(1,30) end
            end
            dot_findings[#dot_findings+1] = n .. "=" .. val
        end
    end
    log(label .. " dot-notation:     " .. (#dot_findings > 0 and table.concat(dot_findings, " | ") or "nothing"))

    -- Deep probe on ItemData: try UObject methods (IsValid, GetPathName, GetClass).
    -- tostring() returns "UObject: 0x..." for both empty and occupied slots because
    -- UE4SS wraps FItemSlot sub-field accesses in dummy Lua objects.  We need to check
    -- whether this "UObject" is actually valid and points to a real asset.
    local ok_id, id_udata = pcall(function() return sv:GetPropertyValue("ItemData") end)
    if ok_id and id_udata ~= nil and type(id_udata) == "userdata" then
        local ok_iv, is_v = pcall(function() return id_udata:IsValid() end)
        log(label .. " ItemData:IsValid() = " .. (ok_iv and tostring(is_v) or "(error)"))
        if ok_iv and is_v then
            local ok_pn, pn = pcall(function() return id_udata:GetPathName() end)
            log(label .. " ItemData:GetPathName() = " .. (ok_pn and tostring(pn) or "(error)"))
            local ok_cls, cls = pcall(function()
                return id_udata:GetClass():GetName()
            end)
            log(label .. " ItemData:GetClass():GetName() = " .. (ok_cls and tostring(cls) or "(error)"))
        end
        log(label .. " tostring(ItemData) = " .. tostring(id_udata))
    end
end

-- ---------------------------------------------------------------------------
-- Main serializer
-- ---------------------------------------------------------------------------
local function serialize_item_slots(inv_comp)
    -- The LIVE ItemSlots array is the ONLY source of truth. Never read
    -- JsonInventory here — we write that property ourselves at cast time, so
    -- it's a stale snapshot (run-12 bug: saves captured the chest as it was
    -- when opened, losing every change made after).
    local ok_s, sv = pcall(function()
        return inv_comp:GetPropertyValue("ItemSlots")
    end)
    if not ok_s or sv == nil then
        log("serialize: ItemSlots read failed")
        return nil
    end

    -- 2. Probe a few slots with detailed field inspection.
    -- DISABLED: served its purpose during format discovery; pure log noise now.
    local PROBES_ENABLED = false
    _probe_cast = _probe_cast + 1
    if PROBES_ENABLED and _probe_cast <= 5 then
        local ok_1, s1 = pcall(function() return sv[1] end)
        if ok_1 and s1 then probe_slot(s1, "probe sv[1]") end
        -- Also probe index 2 in case slot 1 is our seeded empty entry.
        local ok_2, s2 = pcall(function() return sv[2] end)
        if ok_2 and s2 then probe_slot(s2, "probe sv[2]") end
    end

    -- 3. Walk ItemSlots and build JSON from any occupied (non-zero GUID) slots.
    local parts         = { '{"Version":67' }
    local sidecar_parts = {}  -- slot idx → asset path (fallback-restore sidecar)
    local max_idx       = -1

    for i = 1, SECOND_INV_SLOTS do
        local ok_slot, slot = pcall(function() return sv[i] end)
        if not ok_slot or slot == nil then
            log("serialize: sv[" .. i .. "] unavailable — stopping.")
            break
        end

        -- GUID: try GetPropertyValue, then sub-fields A/B/C/D.
        local guid_str = ""
        local ok_g, gv = pcall(function() return slot:GetPropertyValue("GUID") end)
        if ok_g and gv ~= nil then guid_str = read_fguid(gv) end

        if guid_str == "" or guid_str == EMPTY_GUID then goto continue end

        -- Deep probe this occupied slot's ItemData with exhaustive method + field sweep.
        -- DISABLED: discovery-era diagnostic, pure log noise now.
        if PROBES_ENABLED and _probe_cast <= 5 then
            local ok_dp, dp = pcall(function() return slot:GetPropertyValue("ItemData") end)
            if ok_dp and dp ~= nil then
                log("=== ItemData sweep for occupied slot " .. (i-1) .. " ===")
                -- Method sweep
                local methods = {
                    "ToString",          "GetFName",           "GetName",
                    "GetPath",           "GetAssetPathString", "GetLongPackageName",
                    "GetAssetName",      "GetPackageName",     "IsNull",
                    "GetTagName",        "GetTagValue",        "GetValue",
                    "GetCurrentTag",     "GetRowName",         "GetType",
                    "GetItemId",         "GetShortDescription","GetDescription",
                    "ToSoftObjectPath",  "GetSoftObjectPath",  "GetStringValue",
                }
                for _, m in ipairs(methods) do
                    local ok_m, v = pcall(function()
                        local fn = dp[m]
                        if type(fn) == "function" then return fn(dp) end
                        return fn
                    end)
                    if ok_m and v ~= nil then
                        local vt = type(v)
                        local vs = vt ~= "userdata" and tostring(v) or "userdata"
                        if vt == "userdata" then
                            local ok_ts2, ts2 = pcall(function() return v:ToString() end)
                            if ok_ts2 and ts2 and ts2 ~= "" then vs = "[" .. ts2 .. "]" end
                        end
                        if vs ~= "" and vs ~= "nil" and vs ~= "false" then
                            log("  ItemData." .. m .. "() [" .. vt .. "] = " .. vs)
                        end
                    end
                end
                -- Sub-field (direct index) sweep
                local fields = {
                    "AssetPath",    "SubPathString", "PackageName",  "AssetName",
                    "ObjectPath",   "RowName",       "DataTable",    "Tag",
                    "TagName",      "Type",          "Name",         "Id",
                    "Handle",       "Key",           "Path",         "Class",
                    "SoftPath",     "SoftClass",     "ItemHandle",   "Definition",
                }
                for _, f in ipairs(fields) do
                    local ok_f, v = pcall(function() return dp[f] end)
                    if ok_f and v ~= nil then
                        local vt = type(v)
                        local vs = vt ~= "userdata" and tostring(v) or "userdata"
                        if vt == "userdata" then
                            local ok_ts2, ts2 = pcall(function() return v:ToString() end)
                            if ok_ts2 and ts2 and ts2 ~= "" then vs = "[" .. ts2 .. "]" end
                        end
                        log("  ItemData['" .. f .. "'] [" .. vt .. "] = " .. vs)
                    end
                end
                -- GetFName confirmed working; GetFullName() confirmed to return full asset path.
                -- GetOuter() loop REMOVED — it traverses invalid memory and crashes the game.
                local ok_fn2, fn2 = pcall(function() return dp:GetFName() end)
                if ok_fn2 and fn2 then
                    local ok_ts2, ts2 = pcall(function() return fn2:ToString() end)
                    if ok_ts2 and ts2 and ts2 ~= "" then
                        log("  ItemData.GetFName() = " .. ts2)
                    end
                end

                -- GetFullName() returns "ClassName /Full/Path.ObjectName" — log the full string.
                local ok_gfn, gfn = pcall(function() return dp:GetFullName() end)
                if ok_gfn and gfn and gfn ~= "" then
                    log("  ItemData.GetFullName() = " .. tostring(gfn))
                    local path_part = gfn:match("^%S+%s+(.+)$")
                    if path_part then
                        log("  ItemData parsed path = " .. path_part)
                    end
                end
            end
        end

        -- ItemData: primary path is GetFullName() → parse the asset path component.
        -- GetFullName() returns "ClassName /Game/Full/Path.ObjectName" — split on first
        -- space to get "/Game/Full/Path.ObjectName", which the engine accepts as a soft
        -- object reference and uses to restore items across sessions.
        -- Fallback: GetFName():ToString() → short name only (items won't restore on reload).
        local item_data_str = ""
        local ok_d, dv = pcall(function() return slot:GetPropertyValue("ItemData") end)
        if ok_d and dv ~= nil then
            if type(dv) == "string" then
                item_data_str = dv
            else
                -- Primary: GetFullName() → parse full asset path
                local ok_gfn, gfn = pcall(function() return dv:GetFullName() end)
                if ok_gfn and gfn and gfn ~= "" then
                    local path_part = gfn:match("^%S+%s+(.+)$")
                    if path_part and path_part ~= "" then
                        item_data_str = path_part
                        log("serialize: ItemData (full path) = " .. path_part)
                    end
                end
                -- Fallback: GetFName():ToString() → short row name
                if item_data_str == "" then
                    local ok_fn, fn = pcall(function() return dv:GetFName() end)
                    if ok_fn and fn ~= nil then
                        local ok_ts, ts = pcall(function() return fn:ToString() end)
                        if ok_ts and ts and ts ~= "" and ts ~= "None" then
                            item_data_str = ts
                            log("serialize: ItemData (fallback FName) = " .. ts)
                        end
                    end
                end
            end
        end

        -- Count: returns a real Lua number for occupied slots (confirmed on cast 2).
        -- Empty slots return garbage userdata, but we only reach this code for non-empty
        -- slots (non-zero GUID), so GetPropertyValue should give us the real int32 value.
        local count_val = 1
        local ok_c, cv = pcall(function() return slot:GetPropertyValue("Count") end)
        if ok_c and cv ~= nil then
            local n = tonumber(cv)
            if n then count_val = n end
        end
        if count_val == 1 then  -- dot-notation fallback
            local ok_dn, dn = pcall(function() return slot.Count end)
            if ok_dn and dn ~= nil then
                local n = tonumber(dn)
                if n then count_val = n end
            end
        end

        -- PersistenceID: the b64 GUID string the engine's save format uses for
        -- ItemData (property on DominionDataAsset, base of all item assets).
        -- Fallback: the UItem's own ItemDataPersistenceId FString (per CXX dump,
        -- each slot entry IS a UItem object carrying a copy of the id).
        local persist_id = ""
        if ok_d and dv ~= nil and type(dv) ~= "string" then
            persist_id = get_persistence_id(dv)
        end
        if persist_id == "" then
            local ok_pid2, pid2 = pcall(function()
                return slot:GetPropertyValue("ItemDataPersistenceId")
            end)
            if ok_pid2 and pid2 ~= nil then
                if type(pid2) == "string" then persist_id = pid2
                else pcall(function() persist_id = tostring(pid2:ToString()) end) end
            end
        end

        -- Durability: saved only for items that actually have durability
        -- (ItemData.BaseDurability > 0), mirroring the engine save format.
        local durability_part = ""
        if ok_d and dv ~= nil and type(dv) ~= "string" then
            local ok_bd, bd = pcall(function()
                return tonumber(dv:GetPropertyValue("BaseDurability"))
            end)
            if ok_bd and bd and bd > 0 then
                local ok_du, du = pcall(function()
                    return tonumber(slot:GetPropertyValue("Durability"))
                end)
                if ok_du and du and du >= 0 then
                    durability_part = string.format(',"Durability":%d', du)
                end
            end
        end

        -- Extra attributes, mirroring the engine save format:
        -- VitalShield (UEquipment.CurrentVitalShield), and container contents
        -- (UHeldContainerEquipmentItem.Contents → RemainingFillCharges +
        -- ContentItemData). Properties absent on other item classes simply
        -- fail the pcall reads and are skipped.
        -- NOTE on crash safety (run-14): pcall does NOT catch native access
        -- violations. Reading the live Contents struct proxy crashed the game
        -- when a container was in the chest, so: read the plain mirror fields
        -- (FString/int32 — safe property types) FIRST, and only touch the live
        -- struct when the mirrors yield nothing. Breadcrumb logs (flushed per
        -- line) bracket each read so any future crash pinpoints the access.
        local extra_parts = ""
        write_mod_log("serialize: extras begin slot " .. (i - 1))
        local ok_vs, vs = pcall(function()
            return tonumber(slot:GetPropertyValue("CurrentVitalShield"))
        end)
        if ok_vs and vs then
            extra_parts = extra_parts .. string.format(',"VitalShield":%g', vs)
        end
        write_mod_log("serialize: extras vitalshield done")

        local content_pid, content_qty = "", nil
        if is_container_item(slot) then
            -- Quantity: LIVE struct POD read — struct-proxy POD reads are safe
            -- (every FGuid read proves it). NEVER read ContentData (object ptr)
            -- from the struct proxy: that exact access hard-crashes UE4SS
            -- (run-15 dump: AV at 0xFFFFFFFFFFFFFFFF inside UE4SS.dll).
            write_mod_log("serialize: extras live Quantity read begin")
            local ok_ct, ct = pcall(function() return slot:GetPropertyValue("Contents") end)
            if ok_ct and ct ~= nil then
                local ok_q, q = pcall(function() return tonumber(ct:GetPropertyValue("Quantity")) end)
                if ok_q and q then content_qty = q end
            end
            write_mod_log("serialize: extras live Quantity done (" .. tostring(content_qty) .. ")")
            -- Mirror fallback for quantity (plain int property).
            if not content_qty then
                local ok_qp, qp = pcall(function()
                    return tonumber(slot:GetPropertyValue("Quantity_Persistence"))
                end)
                if ok_qp and qp then content_qty = qp end
            end

            -- Content TYPE: mirror string first (plain FString property)...
            local ok_cp, cp = pcall(function() return slot:GetPropertyValue("ContentPersistenceID") end)
            if ok_cp and cp ~= nil then
                if type(cp) == "string" then content_pid = cp
                else pcall(function() content_pid = tostring(cp:ToString()) end) end
                if content_pid == "None" then content_pid = "" end
            end
            write_mod_log("serialize: extras mirror pid done (" .. tostring(content_pid) .. ")")
            -- ...then the harvested attr cache (engine save data, keyed by the
            -- item's instance GUID — same GUID in both inventories)...
            if content_pid == "" then
                load_attr_cache()
                local b64g = guid_hex_to_b64(guid_str)
                local cached = b64g and ContentAttrCache[b64g]
                if cached and cached.ContentItemData then
                    content_pid = tostring(cached.ContentItemData)
                    log("serialize: content type from attr cache: " .. content_pid)
                end
            end
            -- ...then infer from the asset's AllowedFillTypes when unambiguous
            -- (TArray object-element access is safe — ItemSlots proves it).
            if content_pid == "" and content_qty and content_qty > 0
               and ok_d and dv ~= nil and type(dv) ~= "string" then
                write_mod_log("serialize: extras AllowedFillTypes inference begin")
                local ok_af, af = pcall(function() return dv:GetPropertyValue("AllowedFillTypes") end)
                if ok_af and af ~= nil then
                    local first, n_valid = nil, 0
                    for k = 1, 8 do
                        local ok_e, e = pcall(function() return af[k] end)
                        if not (ok_e and e ~= nil) then break end
                        local ok_iv, iv = pcall(function() return e:IsValid() end)
                        if ok_iv and iv then
                            n_valid = n_valid + 1
                            if not first then first = e end
                        end
                    end
                    if n_valid == 1 and first then
                        content_pid = get_persistence_id(first)
                        log("serialize: content type inferred from AllowedFillTypes: " .. content_pid)
                    elseif n_valid > 1 then
                        log_err("serialize: container content type ambiguous ("
                            .. n_valid .. " allowed types) — type not saved, quantity kept.")
                    end
                end
                write_mod_log("serialize: extras AllowedFillTypes inference done")
            end
        end
        write_mod_log("serialize: extras done slot " .. (i - 1))
        -- PAIRED OR NOTHING: the engine applies these from JsonInventory when
        -- the item lands in a slot — charges with no content type renders a
        -- broken fill bar and crashes the UI (runs 16/17). Never emit one
        -- without the other.
        if content_qty and content_qty > 0 and content_pid ~= "" and content_pid ~= "None" then
            extra_parts = extra_parts
                .. string.format(',"RemainingFillCharges":%d', content_qty)
                .. string.format(',"ContentItemData":"%s"', content_pid)
        elseif content_qty and content_qty > 0 then
            log_err("serialize: container has " .. content_qty
                .. " charges but unknown content type — contents NOT saved (will restore empty).")
        end

        local json_idx = i - 1
        -- ENGINE FORMAT: GUID as b64url, ItemData as PersistenceID. Falls back
        -- to legacy hex/path when conversion isn't possible (restore handles both).
        local b64_guid = guid_hex_to_b64(guid_str)
        parts[#parts + 1] = string.format(
            ',"%d":{"GUID":"%s","ItemData":"%s","Count":%d%s%s}',
            json_idx,
            b64_guid or guid_str,
            (persist_id ~= "" and persist_id or item_data_str):gsub('"', '\\"'),
            count_val,
            durability_part,
            extra_parts)
        if item_data_str ~= "" then
            sidecar_parts[#sidecar_parts + 1] = string.format(
                '%s"%d":"%s"', (#sidecar_parts > 0 and "," or ""),
                json_idx, item_data_str:gsub('"', '\\"'))
        end
        max_idx = json_idx
        log(string.format("serialize: slot %d  GUID=%s  PID=%s  Count=%d",
            json_idx, tostring(b64_guid or guid_str:sub(1, 16)),
            persist_id ~= "" and persist_id or "(path)", count_val))

        ::continue::
    end

    if max_idx < 0 then
        -- Empty is an AUTHORITATIVE state (user may have removed everything) —
        -- return a valid empty engine-format save, not nil, so it gets written.
        log("serialize: no items — emitting empty inventory JSON.")
        return '{"Version":67,"MaxSlotIndex":' .. (SECOND_INV_SLOTS - 1) .. '}', "{}"
    end

    -- Mirror the engine's PersonalInventory format exactly (no AllowAdds).
    parts[#parts + 1] = string.format(',"MaxSlotIndex":%d}', SECOND_INV_SLOTS - 1)
    local result = table.concat(parts)
    local sidecar_json = "{" .. table.concat(sidecar_parts) .. "}"
    log("serialize: built JSON (" .. #result .. " bytes, engine format).")
    return result, sidecar_json
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

    local to_write = nil
    local sidecar_json = nil

    -- Serialize the LIVE ItemSlots — the only source of truth. No JsonInventory
    -- or cached fallbacks: both are stale snapshots and caused run-12's lost
    -- changes (and would dupe items back after the user empties the chest).
    to_write, sidecar_json = serialize_item_slots(inv_comp)

    if not to_write then
        -- ItemSlots unreadable (error, not "empty") — leave the existing file
        -- untouched rather than risk writing bad state.
        log_err("save: ItemSlots unreadable — existing save left untouched for GUID " .. guid)
        return nil
    end

    -- Preserve unrestored slots: merge them into the outgoing JSON so items
    -- that failed to restore this session are never dropped from the save.
    local failed = FailedRestoreSlots[guid]
    if failed and next(failed) then
        for key, rec in pairs(failed) do
            if to_write:find('"' .. key .. '":', 1, true) then
                log_err("save: slot " .. key .. " has live data AND an unrestored item — keeping live; dropped: "
                    .. tostring(rec.ItemData))
            else
                local frag = string.format(',"%s":{"GUID":"%s","ItemData":"%s","Count":%d',
                    key, tostring(rec.GUID), tostring(rec.ItemData):gsub('"', '\\"'),
                    tonumber(rec.Count) or 1)
                local dur = tonumber(rec.Durability)
                if dur then frag = frag .. string.format(',"Durability":%d', dur) end
                local vsh = tonumber(rec.VitalShield)
                if vsh then frag = frag .. string.format(',"VitalShield":%g', vsh) end
                -- Paired or nothing (see serializer note).
                local rfc = tonumber(rec.RemainingFillCharges)
                if rfc and rfc > 0 and rec.ContentItemData and rec.ContentItemData ~= "" then
                    frag = frag .. string.format(',"RemainingFillCharges":%d', rfc)
                    frag = frag .. string.format(',"ContentItemData":"%s"',
                        tostring(rec.ContentItemData):gsub('"', '\\"'))
                end
                frag = frag .. "}"
                local pos = to_write:find(',"MaxSlotIndex"', 1, true)
                if pos then
                    to_write = to_write:sub(1, pos - 1) .. frag .. to_write:sub(pos)
                    log("save: preserved unrestored slot " .. key .. " in save file.")
                else
                    log_err("save: could not splice unrestored slot " .. key .. " (no MaxSlotIndex anchor).")
                end
                -- Carry the asset path forward in the sidecar too.
                if rec.Path and rec.Path ~= "" then
                    local inner = (sidecar_json or "{}"):sub(2, -2)
                    local entry = string.format('"%s":"%s"', key, rec.Path:gsub('"', '\\"'))
                    sidecar_json = "{" .. (inner ~= "" and (inner .. ",") or "") .. entry .. "}"
                end
            end
        end
    end

    local path = json_path(guid)
    local file = io.open(path, "w")
    if not file then
        log_err("Could not open save file for writing: " .. path)
        return to_write
    end
    file:write(to_write)
    file:close()
    log("Saved inventory for GUID " .. guid .. " (" .. #to_write .. " bytes).")

    -- Sidecar: slot → asset path map for the fallback restore.
    if sidecar_json and sidecar_json ~= "{}" then
        local pf = io.open(paths_path(guid), "w")
        if pf then
            pf:write(sidecar_json)
            pf:close()
            log("Saved paths sidecar (" .. #sidecar_json .. " bytes).")
        end
    end
    return to_write
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

    -- Pre-allocate the ItemSlots TArray to SECOND_INV_SLOTS entries.
    -- Without this, the array starts at size 0. The first drag creates entry 0;
    -- all other visual slots are ghost slots that silently reject items.
    -- RegisterComponent/InitializeComponent/BeginPlay all fail as UFunctions in
    -- this UE4SS build ("UObject instance is nullptr"), so we try several paths.

    -- Attempt 1: ReceiveBeginPlay — the BlueprintImplementableEvent version of
    -- BeginPlay IS a UFUNCTION. If PersonalInventoryComponent has BP logic in its
    -- BeginPlay that calls ItemSlots.SetNum(MaxSlotCount), this will trigger it.
    local ok_rbp = pcall(function() second_inv:ReceiveBeginPlay() end)
    if ok_rbp then
        log("ReceiveBeginPlay() succeeded — ItemSlots should be pre-allocated.")
    else
        -- Attempt 2: SetPropertyValue("ItemSlots", ...) with an array of 40 empty
        -- tables. UE4SS may default-initialize each FItemSlot struct from the empty
        -- table, giving us 40 pre-allocated (empty) slot entries.
        local ok_pre = pcall(function()
            local slots = {}
            for i = 1, SECOND_INV_SLOTS do slots[i] = {} end
            second_inv:SetPropertyValue("ItemSlots", slots)
        end)
        if ok_pre then
            log("ItemSlots pre-allocated via SetPropertyValue (40 empty entries).")
        else
            -- Attempt 3: game-specific named functions.
            local named_fns = {
                { "InitInventory",       function() second_inv:InitInventory(SECOND_INV_SLOTS) end },
                { "InitializeInventory", function() second_inv:InitializeInventory(SECOND_INV_SLOTS) end },
                { "SetNumSlots",         function() second_inv:SetNumSlots(SECOND_INV_SLOTS) end },
                { "ResizeInventory",     function() second_inv:ResizeInventory(SECOND_INV_SLOTS) end },
                { "EnsureSlotCount",     function() second_inv:EnsureSlotCount(SECOND_INV_SLOTS) end },
                { "AddSlots",            function() second_inv:AddSlots(SECOND_INV_SLOTS) end },
                { "SetInventorySize",    function() second_inv:SetInventorySize(SECOND_INV_SLOTS) end },
            }
            local any_ok = false
            for _, entry in ipairs(named_fns) do
                local ok_fn = pcall(entry[2])
                if ok_fn then
                    log("Slot pre-alloc via " .. entry[1] .. "() succeeded!")
                    any_ok = true
                    break
                end
            end
            if not any_ok then
                log_err("All slot pre-alloc attempts failed. Only 1 slot will be usable until this is resolved.")
            end
        end
    end

    -- Diagnostic: read ItemSlots back to see what state the TArray is in.
    -- GetPropertyValue returns a TArray as userdata (not a Lua table), so #slots_val
    -- won't work — try the TArray:Num() method instead.
    local ok_diag, slots_val = pcall(function()
        return second_inv:GetPropertyValue("ItemSlots")
    end)
    if ok_diag and slots_val ~= nil then
        local slots_type = type(slots_val)
        local slots_count
        if slots_type == "table" then
            slots_count = tostring(#slots_val)
        else
            local ok_num, num = pcall(function() return slots_val:Num() end)
            slots_count = ok_num and tostring(num) or "? (Num() unavailable)"
        end
        log("ItemSlots after pre-alloc: type=" .. slots_type .. " count=" .. slots_count)
    else
        log("ItemSlots diagnostic: read failed or returned nil.")
    end

    -- Seed with empty 40-slot JSON and broadcast OnInventoryLoadedFromSave so the engine
    -- parses the 40 slot entries and pre-populates ItemSlots with 40 empty FItemSlot structs.
    -- This runs only here (fresh construction), never on reuse, so live items are never wiped.
    populate_inventory(second_inv, EMPTY_INV_JSON)
    log("Seeded empty 40-slot JSON — engine should pre-allocate ItemSlots via Broadcast().")

    -- Confirm ItemSlots count after seeding.
    local ok_diag2, slots_val2 = pcall(function()
        return second_inv:GetPropertyValue("ItemSlots")
    end)
    if ok_diag2 and slots_val2 ~= nil then
        local slots_type2 = type(slots_val2)
        local slots_count2
        if slots_type2 == "table" then
            slots_count2 = tostring(#slots_val2)
        else
            local ok_n2, n2 = pcall(function() return slots_val2:Num() end)
            slots_count2 = ok_n2 and tostring(n2) or "? (Num() unavailable)"
        end
        log("ItemSlots after seed: type=" .. slots_type2 .. " count=" .. slots_count2)
    end

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
-- Controller / GUID resolution helpers
-- -----------------------------------------------------------------------------

local function find_local_controller()
    local ok_all, all_ctrls = pcall(FindAllOf, "DominionPlayerController")
    if not ok_all or not all_ctrls then return nil end
    for _, c in ipairs(all_ctrls) do
        if c:IsValid() then
            local ok_l, is_l = pcall(function() return c:IsLocalController() end)
            if ok_l and is_l then return c end
        end
    end
    for _, c in ipairs(all_ctrls) do
        if c:IsValid() then return c end
    end
    return nil
end

local function resolve_character_guid(ctrl)
    local ok_guid, guid_struct = pcall(function() return ctrl:GetCharacterGuid() end)
    if not ok_guid or not guid_struct then return nil end
    local ok_ig, ig = pcall(function() return guid_struct.InnerGuid end)
    if not ok_ig or ig == nil then return nil end
    if type(ig) == "string" then
        return ig ~= "" and ig or nil
    end
    local ok_ts, ts = pcall(function() return ig:ToString() end)
    if ok_ts and ts and ts ~= "" then return ts end
    local ok_f, s = pcall(function()
        return string.format("%08X%08X%08X%08X", ig.A or 0, ig.B or 0, ig.C or 0, ig.D or 0)
    end)
    if ok_f and s and s ~= EMPTY_GUID then return s end
    return nil
end

-- -----------------------------------------------------------------------------
-- Restore: broadcast engine-format JSON, then engine-add any missing slots
-- -----------------------------------------------------------------------------

local function scan_occupied_slots(comp)
    local set, list = {}, {}
    local ok_sv, sv = pcall(function() return comp:GetPropertyValue("ItemSlots") end)
    if not (ok_sv and sv) then return set, list end
    for si = 1, SECOND_INV_SLOTS do
        local ok_ssl, ssl = pcall(function() return sv[si] end)
        if not (ok_ssl and ssl) then break end
        local ok_sg, sg = pcall(function() return ssl:GetPropertyValue("GUID") end)
        local shex = (ok_sg and sg) and norm_guid_hex(read_fguid(sg)) or ""
        if shex ~= "" and shex ~= EMPTY_GUID then
            set[si - 1] = true
            list[#list + 1] = si - 1
        end
    end
    return set, list
end

local function restore_inventory(guid, comp, restore_json)
    -- 1. Engine-native path: set JsonInventory + OnInventoryLoadedFromSave
    --    broadcast. With engine-format JSON (b64 GUIDs + PersistenceIDs) the
    --    engine should rebuild ItemSlots itself.
    populate_inventory(comp, restore_json)

    local occ_set, occ_list = scan_occupied_slots(comp)
    log("restore: occupied slots after broadcast = " .. #occ_list
        .. (#occ_list > 0 and (" [" .. table.concat(occ_list, ",") .. "]") or ""))

    local ok_dec, parsed = pcall(json.decode, restore_json)
    if not ok_dec then
        log_err("restore: json.decode failed: " .. tostring(parsed))
        parsed = nil
    end

    -- Paths sidecar (engine-format saves keep asset paths here).
    local sidecar = {}
    pcall(function()
        local pf = io.open(paths_path(guid), "r")
        if pf then
            local c = pf:read("*a")
            pf:close()
            local ok_p, p = pcall(json.decode, c)
            if ok_p and type(p) == "table" then sidecar = p end
        end
    end)

    -- Make sure adds aren't blocked (property is named bAllowAdds per the
    -- CXX header dump; set both spellings defensively).
    pcall(function() comp:SetPropertyValue("bAllowAdds", true) end)
    pcall(function() comp:SetPropertyValue("AllowAdds", true) end)

    -- 2. Fallback: any slot the engine didn't fill gets restored through the
    --    engine's own add functions.
    for key, slot_data in pairs(parsed or {}) do
        local idx = tonumber(key)
        if idx and type(slot_data) == "table"
           and slot_data.GUID and slot_data.GUID ~= "" then
            if occ_set[idx] then
                log("restore: slot " .. idx .. " already restored by engine.")
                goto next_slot
            end

            -- Resolve the item asset: legacy path in ItemData, sidecar path,
            -- or PersistenceID scan of loaded assets.
            local idat = tostring(slot_data.ItemData or "")
            local path = (idat:sub(1, 1) == "/") and idat or sidecar[key]
            local found = nil
            if path and path ~= "" then
                for _, tp in ipairs({ path, path .. "_C" }) do
                    local ok_fo, fo = pcall(StaticFindObject, tp)
                    if ok_fo and fo and fo:IsValid() then
                        found = fo
                        break
                    end
                end
                if not found then
                    pcall(function() LoadAsset(path) end)
                    local ok_fo, fo = pcall(StaticFindObject, path)
                    if ok_fo and fo and fo:IsValid() then found = fo end
                end
            end
            if not found and idat ~= "" and idat:sub(1, 1) ~= "/" then
                found = find_item_by_persistence_id(idat)
                if found then
                    log("restore: slot " .. idx .. " resolved via PersistenceID scan.")
                end
            end
            if not found then
                log_err("restore: slot " .. idx .. ": cannot resolve item ("
                    .. idat:sub(1, 60) .. ") — preserving in saves.")
                FailedRestoreSlots[guid] = FailedRestoreSlots[guid] or {}
                FailedRestoreSlots[guid][key] = {
                    GUID = slot_data.GUID, ItemData = slot_data.ItemData,
                    Count = slot_data.Count, Durability = slot_data.Durability,
                    VitalShield = slot_data.VitalShield,
                    RemainingFillCharges = slot_data.RemainingFillCharges,
                    ContentItemData = slot_data.ContentItemData,
                    Path = path,
                }
                goto next_slot
            end

            -- Engine-native add. EXACT signature from the CXX header dump:
            -- bool AddItemByDataToSlot(const UItemData* ItemData, int32 SlotIndex,
            --     int32 Count, float DurabilityPercentage,
            --     const FGameplayTagContainer& GameplayTags)
            -- The engine constructs a UItem and places it in ItemSlots[SlotIndex].
            local cnt = tonumber(slot_data.Count) or 1
            local ok_add, ret_add = pcall(function()
                return comp:AddItemByDataToSlot(found, idx, cnt, 100.0, {})
            end)
            log(string.format("restore: slot %d AddItemByDataToSlot ok=%s ret=%s",
                idx, tostring(ok_add), tostring(ret_add):sub(1, 160)))

            local now_set = scan_occupied_slots(comp)
            if not now_set[idx] then
                log_err("restore: slot " .. idx .. " still empty after add — preserving in saves.")
                FailedRestoreSlots[guid] = FailedRestoreSlots[guid] or {}
                FailedRestoreSlots[guid][key] = {
                    GUID = slot_data.GUID, ItemData = slot_data.ItemData,
                    Count = slot_data.Count, Durability = slot_data.Durability,
                    VitalShield = slot_data.VitalShield,
                    RemainingFillCharges = slot_data.RemainingFillCharges,
                    ContentItemData = slot_data.ContentItemData,
                    Path = path,
                }
                goto next_slot
            end
            log("restore: slot " .. idx .. " now occupied.")

            -- Post-fix the new UItem (a real UObject — property writes stick,
            -- unlike the FItemSlot-struct misunderstanding of earlier attempts):
            -- restore the original instance Guid and saved Durability.
            local ok_it, it = pcall(function() return comp:GetItemFromSlot(idx) end)
            if ok_it and it then
                local ghex = guid_any_to_hex(slot_data.GUID)
                if ghex then
                    local ok_g, gv = pcall(function() return it:GetPropertyValue("Guid") end)
                    if ok_g and gv then
                        local ok_wg, wg = write_fguid(gv, ghex)
                        log("restore: slot " .. idx .. " Guid write ok=" .. tostring(ok_wg)
                            .. " (" .. tostring(wg) .. ")")
                    end
                end
                local dur = tonumber(slot_data.Durability)
                if dur then
                    pcall(function() it:SetPropertyValue("Durability", dur) end)
                    pcall(function() it:OnRep_Durability() end)
                    log("restore: slot " .. idx .. " Durability set to " .. dur)
                end

                -- VitalShield (UEquipment.CurrentVitalShield).
                local vshield = tonumber(slot_data.VitalShield)
                if vshield then
                    pcall(function() it:SetPropertyValue("CurrentVitalShield", vshield) end)
                    log("restore: slot " .. idx .. " VitalShield set to " .. vshield)
                end

                -- Container contents (buckets / watering cans):
                -- RemainingFillCharges → Contents.Quantity, ContentItemData →
                -- Contents.ContentData (resolved by PersistenceID).
                local fill_qty = tonumber(slot_data.RemainingFillCharges)
                local content_id = slot_data.ContentItemData
                if fill_qty or (content_id and content_id ~= "") then
                    -- Crash-safety: breadcrumb each step (run-14 showed struct
                    -- proxy access can hard-crash; pcall can't catch that).
                    write_mod_log("restore: contents begin slot " .. idx)
                    -- Cache fallback: older saves may lack ContentItemData.
                    if not content_id or content_id == "" then
                        load_attr_cache()
                        local cached = slot_data.GUID and ContentAttrCache[slot_data.GUID]
                        if cached and cached.ContentItemData then
                            content_id = tostring(cached.ContentItemData)
                            log("restore: slot " .. idx .. " content type from attr cache.")
                        end
                    end
                    local content_obj = nil
                    if content_id and content_id ~= "" then
                        content_obj = find_item_by_persistence_id(content_id)
                        if not content_obj then
                            log_err("restore: slot " .. idx .. " content asset not found for PID "
                                .. tostring(content_id))
                        end
                    end
                    -- CRASH GUARD: charges with a null content type render a
                    -- broken fill bar and hard-crash the UI (run-16). If the
                    -- content can't be resolved, restore the container EMPTY.
                    if fill_qty and fill_qty > 0 and not content_obj then
                        log_err("restore: slot " .. idx .. " has " .. fill_qty
                            .. " charges but unresolvable content — restoring EMPTY to avoid crash.")
                        fill_qty = 0
                    end
                    -- 1. Persistence mirror fields first (safe plain properties).
                    if content_id and content_id ~= "" then
                        pcall(function() it:SetPropertyValue("ContentPersistenceID", content_id) end)
                    end
                    if fill_qty then
                        pcall(function() it:SetPropertyValue("Quantity_Persistence", fill_qty) end)
                    end
                    write_mod_log("restore: contents mirrors written slot " .. idx)
                    -- 2. Live struct write (whole-struct table assignment).
                    local ok_cw = pcall(function()
                        it:SetPropertyValue("Contents", {
                            ContentData = content_obj,
                            Quantity    = fill_qty or 0,
                        })
                    end)
                    write_mod_log("restore: contents struct-write done (ok=" .. tostring(ok_cw) .. ")")
                    -- 3. Verify via a guarded read.
                    local qty_back = nil
                    local ok_ct, ct = pcall(function() return it:GetPropertyValue("Contents") end)
                    if ok_ct and ct then
                        local ok_q, q = pcall(function() return tonumber(ct:GetPropertyValue("Quantity")) end)
                        if ok_q and q then qty_back = q end
                    end
                    write_mod_log("restore: contents verify done slot " .. idx)
                    pcall(function() it:OnRep_Contents() end)
                    log(string.format(
                        "restore: slot %d contents — struct-write ok=%s qty-readback=%s content=%s",
                        idx, tostring(ok_cw), tostring(qty_back),
                        tostring(content_obj ~= nil)))
                end
            end
        end
        ::next_slot::
    end

    local _, final_list = scan_occupied_slots(comp)
    log("restore: occupied slots after restore = " .. #final_list
        .. (#final_list > 0 and (" [" .. table.concat(final_list, ",") .. "]") or ""))

    -- Nudge replication/UI.
    local ok_rep = pcall(function() comp:OnRep_ItemSlots() end)
    log("restore: OnRep_ItemSlots() = " .. tostring(ok_rep))
end

-- -----------------------------------------------------------------------------
-- Game-save hooks
-- -----------------------------------------------------------------------------

-- Registration is DEFERRED to the controller-ready callback: at mod start the
-- Dominion classes aren't loaded yet, so RegisterHook on them fails silently
-- (run-10: only the Engine's SaveGameToSlot ever registered).
local save_hooks_registered = false
local function register_save_hooks()
    if save_hooks_registered then return end
    save_hooks_registered = true
    log("Registering game-save hooks...")
    for _, hook_path in ipairs(GAME_SAVE_HOOKS) do
        local ok = pcall(function()
            RegisterHook(hook_path,
                function()
                    -- PRE-hook, on the game thread: the save must complete before
                    -- the hooked function runs — critical for RequestGameExit,
                    -- where a post-hook would land after world teardown begins.
                    log("Game save hook fired: " .. hook_path)
                    pcall(save_all_inventories)
                end,
                function() end
            )
        end)
        if ok then
            log("Save hook registered: " .. hook_path)
        else
            log("Save hook NOT available: " .. hook_path)
        end
    end

    -- Harvest hook: on character load the game hands over its full save JSON
    -- (plain FString param) — mine it for container content types.
    local ok_h = pcall(function()
        RegisterHook("/Script/Dominion.DominionPlayerControllerBase:Server_ReceiveLoadFromDisk",
            function(self, handle, bsuccess, slotinfo, content)
                local s = nil
                local ok_c, cv = pcall(function() return content:get() end)
                if ok_c and cv ~= nil then
                    if type(cv) == "string" then s = cv
                    else pcall(function() s = tostring(cv:ToString()) end) end
                end
                if s and #s > 2 then
                    log("harvest: received character save content (" .. #s .. " bytes).")
                    pcall(harvest_content_attrs, s)
                end
            end,
            function() end
        )
    end)
    log("Harvest hook " .. (ok_h and "registered." or "NOT available."))
end

-- Register hooks as early as possible: the menu controller exists at the main
-- menu, BEFORE any world load — so the harvest/save hooks are live before the
-- game sends the character-load RPC (in-world registration was too late).
NotifyOnNewObject("/Script/Dominion.DominionPlayerControllerMenu", function(_)
    ExecuteInGameThread(register_save_hooks)
end)

-- -----------------------------------------------------------------------------
-- Load-time restore (runs on EVERY world load)
-- NotifyOnNewObject(DominionPlayerController) fires on each world entry — incl.
-- re-entry after exit-to-main-menu, when the previous world's component is gone
-- but our Lua state (LoadedFromDisk etc.) lingers. Detect that and re-restore.
-- -----------------------------------------------------------------------------

local load_restore_generation = 0

local function find_second_inventory_in_world()
    local ok_fa, all_pics = pcall(FindAllOf, "PersonalInventoryComponent")
    if not ok_fa or not all_pics then return nil end
    for _, pic in ipairs(all_pics) do
        if pic:IsValid() then
            local ok_nm, nm = pcall(function() return pic:GetName() end)
            if ok_nm and nm and nm:find("SecondPersonalInventory") then return pic end
        end
    end
    return nil
end

local function start_load_restore()
    -- Generation counter: a newer call supersedes any still-polling loop.
    load_restore_generation = load_restore_generation + 1
    local gen = load_restore_generation
    local done = false
    local tries = 0
    local ok_loop = pcall(function()
        LoopAsync(2000, function()
            if done or gen ~= load_restore_generation then return true end
            tries = tries + 1
            if tries > 30 then
                log_err("Load-time restore: timed out waiting for character.")
                return true
            end
            ExecuteInGameThread(function()
                if done or gen ~= load_restore_generation then return end

                local ctrl = find_local_controller()
                if not ctrl then return end
                local guid = resolve_character_guid(ctrl)
                if not guid then return end

                -- Wait for the player character — its presence means the save
                -- data is loaded and components are safe to construct.
                local char_ok = false
                local ok_ch, chars = pcall(FindAllOf, "DominionPlayerCharacter")
                if ok_ch and chars then
                    for _, ch in ipairs(chars) do
                        if ch:IsValid() then char_ok = true break end
                    end
                end
                if not char_ok then return end

                -- World re-entry detection: we restored earlier this mod
                -- lifetime — but does that component still exist in THIS world?
                if LoadedFromDisk[guid] then
                    local comp = SecondInventories[guid]
                    local ok_v, is_v = pcall(function() return comp and comp:IsValid() end)
                    if ok_v and is_v then
                        done = true  -- same world; nothing to do
                        return
                    end
                    local found = find_second_inventory_in_world()
                    if found then
                        SecondInventories[guid] = found  -- stale Lua ref, live object
                        done = true
                        return
                    end
                    -- Component gone → fresh world instance → full re-restore.
                    log("New world load detected — resetting session state for re-restore.")
                    LoadedFromDisk[guid] = nil
                    PendingRestoreData[guid] = nil
                    FailedRestoreSlots[guid] = nil
                    SecondInventories[guid] = nil
                end

                done = true
                LoadedFromDisk[guid] = true
                ControllersByGuid[guid] = ctrl

                -- Refresh the content-type cache from the game's own save
                -- before restoring (covers container fill types).
                pcall(harvest_from_disk)

                local saved = load_inventory_data(guid)
                if not saved then
                    log("Load-time restore: no save file — nothing to restore.")
                    return
                end

                local comp = get_or_create_second_inventory(guid, ctrl)
                if not comp then
                    log_err("Load-time restore: component construction failed.")
                    return
                end

                log("Load-time restore: populating second inventory from disk...")
                restore_inventory(guid, comp, saved)
                log("Load-time restore: complete.")
            end)
            return done
        end)
    end)
    if not ok_loop then
        log_err("LoopAsync unavailable — load-time restore will run on first cast instead.")
    end
end

-- -----------------------------------------------------------------------------
-- Eye of Oculus hook
-- -----------------------------------------------------------------------------

log("Waiting for player controller to register Eye of Oculus hook...")

local hook_registered = false

NotifyOnNewObject("/Script/Dominion.DominionPlayerController", function(_)
    ExecuteInGameThread(function()
        -- Hooks register once; the load restore runs on EVERY controller spawn.
        if not hook_registered then

        log("Player controller ready — registering hooks...")

        -- Game-save hooks need the Dominion classes loaded — register them here.
        register_save_hooks()

        -- Post-hook on our second inventory's OpenPersonalInventory.
        -- OpenPersonalInventory likely rewrites JsonInventory from ItemSlots during its
        -- execution, trimming MaxSlotIndex to the highest occupied slot.  We intercept
        -- immediately after and patch it back to 39, then broadcast so the open UI
        -- refreshes to show all 40 slots.
        local ok_opi = pcall(function()
            RegisterHook("/Script/Dominion.PersonalInventoryComponent:OpenPersonalInventory",
                function(self, p1, char_obj) end,
                function(self, p1, char_obj)
                    -- NOTE: In UE4SS native post-hooks self wraps the function's return value
                    -- (void → nullptr), NOT the component instance.  self:get():GetName() always
                    -- crashes.  We identify which component to restore via PendingRestoreData,
                    -- which the Eye of Oculus hook sets just before calling open_second_inventory_ui.
                    log("OPI post-hook: fired — consuming PendingRestoreData.")

                    -- Snapshot pending work and clear the table before processing so that
                    -- any re-entrant calls see an empty table.
                    local to_restore = {}
                    for guid, json in pairs(PendingRestoreData) do
                        to_restore[guid] = json
                    end
                    PendingRestoreData = {}

                    local any = false
                    for guid, restore_json in pairs(to_restore) do
                        local comp = SecondInventories[guid]
                        if comp then
                            local ok_v, is_v = pcall(function() return comp:IsValid() end)
                            if ok_v and is_v then
                                log("OPI post-hook: restoring items for GUID=" .. guid:sub(1, 16) .. "...")
                                restore_inventory(guid, comp, restore_json)
                                any = true
                            else
                                log("OPI post-hook: comp invalid for GUID=" .. guid:sub(1, 16))
                            end
                        else
                            log("OPI post-hook: no comp stored for GUID=" .. guid:sub(1, 16))
                        end
                    end
                    if not any then
                        log("OPI post-hook: nothing to restore.")
                    end
                end
            )
        end)
        if ok_opi then log("OpenPersonalInventory post-hook registered.")
        else log_err("Could not hook OpenPersonalInventory.") end

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

        -- -----------------------------------------------------------------------
        -- Item-movement hooks: brute-force discovery
        -- We don't know which UFunction gets called when an item is dragged into
        -- our second inventory.  Register hooks for every plausible name; log
        -- which ones succeed and, crucially, what parameters arrive when they fire
        -- on our SecondPersonalInventory component.  The parameter that carries
        -- item type/class info is what we need to capture as "ItemData".
        -- -----------------------------------------------------------------------
        local ITEM_HOOKS = {
            "AddItem",          "TryAddItem",       "ServerAddItem",
            "AddItemToSlot",    "MoveItemToSlot",   "SetItemInSlot",
            "PlaceItemInSlot",  "InsertItem",       "PutItem",
            "OnItemAdded",      "OnSlotUpdated",    "OnInventoryChanged",
            "SwapItems",        "SwapItemSlots",    "MoveItem",
            "ServerMoveItem",   "PickupItem",       "ReceiveItem",
            "SetSlotContent",   "UpdateSlot",
        }
        local item_hook_count = 0
        for _, fn_name in ipairs(ITEM_HOOKS) do
            local hook_path = "/Script/Dominion.PersonalInventoryComponent:" .. fn_name
            local ok_ih = pcall(function()
                RegisterHook(hook_path,
                    function(self, ...)
                        -- Pre-hook: log whenever this fires on our inventory.
                        local comp = nil
                        pcall(function()
                            local c = self:get()
                            if c and c:IsValid() then comp = c end
                        end)
                        if not comp then return end
                        local ok_nm, nm = pcall(function() return comp:GetName() end)
                        if not ok_nm or not nm or not nm:find("SecondPersonalInventory") then return end

                        -- Count and type-inspect parameters.
                        local args = { ... }
                        log("ITEM_HOOK pre [" .. fn_name .. "] fired on SecondPersonalInventory, "
                            .. #args .. " params:")
                        for i, p in ipairs(args) do
                            local pt = type(p)
                            local pval = pt ~= "userdata" and tostring(p) or "userdata"
                            -- Try common UObject methods.
                            if pt == "userdata" then
                                local ok_g, pv = pcall(function() return p:get() end)
                                if ok_g and pv ~= nil then
                                    pt = "RemoteUnrealParam"
                                    local ok_cls, cls = pcall(function() return pv:GetClass():GetName() end)
                                    local ok_pn, pn   = pcall(function() return pv:GetPathName()         end)
                                    local ok_nm2, nm2  = pcall(function() return pv:GetName()            end)
                                    pval = string.format("cls=%s path=%s name=%s",
                                        ok_cls and cls or "?",
                                        ok_pn  and pn  or "?",
                                        ok_nm2 and nm2 or "?")
                                else
                                    local ok_ts, ts = pcall(function() return p:ToString() end)
                                    if ok_ts and ts and ts ~= "" then pval = ts:sub(1, 60) end
                                end
                            end
                            log("  param[" .. i .. "] type=" .. pt .. " val=" .. pval)
                        end
                    end,
                    function(self, ...) end   -- post-hook (empty)
                )
            end)
            if ok_ih then
                item_hook_count = item_hook_count + 1
                log("Item hook registered: " .. fn_name)
            end
        end
        log("Item-movement hooks registered: " .. item_hook_count .. " / " .. #ITEM_HOOKS)

        -- -----------------------------------------------------------------------
        -- Add-function parameter spy
        -- ForEachProperty doesn't work on UFunction wrappers in this UE4SS build,
        -- so learn the Add* signatures from live gameplay instead: hook them on
        -- the BASE InventoryComponent (the ITEM_HOOKS on PersonalInventoryComponent
        -- registered 0/20 — these functions live on the base class) and log the
        -- first few firings with full parameter values. Any item pickup fires them.
        -- -----------------------------------------------------------------------
        local ADD_SPY_FNS = {
            "AddItem", "AddItems", "AddItemByData", "AddItemsByData",
            "AddItemByDataToSlot", "AddItemToSlot", "RemoveFromSlot",
        }
        local add_spy_counts = {}
        local add_spy_registered = 0
        for _, sf in ipairs(ADD_SPY_FNS) do
            local ok_sp = pcall(function()
                RegisterHook("/Script/Dominion.InventoryComponent:" .. sf,
                    function(self, ...)
                        add_spy_counts[sf] = (add_spy_counts[sf] or 0) + 1
                        if add_spy_counts[sf] > 3 then return end
                        local args = { ... }
                        log("ADDSPY " .. sf .. " fired with " .. #args .. " params:")
                        for ai, p in ipairs(args) do
                            local desc = type(p)
                            if type(p) == "userdata" then
                                local ok_g, v = pcall(function() return p:get() end)
                                if ok_g and v ~= nil then
                                    local vt = type(v)
                                    if vt == "userdata" then
                                        local s = nil
                                        local ok_fn2, fn2 = pcall(function() return v:GetFullName() end)
                                        if ok_fn2 and fn2 and tostring(fn2) ~= "" then
                                            s = tostring(fn2)
                                        else
                                            pcall(function() s = tostring(v:ToString()) end)
                                        end
                                        -- FGuid? read sub-fields.
                                        local gh = ""
                                        pcall(function() gh = norm_guid_hex(read_fguid(v)) end)
                                        desc = "wrapped userdata: " .. tostring(s):sub(1, 90)
                                            .. (#gh == 32 and (" FGUID=" .. gh) or "")
                                    else
                                        desc = "wrapped " .. vt .. " = " .. tostring(v)
                                    end
                                else
                                    local ok_ts, ts = pcall(function() return p:ToString() end)
                                    desc = "userdata" .. ((ok_ts and ts) and (" ts=" .. tostring(ts):sub(1, 60)) or "")
                                end
                            else
                                desc = desc .. " = " .. tostring(p)
                            end
                            log("ADDSPY   param[" .. ai .. "] " .. desc)
                        end
                    end,
                    function() end
                )
            end)
            if ok_sp then add_spy_registered = add_spy_registered + 1 end
        end
        log("ADDSPY hooks registered: " .. add_spy_registered .. " / " .. #ADD_SPY_FNS)

        local reg_ok, reg_err = pcall(function()
            RegisterHook(SPELL_HOOK,
                function(self, Instance)
                    ExecuteInGameThread(function()
                        log("Eye of Oculus cast — finding local player controller...")

                        local ctrl = find_local_controller()
                        if not ctrl then
                            log_err("No valid DominionPlayerController found.")
                            return
                        end

                        local guid = resolve_character_guid(ctrl)
                        if not guid then
                            log_err("Could not resolve character GUID.")
                            return
                        end
                        log("Controller found, GUID=" .. guid)
                        ControllersByGuid[guid] = ctrl

                        -- Spy on all PersonalInventoryComponents to learn real JSON format.
                        -- DISABLED 2026-06-09: served its purpose (PersistenceID property found,
                        -- UFunction list captured, GUID encoding confirmed). Both logs went dark
                        -- mid-spy on runs 3/4, so this block is also the prime crash suspect.
                        local SPY_ENABLED = false
                        if SPY_ENABLED and _probe_cast <= 5 then
                            local ok_all, all_pics = pcall(function()
                                return FindAllOf("PersonalInventoryComponent")
                            end)
                            if ok_all and all_pics then
                                for _, pic in ipairs(all_pics) do
                                    if pic:IsValid() then
                                        local ok_nm, nm = pcall(function() return pic:GetName() end)
                                        local nm_str = (ok_nm and nm) or "?"
                                        if not nm_str:find("SecondPersonalInventory") then
                                            local ok_j, j = pcall(function()
                                                return pic:GetPropertyValue("JsonInventory"):ToString()
                                            end)
                                            if ok_j and j and j ~= "" and j ~= SLOT_LAYOUT_JSON
                                               and j ~= EMPTY_INV_JSON then
                                                -- Show the first 400 chars so we can see item entries.
                                                log("REAL inv [" .. nm_str .. "] len=" .. #j
                                                    .. "  preview=" .. j:sub(1, 400))
                                            else
                                                log("REAL inv [" .. nm_str .. "] len="
                                                    .. (ok_j and j and tostring(#j) or "err")
                                                    .. " (empty/layout only)")
                                            end

                                            -- One-shot UFunction dump of the component class chain. Goal:
                                            -- find the engine's own "serialize ItemSlots → JsonInventory"
                                            -- function so we can call it on OUR component and get engine-
                                            -- format JSON (incl. correct b64 ItemData GUIDs) for free.
                                            if not _dumped_comp_fns then
                                                _dumped_comp_fns = true
                                                local ok_cls, cls = pcall(function() return pic:GetClass() end)
                                                local depth = 0
                                                while ok_cls and cls and depth < 4 do
                                                    local cn = "?"
                                                    pcall(function() cn = cls:GetFName():ToString() end)
                                                    if cn == "ActorComponent" or cn == "Object" then break end
                                                    local fns = {}
                                                    local ok_fe, fe_err = pcall(function()
                                                        cls:ForEachFunction(function(fn)
                                                            local n = "?"
                                                            pcall(function() n = fn:GetFName():ToString() end)
                                                            fns[#fns + 1] = n
                                                        end)
                                                    end)
                                                    if not ok_fe then
                                                        log("FNDUMP ForEachFunction unavailable: " .. tostring(fe_err))
                                                        break
                                                    end
                                                    -- Chunk output: 6 names per line.
                                                    log("FNDUMP class [" .. cn .. "] " .. #fns .. " functions:")
                                                    for ci = 1, #fns, 6 do
                                                        log("FNDUMP   " .. table.concat(fns, ", ", ci, math.min(ci + 5, #fns)))
                                                    end
                                                    local ok_su, su = pcall(function() return cls:GetSuperStruct() end)
                                                    if not (ok_su and su) then break end
                                                    cls = su
                                                    depth = depth + 1
                                                end
                                            end

                                            -- GUID-encoding spy: dump the real inventory's LIVE slots so we
                                            -- can match hex GUIDs/asset paths against the base64url values in
                                            -- CharacterSave.json's PersonalInventory table (offline analysis).
                                            local ok_rs, rs = pcall(function()
                                                return pic:GetPropertyValue("ItemSlots")
                                            end)
                                            if ok_rs and rs then
                                                for ri = 1, 32 do
                                                    local ok_rsl, rsl = pcall(function() return rs[ri] end)
                                                    if not (ok_rsl and rsl) then break end
                                                    local ok_rg, rg = pcall(function()
                                                        return rsl:GetPropertyValue("GUID")
                                                    end)
                                                    local ghex = (ok_rg and rg) and norm_guid_hex(read_fguid(rg)) or ""
                                                    if ghex ~= "" and ghex ~= EMPTY_GUID then
                                                        local ok_rd, rd = pcall(function()
                                                            return rsl:GetPropertyValue("ItemData")
                                                        end)
                                                        local path = "?"
                                                        if ok_rd and rd then
                                                            local ok_fn, fn = pcall(function() return rd:GetFullName() end)
                                                            if ok_fn and fn then path = tostring(fn) end
                                                        end
                                                        local ok_rcnt, rcnt = pcall(function()
                                                            return tonumber(rsl:GetPropertyValue("Count"))
                                                        end)
                                                        log(string.format("SPY real slot %d: GUID=%s Count=%s",
                                                            ri - 1, ghex, tostring(ok_rcnt and rcnt)))
                                                        log("SPY real slot " .. (ri - 1) .. ": ItemData=" .. path)
                                                        -- One-shot FULL property dump of this ItemData asset via
                                                        -- UE4SS reflection. Goal: find the property holding the
                                                        -- 16-byte GUID the engine writes as b64 ItemData in saves
                                                        -- (e.g. stone block = 8C41847A44CB69B7D3AAD58496A3572D).
                                                        if not _dumped_item_props and ok_rd and rd then
                                                            _dumped_item_props = true
                                                            local ok_cls, cls = pcall(function() return rd:GetClass() end)
                                                            local depth = 0
                                                            while ok_cls and cls and depth < 8 do
                                                                local cn = "?"
                                                                pcall(function() cn = cls:GetFName():ToString() end)
                                                                if cn == "Object" then break end
                                                                log("PROPDUMP class [" .. cn .. "]:")
                                                                local ok_fe, fe_err = pcall(function()
                                                                    cls:ForEachProperty(function(prop)
                                                                        local pn = "?"
                                                                        pcall(function() pn = prop:GetFName():ToString() end)
                                                                        local info = "unreadable"
                                                                        local ok_v, v = pcall(function() return rd:GetPropertyValue(pn) end)
                                                                        if ok_v and v ~= nil then
                                                                            local t = type(v)
                                                                            if t ~= "userdata" then
                                                                                info = t .. " = " .. tostring(v):sub(1, 80)
                                                                            else
                                                                                local h = ""
                                                                                pcall(function() h = norm_guid_hex(read_fguid(v)) end)
                                                                                if #h == 32 then
                                                                                    info = "FGUID = " .. h
                                                                                else
                                                                                    local ts = ""
                                                                                    pcall(function() ts = tostring(v:ToString()) end)
                                                                                    info = "userdata" .. (ts ~= "" and (" = " .. ts:sub(1, 80)) or "")
                                                                                end
                                                                            end
                                                                        end
                                                                        log("PROPDUMP   " .. pn .. " : " .. info)
                                                                    end)
                                                                end)
                                                                if not ok_fe then
                                                                    log("PROPDUMP ForEachProperty unavailable: " .. tostring(fe_err))
                                                                    break
                                                                end
                                                                local ok_su, su = pcall(function() return cls:GetSuperStruct() end)
                                                                if not (ok_su and su) then break end
                                                                cls = su
                                                                depth = depth + 1
                                                            end
                                                        end

                                                        -- Sweep the ItemData asset for GUID-like properties —
                                                        -- one of them should match the b64 ItemData in the save.
                                                        if ok_rd and rd then
                                                            local gprops = {
                                                                "Guid", "GUID", "ItemGuid", "AssetGuid",
                                                                "Id", "ID", "ItemId", "ItemID",
                                                                "UniqueId", "UniqueID", "AssetId",
                                                                "RegistryId", "SaveId", "SaveGuid",
                                                                "PersistentGuid", "DataGuid",
                                                            }
                                                            for _, gp in ipairs(gprops) do
                                                                local ok_pv, pv = pcall(function()
                                                                    return rd:GetPropertyValue(gp)
                                                                end)
                                                                if ok_pv and pv ~= nil then
                                                                    local h = norm_guid_hex(read_fguid(pv))
                                                                    if h ~= "" and h ~= EMPTY_GUID then
                                                                        log("SPY real slot " .. (ri - 1)
                                                                            .. ": ItemData." .. gp .. " = " .. h)
                                                                    end
                                                                end
                                                            end
                                                        end
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end

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

                        -- ARCHITECTURE (2026-06-09): restore happens ONCE at game load (see the
                        -- load-time restore loop below). The live component owns the state from
                        -- then on; casts only persist + sync + open the UI.

                        -- Cast-time fallback: if the load-time restore hasn't run yet (slow
                        -- load, race), restore now before opening.
                        if not LoadedFromDisk[guid] then
                            LoadedFromDisk[guid] = true
                            local saved = load_inventory_data(guid)
                            if saved then
                                log("Cast-time fallback restore (load-time restore hadn't run).")
                                restore_inventory(guid, second_inv, saved)
                            end
                        end

                        -- NO file write here: the JSON on disk must only change when the
                        -- game itself saves (Client_SaveToDisk hook), so chest state and
                        -- world state always snapshot the same moment — otherwise items
                        -- can dupe or vanish if the session ends without a game save.
                        -- Serialize in-memory only, for the JsonInventory sync below.
                        local current_json = serialize_item_slots(second_inv)

                        -- Keep JsonInventory = full engine-format inventory (items + MaxSlotIndex:39).
                        -- If OpenPersonalInventory rebuilds ItemSlots from JsonInventory, this
                        -- reproduces the items instead of wiping them, and keeps the 40-slot grid.
                        -- No broadcast — the live ItemSlots array is the source of truth.
                        local sync_json = current_json or SLOT_LAYOUT_JSON
                        local ok_sync = pcall(function()
                            second_inv:SetPropertyValue("JsonInventory", sync_json)
                        end)
                        log("JsonInventory synced pre-open (" .. #sync_json .. " bytes, ok=" .. tostring(ok_sync) .. ").")

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

        end  -- if not hook_registered

        -- Every controller spawn (= every world load, incl. re-entry from the
        -- main menu) kicks off the load restore. start_load_restore detects
        -- whether this is the same world (no-op) or a fresh one (re-restore).
        start_load_restore()
    end)
end)
