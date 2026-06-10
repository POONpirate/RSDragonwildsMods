# PersonalInventoryMod — Handoff Prompt

## What we're building

A UE4SS Lua mod for RSDragonwilds (Unreal Engine 4, module name `Dominion`) that hooks the Eye of Oculus spell to open a second 40-slot personal inventory. Items must persist across game sessions in a per-character JSON file. The full technical summary is in `Docs/PersonalInventoryMod_Summary.md`. The code is in `PersonalInventoryMod/Scripts/main.lua`.

## Current state

Almost everything works. The single remaining blocker is **cross-session item persistence**: saved items don't render visually after reloading the game and re-casting.

**What we know for certain:**
- The JSON save file is written correctly with full ItemData asset paths (e.g. `/Game/Gameplay/Items/Consumables/Food/.../ITEM_Consumable_Fruit_Redberry.ITEM_Consumable_Fruit_Redberry`)
- The JSON is read from disk on reload (confirmed in logs)
- `OnInventoryLoadedFromSave:Broadcast()` is called successfully (confirmed)
- The inventory opens empty despite all of the above

**Working hypothesis:** `OnInventoryLoadedFromSave:Broadcast()` rebuilds `ItemSlots` with correct GUID and Count values but leaves the `ItemData` field as a null/invalid UObject reference. The UI requires `ItemData:IsValid() == true` to render an item. We need to manually resolve `ItemData` to a live UObject after the broadcast.

## What was just added (not yet tested)

Diagnostic + fix code in the OPI post-hook (lines ~762–830 of main.lua). After the broadcast, it:
1. Scans each slot for non-zero GUID, logs `ItemData:IsValid()`
2. If invalid: calls `StaticFindObject(item_path)` (also tries `_C` suffix)
3. If found: calls `sl:SetPropertyValue("ItemData", found_obj)`, re-checks validity
4. Calls `comp:OnRep_ItemSlots()` to try forcing UI refresh

## Immediate next step

The user needs to run one test cycle: place items in the second inventory → cast Eye of Oculus twice (to trigger a save) → quit the game → reload → cast once → open the log file and share it.

**The critical log lines to analyze are:**
```
OPI fix: sv[X] GUID.A=XXXXXXXX ItemData:IsValid()=true/false
OPI fix: StaticFindObject OK: /Game/...       (or "failed for:")
OPI fix: SetPropertyValue(ItemData) = true/false
OPI fix: ItemData:IsValid() after set = true/false
OPI fix: OnRep_ItemSlots() = true/false
```

## Decision tree based on log results

**If `ItemData:IsValid()=false` AND `StaticFindObject OK` AND `IsValid() after set=true`:**
→ The fix is working in-memory. Check if items actually render. If still invisible, `OnRep_ItemSlots()` may not exist or may not be enough — try calling `OpenPersonalInventory` a second time, or find the correct UI refresh function.

**If `ItemData:IsValid()=false` AND `StaticFindObject failed`:**
→ The item asset isn't loaded into memory at cast time. Options:
  - Use async `LoadObject`/`LoadClass` if UE4SS exposes it
  - Hook `OnInventoryLoadedFromSave` itself to intercept *after* GUID/Count are set but before the engine tries to resolve ItemData
  - Find which game function pre-loads item assets and hook after that
  - Try `LoadObject` style path with soft reference resolution

**If `ItemData:IsValid()=true` right after broadcast:**
→ Hypothesis was wrong; ItemData IS valid. The problem is something else — the UI widget may need a different trigger to refresh. Look for grid/widget refresh functions on the inventory component or its owning UI widget.

**If `SetPropertyValue(ItemData)=false`:**
→ FItemSlot struct fields may be read-only via Lua. Try writing the full slot struct as a table, or bypass by calling a game UFunction that accepts an item class (like `AddItem(itemClass, slotIndex, count)`) instead of manually setting the struct field.
