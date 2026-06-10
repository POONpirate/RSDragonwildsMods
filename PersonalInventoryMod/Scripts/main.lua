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

-- -----------------------------------------------------------------------------
-- Logging helpers
-- -----------------------------------------------------------------------------

-- Parallel mod log file with immediate flush. UE4SS buffers print() output,
-- so UE4SS.log copied while the game is running can be truncated mid-write.
-- This file is always complete and safe to copy at any time.
local MOD_LOG_PATH = "ue4ss/Mods/" .. MOD_NAME .. "/" .. MOD_NAME .. ".log"
local mod_log_file = io.open(MOD_LOG_PATH, "w")  -- truncate per session

local function write_mod_log(line)
    if mod_log_file then
        mod_log_file:write(os.date("[%H:%M:%S] ") .. line .. "\n")
        mod_log_file:flush()
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
    -- 1. Try calling functions that might update JsonInventory from ItemSlots.
    local forced = try_force_json(inv_comp)
    if forced then return forced end

    local ok_s, sv = pcall(function()
        return inv_comp:GetPropertyValue("ItemSlots")
    end)
    if not ok_s or sv == nil then
        log("serialize: ItemSlots read failed")
        return nil
    end

    -- 2. Probe a few slots with detailed field inspection (every other cast).
    _probe_cast = _probe_cast + 1
    if _probe_cast <= 5 then
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
        -- IsValid()=true for occupied slots but GetPathName/GetClass fail (it's an FStruct,
        -- not a real UObject).  Sweep every plausible method and sub-field to find the
        -- string form of the item type reference.
        if _probe_cast <= 5 then
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
        local persist_id = ""
        if ok_d and dv ~= nil and type(dv) ~= "string" then
            persist_id = get_persistence_id(dv)
        end

        local json_idx = i - 1
        -- ENGINE FORMAT: GUID as b64url, ItemData as PersistenceID. Falls back
        -- to legacy hex/path when conversion isn't possible (restore handles both).
        local b64_guid = guid_hex_to_b64(guid_str)
        parts[#parts + 1] = string.format(
            ',"%d":{"GUID":"%s","ItemData":"%s","Count":%d}',
            json_idx,
            b64_guid or guid_str,
            (persist_id ~= "" and persist_id or item_data_str):gsub('"', '\\"'),
            count_val)
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
        log("serialize: no items found (GUID sub-fields all zero or unreadable).")
        return nil
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

    -- Priority 1: manually serialize ItemSlots → JSON (engine format).
    -- This is the primary path because the engine never writes item data back into
    -- JsonInventory for our dynamic component.
    to_write, sidecar_json = serialize_item_slots(inv_comp)

    -- Priority 2: live JsonInventory (populated if the engine did serialize it).
    if not to_write then
        local ok_json, json_str = pcall(function()
            return inv_comp:GetPropertyValue("JsonInventory"):ToString()
        end)
        log("save: live JsonInventory len=" .. (ok_json and json_str and tostring(#json_str) or "err"))
        if ok_json and json_str and json_str ~= ""
           and json_str ~= SLOT_LAYOUT_JSON and json_str ~= EMPTY_INV_JSON then
            to_write = json_str
            log("save: using live JsonInventory.")
        end
    end

    -- Priority 3: cached snapshot captured from the post-open hook.
    if not to_write and fallback_json and fallback_json ~= ""
       and fallback_json ~= SLOT_LAYOUT_JSON and fallback_json ~= EMPTY_INV_JSON then
        to_write = fallback_json
        log("save: using cached fallback JSON.")
    end

    if not to_write then
        log("save: inventory is empty — nothing written for GUID " .. guid)
        return
    end

    local path = json_path(guid)
    local file = io.open(path, "w")
    if not file then
        log_err("Could not open save file for writing: " .. path)
        return
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
-- Game-save hooks
-- -----------------------------------------------------------------------------

log("Registering game-save hooks...")
for _, hook_path in ipairs(GAME_SAVE_HOOKS) do
    local ok = pcall(function()
        RegisterHook(hook_path,
            function() end,
            function()
                log("Game save hook fired: " .. hook_path)
                ExecuteInGameThread(save_all_inventories)
            end
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
                                populate_inventory(comp, restore_json)
                                log("OPI post-hook: restore broadcast sent.")

                                -- Restore strategy (2026-06-09):
                                -- 1. Broadcast already fired above. If the save is engine format
                                --    (b64 GUIDs + PersistenceIDs) the engine may restore natively —
                                --    the occupancy scan below tells us.
                                -- 2. Any slot still empty gets restored via the engine's own add
                                --    functions (AddItemByDataToSlot etc., found via FNDUMP), with the
                                --    asset resolved from the paths sidecar / legacy path / PersistenceID.
                                -- NOTE: direct struct writes are DEAD — UE4SS returns FItemSlot copies.
                                local function scan_occupied()
                                    local set, list = {}, {}
                                    local ok_sv, sv = pcall(function()
                                        return comp:GetPropertyValue("ItemSlots")
                                    end)
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

                                local occ_set, occ_list = scan_occupied()
                                log("OPI fix: occupied slots after broadcast = " .. #occ_list
                                    .. (#occ_list > 0 and (" [" .. table.concat(occ_list, ",") .. "]") or ""))

                                local ok_dec, parsed = pcall(json.decode, restore_json)
                                if not ok_dec then
                                    log_err("OPI fix: json.decode failed: " .. tostring(parsed))
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

                                -- Make sure AllowAdds isn't blocking the engine add functions.
                                pcall(function() comp:SetPropertyValue("AllowAdds", true) end)

                                for key, slot_data in pairs(parsed or {}) do
                                    local idx = tonumber(key)
                                    if idx and type(slot_data) == "table"
                                       and slot_data.GUID and slot_data.GUID ~= "" then
                                        if occ_set[idx] then
                                            log("OPI fix: slot " .. idx .. " already restored by engine.")
                                            goto next_slot
                                        end

                                        -- Resolve the item asset: legacy path in ItemData, sidecar
                                        -- path, or PersistenceID scan of loaded assets.
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
                                                log("OPI fix: slot " .. idx .. " resolved via PersistenceID scan.")
                                            end
                                        end
                                        if not found then
                                            log_err("OPI fix: slot " .. idx .. ": cannot resolve item ("
                                                .. idat:sub(1, 60) .. ")")
                                            goto next_slot
                                        end

                                        -- Engine-native add. Signature unknown — try likely arg orders
                                        -- and verify by re-scanning slot occupancy after each call.
                                        local cnt = tonumber(slot_data.Count) or 1
                                        local attempts = {
                                            { "AddItemByDataToSlot", { found, idx, cnt } },
                                            { "AddItemByDataToSlot", { found, cnt, idx } },
                                            { "AddItemByData",       { found, cnt } },
                                        }
                                        local added = false
                                        for _, att in ipairs(attempts) do
                                            local fname, args = att[1], att[2]
                                            local ok_call, ret = pcall(function()
                                                return comp[fname](comp, table.unpack(args))
                                            end)
                                            log(string.format("OPI fix: slot %d %s(#%d args) ok=%s ret=%s",
                                                idx, fname, #args, tostring(ok_call), tostring(ret)))
                                            local now_set = scan_occupied()
                                            if now_set[idx] then
                                                added = true
                                                log("OPI fix: slot " .. idx .. " now occupied via " .. fname)
                                                break
                                            end
                                            if ok_call and (ret == true or (tonumber(ret) or 0) > 0) then
                                                added = true
                                                log("OPI fix: " .. fname .. " reported success (slot may differ).")
                                                break
                                            end
                                        end
                                        if not added then
                                            log_err("OPI fix: slot " .. idx .. " could not be filled by engine adds.")
                                        end
                                    end
                                    ::next_slot::
                                end

                                local _, final_list = scan_occupied()
                                log("OPI fix: occupied slots after restore = " .. #final_list
                                    .. (#final_list > 0 and (" [" .. table.concat(final_list, ",") .. "]") or ""))

                                -- Try OnRep_ItemSlots to nudge the UI into re-rendering.
                                local ok_rep = pcall(function() comp:OnRep_ItemSlots() end)
                                log("OPI fix: OnRep_ItemSlots() = " .. tostring(ok_rep))

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

                        -- Spy on all PersonalInventoryComponents to learn real JSON format.
                        -- The real chest's JsonInventory shows us what valid ItemData looks like.
                        -- Only log the first time (or first few times) to avoid log spam.
                        if _probe_cast <= 5 then
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

                        -- Persist on every open so items are never lost between sessions.
                        -- On first cast the component is freshly constructed (no items) so
                        -- save_inventory_data writes nothing.  On second+ cast this captures
                        -- everything placed since the last save.
                        save_inventory_data(guid, second_inv, CachedInventoryJson[guid])

                        -- JsonInventory controls grid layout (how many slots the UI renders).
                        -- ItemSlots holds actual item data and persists in-memory on the
                        -- component between casts. The engine does NOT update JsonInventory
                        -- when items are dragged in — only during game serialization/save.
                        --
                        -- On the very first open after loading (disk save exists), we restore
                        -- by calling populate_inventory, which sets JsonInventory and fires
                        -- OnInventoryLoadedFromSave:Broadcast() so the engine rebuilds ItemSlots.
                        -- LoadedFromDisk prevents re-loading on subsequent casts, which would
                        -- overwrite any items moved since the last restore.
                        --
                        -- When there is no disk save (or already restored), we only update
                        -- JsonInventory via SetPropertyValue (no broadcast) to keep the 40-slot
                        -- grid visible without touching the live ItemSlots array.

                        local saved = (not LoadedFromDisk[guid]) and load_inventory_data(guid)
                        if saved then
                            -- Set JsonInventory now so OpenPersonalInventory sees the right slot
                            -- count (MaxSlotIndex:39) when it initialises the UI grid.
                            -- We also queue the data in PendingRestoreData so the OPI post-hook
                            -- can call populate_inventory AGAIN after OpenPersonalInventory runs —
                            -- because OPI internally clears/reinitialises ItemSlots, wiping items
                            -- that were placed by the Broadcast we fired here.
                            populate_inventory(second_inv, saved)
                            PendingRestoreData[guid] = saved
                            LoadedFromDisk[guid] = true
                            log("Disk save loaded — queued post-OPI restore for GUID=" .. guid:sub(1, 16) .. "...")
                        else
                            -- Broadcast with SLOT_LAYOUT_JSON (MaxSlotIndex:39, no item entries)
                            -- on EVERY cast.  Goal: engine's OnInventoryLoadedFromSave handler
                            -- should call ItemSlots.SetNum(40) non-destructively, expanding the
                            -- array back to 40 slots after the game trimmed it on item placement.
                            -- If items disappear after this, the handler clears on broadcast and
                            -- we need a different approach.
                            populate_inventory(second_inv, SLOT_LAYOUT_JSON)
                            log("Broadcast SLOT_LAYOUT_JSON — testing non-destructive SetNum(40).")

                            -- Diagnostic: probe TArray indexing (0-based vs 1-based) and slot count.
                            local ok_s, sv = pcall(function()
                                return second_inv:GetPropertyValue("ItemSlots")
                            end)
                            if ok_s and sv ~= nil then
                                local ok0,  s0  = pcall(function() return sv[0]  end)
                                local ok1,  s1  = pcall(function() return sv[1]  end)
                                local ok39, s39 = pcall(function() return sv[39] end)
                                local ok40, s40 = pcall(function() return sv[40] end)
                                log(string.format(
                                    "ItemSlots idx: [0]=%s [1]=%s [39]=%s [40]=%s",
                                    ok0  and type(s0)  or "err",
                                    ok1  and type(s1)  or "err",
                                    ok39 and type(s39) or "err",
                                    ok40 and type(s40) or "err"))
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
