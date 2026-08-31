-- Appended to data/entities/animals/boss_centipede/sampo_pickup.lua
--
-- Vanilla `item_pickup` wakes Kolmi by flipping tags on the *local* "sampo_or_boss" entities.
-- In multiplayer the local copy of the boss is very often only a replica (the DES authority for
-- the boss entity lives on another peer), so doing that locally leaves the real boss dormant and
-- every replica immortal ("boss takes no damage / doesn't move / health bar only for the picker").
--
-- We therefore tell every peer that the Sampo was taken (run flag `ew_sampo_picked`, see
-- kolmi.lua); the peer that owns the boss entity performs the vanilla wake-up itself. The vanilla
-- call only runs locally when the local boss is ours, so the ceiling/lava entities it spawns are
-- created exactly once.

-- true if the closest boss is ours (no `ew_gid_lid` variable, or one with value_bool == true);
-- replicas created by ewext carry that variable with value_bool == false.
local function ew_local_boss_is_mine()
    local boss = EntityGetClosestWithTag(0, 0, "boss_centipede")
    if boss == nil or boss == 0 then
        return false
    end
    for _, v in ipairs(EntityGetComponentIncludingDisabled(boss, "VariableStorageComponent") or {}) do
        if ComponentGetValue2(v, "name") == "ew_gid_lid" then
            return ComponentGetValue2(v, "value_bool")
        end
    end
    return true
end

local old = item_pickup
function item_pickup(ent, who, name, run)
    if run ~= nil then
        -- called from kolmi.lua's wake_boss on the boss authority
        old(ent, who, name)
        return
    end
    CrossCall("ew_sampo_picked")
    if ew_local_boss_is_mine() then
        old(ent, who, name)
    end
end
