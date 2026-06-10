# PersonalInventoryMod — Technical Summary
> For use with a larger model. Covers full project context, architecture, resolved issues, and current blocker.

---

## Project Overview

A **UE4SS Lua mod** (`PersonalInventoryMod`) for the game **RSDragonwilds** (Unreal Engine module name: `Dominion`). The mod hooks the **Eye of Oculus** spell to open a **second, separate 40-slot personal inventory** alongside the game's built-in Personal Chest (Bank). Items must persist per-character via JSON files keyed by character GUID. The mod must never interfere with the regular inventory.

**File:** `PersonalInventoryMod/Scripts/main.lua` (~1115 lines)

---

## Architecture

### Core Mechanism

1. The **Eye of Oculus spell** fires `GE_PerkV2_Construction_Oculus_C:OnGameplayEffectAdded`.
2. The pre-hook: resolves the local player controller → gets the character GUID → calls `get_or_create_second_inventory(guid, ctrl)` → calls `open_second_inventory_ui(ctrl, second_inv, char_obj)`.
3. `get_or_create_second_inventory` uses **`StaticConstructObject`** to dynamically create a `PersonalInventoryComponent` named `"SecondPersonalInventory"` owned by the player controller.
4. `OpenPersonalInventory(34, char_obj)` opens the grid UI.

### Persistence

- On game save (hooks on several save UFunctions), `serialize_item_slots()` walks the live `ItemSlots` TArray and builds a JSON string manually, then writes it to `ue4ss/Mods/PersonalInventoryMod/PersonalInventoryMod_<GUID>.json`.
- On game load (first cast after restart), the saved JSON is read from disk and `populate_inventory()` is called to restore items.

### State Tables

```lua
local SecondInventories   = {}  -- guid → PersonalInventoryComponent
local ControllersByGuid   = {}  -- guid → ctrl
local CachedInventoryJson = {}  -- guid → json string (captured between casts)
local LoadedFromDisk      = {}  -- guid → true once disk save restored this session
local PendingRestoreData  = {}  -- guid → json string; consumed by OPI post-hook
```

All tables keyed by **GUID string**, not ctrl Lua object (ctrl proxies change between `FindAllOf` calls even for the same underlying UObject).

---

## Key Confirmed Technical Facts (UE4SS / UE4)

### UE4SS Hook Behavior
- In **native post-hooks**, `self` wraps the **return value** of the hooked function, NOT the component instance. For void functions this is a nullptr wrapper. `self:get():IsValid()` returns `true` (the wrapper is valid) but any method call on `self:get()` **crashes** with "UObject instance is nullptr".
- In **pre-hooks** on native functions (not BP), `self:get()` reliably returns the component instance.
- `RegisterHook` on Blueprint functions (those with `_C` in path like `GE_..._C:...`) behaves normally — `self:get()` is the instance in both pre and post.

### TArray Indexing
- TArray userdata returned by `GetPropertyValue` is **1-based** in Lua. `sv[1]` through `sv[40]` for a 40-slot array. `sv[0]` errors.

### FGuid Sign Extension Bug
- `GetPropertyValue` on FGuid sub-fields A/B/C/D returns uint32 as **sign-extended int64**. Without masking, `string.format("%08X", val)` produces 16-char hex strings instead of 8-char. Fix: `val = (tonumber(val) or 0) & 0xFFFFFFFF`.

### ItemData Field Format
- `GetFullName()` on the ItemData UObject returns: `"ClassName /Full/Package/Path.ObjectName"`. Parse with `gfn:match("^%S+%s+(.+)$")` to get the asset path component.
- This full path is what gets written to JSON and what `StaticFindObject` needs to resolve it back to a UObject on reload.
- `GetOuter()` **crashes the game** — never use it.

### JSON Format (confirmed from real game inventory)
```json
{
  "Version": 67,
  "9": {"GUID": "1A8987444BA8CB9B...", "ItemData": "/Game/Gameplay/Items/Consumables/Food/Items/v3/ITEM_Consumable_Fruit_Redberry.ITEM_Consumable_Fruit_Redberry", "Count": 3},
  "MaxSlotIndex": 39,
  "AllowAdds": false
}
```
- Slot keys are **0-based integers as strings** (so JSON key `"9"` = Lua `sv[10]`).
- `MaxSlotIndex: 39` makes the UI render 40 slots.
- `AllowAdds: false` prevents the engine from overwriting MaxSlotIndex on new item placement.

### `OpenPersonalInventory` Behavior
- Internally **clears and reinitializes** `ItemSlots` during execution.
- Items placed into ItemSlots *before* `OpenPersonalInventory` runs are **wiped**.
- Fix: populate items from the OPI **post-hook** (after OPI runs), using `PendingRestoreData`.

### `OnInventoryLoadedFromSave:Broadcast()`
- This is the engine's native handler that reads `JsonInventory` and rebuilds `ItemSlots`.
- **Confirmed behavior**: It sets `GUID` and `Count` correctly in each slot.
- **Suspected behavior (unconfirmed)**: It does NOT properly resolve `ItemData` as a live UObject reference — leaving `ItemData` as null/invalid. This is the current main hypothesis for why items don't appear visually on reload.

---

## What's Working (Solved)

| Feature | Status |
|---|---|
| Eye of Oculus opens second inventory | ✅ |
| Build menu suppressed on cast | ✅ |
| 40-slot visual grid | ✅ |
| All 40 slots usable + ctrl+click | ✅ |
| Session persistence (same session) | ✅ |
| GUID resolution (32-char clean hex) | ✅ |
| Serialize: Count, GUID read from ItemSlots | ✅ |
| Serialize: Full ItemData asset path via `GetFullName()` | ✅ |
| JSON written correctly to disk with full paths | ✅ |
| No game crash (GetOuter removed, post-hook nullptr fixed) | ✅ |
| OPI post-hook fires after `OpenPersonalInventory` | ✅ |
| `populate_inventory()` called in OPI post-hook | ✅ |

---

## Current Blocker: Cross-Session Item Persistence

### Symptom
After a full restart (quit game → reload → cast Eye of Oculus):
- The save JSON file exists and is read from disk (confirmed by logs).
- The OPI post-hook fires and calls `populate_inventory(comp, restore_json)` (confirmed by logs).
- The inventory opens with **zero items visible**.

### Hypothesis
`OnInventoryLoadedFromSave:Broadcast()` parses `JsonInventory` and fills `ItemSlots` with `GUID` and `Count`, but **leaves `ItemData` as null/invalid**. The UI requires `ItemData:IsValid() == true` to render an item in a slot. This would explain why items don't render even though the slots have valid GUIDs and counts.

### Diagnostic Code Added (OPI post-hook, lines ~762–830)
After the broadcast, the hook scans each slot for non-zero `GUID.A`, then:
1. Logs `ItemData:IsValid()` for each occupied slot.
2. If invalid: calls `StaticFindObject(item_path)` (and `item_path .. "_C"`) to resolve the UObject.
3. If found: calls `sl:SetPropertyValue("ItemData", found_obj)`.
4. Re-checks `ItemData:IsValid()` after set.
5. Calls `comp:OnRep_ItemSlots()` to attempt UI refresh.

### Expected Log Lines to Diagnose
```
OPI fix: sv[X] GUID.A=XXXXXXXX ItemData:IsValid()=true/false
OPI fix: StaticFindObject OK: /Game/...
OPI fix: StaticFindObject failed for: /Game/...
OPI fix: SetPropertyValue(ItemData) = true/false
OPI fix: ItemData:IsValid() after set = true/false
OPI fix: OnRep_ItemSlots() = true/false
```

---

## Key Functions

### `populate_inventory(inv_comp, data)`
Sets `JsonInventory` on the component and fires `OnInventoryLoadedFromSave:Broadcast()`.

### `serialize_item_slots(inv_comp)`
Walks live `ItemSlots` TArray (1-based, up to `SECOND_INV_SLOTS`), reads GUID/ItemData/Count per slot, builds JSON string. Uses `GetFullName()` for ItemData path. Skips slots with empty/zero GUIDs.

### `get_or_create_second_inventory(guid, ctrl)`
Checks live Lua reference → searches `FindAllOf("PersonalInventoryComponent")` by name → falls back to `StaticConstructObject`. Seeds the component with `EMPTY_INV_JSON` via `populate_inventory` to pre-allocate 40 ItemSlot entries.

### `open_second_inventory_ui(ctrl, second_inv, char_obj)`
Calls `second_inv:OpenPersonalInventory(34, char_obj)` (34 = confirmed working first parameter; fallback: ctrl).

### OPI Post-Hook
Consumes `PendingRestoreData` table after `OpenPersonalInventory` runs. Uses stored `SecondInventories[guid]` reference (never `self:get()` — that's nullptr in native post-hooks). Calls `populate_inventory`, then runs the diagnostic/fix pass.

---

## Pending Tasks

1. **Run diagnostic test cycle**: Place items → cast twice to save → quit → reload → cast → collect logs.
2. **Confirm `ItemData:IsValid()` hypothesis** from the `OPI fix: sv[X]...` log lines.
3. **If StaticFindObject fails**: The asset may not be loaded in memory at cast time. Possible fix: use `LoadObject` / `LoadClass` async, or find where the game pre-loads item assets and hook after that.
4. **If StaticFindObject succeeds but SetPropertyValue fails**: The FItemSlot struct field may be read-only or not directly writable via Lua. Possible fix: try writing the full slot struct, or use a different approach (e.g., calling an `AddItem` UFunction directly with the item class).
5. **If OnRep_ItemSlots doesn't exist**: Try `ForceNetUpdate`, `MarkArrayDirty`, or calling `OpenPersonalInventory` a second time after the fix.
6. **Clean up diagnostic/probe code** once persistence is confirmed working.

---

## File Layout

```
PersonalInventoryMod/
  Scripts/
    main.lua           ← full mod code
  enabled.txt          ← UE4SS mod enable file

ue4ss/Mods/PersonalInventoryMod/
  PersonalInventoryMod_<GUID>.json   ← per-character save file

Docs/
  BonesToPersonalInventory.md        ← original concept doc
  PersonalInventoryMod_Summary.md    ← this file
```

---

## UE4SS API Reference (used in this mod)

| API | Usage |
|---|---|
| `RegisterHook(path, pre, post)` | Hook a UFunction |
| `NotifyOnNewObject(class, fn)` | Fire fn when new UObject of class is created |
| `ExecuteInGameThread(fn)` | Run fn on game thread (required for UObject calls from hooks) |
| `FindAllOf(class)` | Find all live UObjects of a class |
| `StaticConstructObject(class, outer, fname)` | Dynamically create a UObject |
| `StaticFindObject(path)` | Look up a UObject by asset path |
| `FName(str)` | Create an FName value |
| `obj:GetPropertyValue(name)` | Read a UPROPERTY by name |
| `obj:SetPropertyValue(name, val)` | Write a UPROPERTY by name |
| `obj:IsValid()` | Check if UObject pointer is non-null |
| `obj:GetFullName()` | Returns `"ClassName /Package/Path.Name"` |
| `obj:GetFName()` | Returns FName userdata |
| `param:get()` | Unwrap a RemoteUnrealParam (hook callback arg) |
