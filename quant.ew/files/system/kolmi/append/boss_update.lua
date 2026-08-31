-- Appended to data/entities/animals/boss_centipede/boss_centipede_update.lua
-- (that script runs once per boss instance, coroutine driven: `execute_times="1"`).

local old_entity_load = EntityLoad

local entity_id = GetUpdatedEntityID()

-- Is this boss instance the DES authority (i.e. the copy whose fight actually counts) ?
-- Replicas get an `ew_gid_lid` variable with value_bool == false (see ewext init_remote_entity).
local function ew_get_var(name)
    for _, v in ipairs(EntityGetComponentIncludingDisabled(entity_id, "VariableStorageComponent") or {}) do
        if ComponentGetValue2(v, "name") == name then
            return v
        end
    end
    return nil
end

local ew_gid_var = ew_get_var("ew_gid_lid")
local ew_is_owner = ew_gid_var == nil or ComponentGetValue2(ew_gid_var, "value_bool")

-- When the boss changes authority, ewext respawns it from the dormant snapshot and vanilla
-- `init_boss()` (which just ran, above this append) resets hp to full. ewext stashes the synced
-- hp in `ew_synced_hp` right before enabling the copy; put it back.
local ew_hp_var = ew_get_var("ew_synced_hp")
if ew_hp_var ~= nil then
    local hp = ComponentGetValue2(ew_hp_var, "value_float")
    EntityRemoveComponent(entity_id, ew_hp_var)
    local dm = EntityGetFirstComponentIncludingDisabled(entity_id, "DamageModelComponent")
    if dm ~= nil and hp ~= nil and hp > 0 then
        local max_hp = ComponentGetValue2(dm, "max_hp")
        if max_hp ~= nil and hp > max_hp then
            hp = max_hp
        end
        ComponentSetValue2(dm, "hp", hp)
    end
end

function EntityLoad(filename, x, y)
    if
        ew_is_owner
        and filename == "data/entities/buildings/teleport_ending_victory_delay.xml"
        and EntityGetFirstComponentIncludingDisabled(entity_id, "StreamingKeepAliveComponent") ~= nil
    then
        CrossCall("ew_kolmi_spawn_portal", x, y)
    end
    return old_entity_load(filename, x, y)
end

local old_main_anim = set_main_animation

function set_main_animation(current_name, next_name)
    old_main_anim(current_name, next_name) -- Doesn't return anything
    if ew_is_owner then
        CrossCall("ew_kolmi_anim", current_name, next_name, is_aggro)
    end
end

local old_shield_on = shield_on
local old_shield_off = shield_off

-- Mirrors vanilla's own `shield_enabled` (this file is executed once, so this persists).
local ew_shield_enabled = false

function shield_on()
    if ew_is_owner and not ew_shield_enabled then
        local newgame_n = tonumber(SessionNumbersGetValue("NEW_GAME_PLUS_COUNT")) or 0
        local orbcount = GameGetOrbCountThisRun() + newgame_n
        CrossCall("ew_kolmi_shield", true, orbcount)
        ew_shield_enabled = true
    end
    return old_shield_on()
end

function shield_off()
    if ew_is_owner and ew_shield_enabled then
        local newgame_n = tonumber(SessionNumbersGetValue("NEW_GAME_PLUS_COUNT")) or 0
        local orbcount = GameGetOrbCountThisRun() + newgame_n
        CrossCall("ew_kolmi_shield", false, orbcount)
        ew_shield_enabled = false
    end
    return old_shield_off()
end
