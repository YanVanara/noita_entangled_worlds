dofile_once("data/scripts/lib/coroutines.lua")

ModLuaFileAppend("data/scripts/biomes/boss_arena.lua", "mods/quant.ew/files/system/kolmi/append/boss_arena.lua")
ModLuaFileAppend(
    "data/entities/animals/boss_centipede/sampo_pickup.lua",
    "mods/quant.ew/files/system/kolmi/append/spawn_kolmi.lua"
)
ModLuaFileAppend(
    "data/entities/animals/boss_centipede/boss_centipede_update.lua",
    "mods/quant.ew/files/system/kolmi/append/boss_update.lua"
)
util.replace_text_in(
    "data/entities/animals/boss_centipede/boss_centipede_before_fight.lua",
    [[local player_nearby = false]],
    [[local player_nearby = #EntityGetInRadiusWithTag(x, y, 128, "ew_peer") > 0]]
)

local rpc = net.new_rpc_namespace()

local module = {}

-- How the fight start works in multiplayer
-- ---------------------------------------
-- The boss entity is synced by ewext (DES): exactly one peer is its authority, everyone else has
-- an immortal replica that just mirrors what the authority does. Vanilla starts the fight from
-- `sampo_pickup.lua` by flipping component tags on the *local* boss entity -- which only has an
-- effect if the picker happens to be the boss authority. Otherwise the real boss stays dormant
-- forever and the fight is "unwinnable" (replicas take no damage, boss doesn't move, health bar
-- only for the picker).
--
-- So: picking the Sampo up (on any peer) sets the run flag `ew_sampo_picked` on every peer
-- (`rpc.sampo_picked`), and every peer keeps checking whether it owns a boss that is still
-- dormant while that flag is set; if so it performs the vanilla wake-up itself
-- (`wake_boss`). This also covers authority transfers: a newly spawned (dormant) copy on the
-- new authority is woken again.

local function is_dormant(boss)
    local hb = EntityGetFirstComponentIncludingDisabled(boss, "BossHealthBarComponent")
    if hb ~= nil and not ComponentGetIsEnabled(hb) then
        return true
    end
    for _, child in ipairs(EntityGetAllChildren(boss) or {}) do
        if EntityHasTag(child, "protection") then
            return true
        end
    end
    return false
end

local vanilla_sampo_pickup

local function wake_boss(boss)
    -- Vanilla `item_pickup` needs the item entity only for its position (music / effects) and
    -- bails out if it can't find a "reference" entity; feed it a throwaway entity at the boss
    -- (same trick as ending.lua's "totally_sampo").
    if #(EntityGetWithTag("reference") or {}) == 0 then
        return false
    end
    if vanilla_sampo_pickup == nil then
        -- load once: every dofile would stack another append/spawn_kolmi.lua wrapper
        dofile("data/entities/animals/boss_centipede/sampo_pickup.lua")
        vanilla_sampo_pickup = item_pickup
    end
    local x, y = EntityGetTransform(boss)
    local dummy = EntityCreateNew("ew_sampo_pickup_dummy")
    EntitySetTransform(dummy, x, y)
    -- 4th argument: skip our own wrapper in append/spawn_kolmi.lua
    vanilla_sampo_pickup(dummy, nil, nil, true)
    EntityKill(dummy)
    return true
end

local last_wake_attempt = -1000

function module.on_world_update()
    local frame = GameGetFrameNum()
    if frame % 15 ~= 7 or not GameHasFlagRun("ew_sampo_picked") then
        return
    end
    if frame - last_wake_attempt < 60 then
        return
    end
    for _, boss in ipairs(EntityGetWithTag("boss_centipede") or {}) do
        if util.do_i_own(boss) and is_dormant(boss) then
            last_wake_attempt = frame
            if wake_boss(boss) then
                print("[ew] Kolmi " .. boss .. " woken up (we are its authority)")
            end
        end
    end
end

rpc.opts_reliable()
rpc.opts_everywhere()
function rpc.sampo_picked()
    if GameHasFlagRun("ew_sampo_picked") then
        return
    end
    GameAddFlagRun("ew_sampo_picked")
    -- The per-client bits of vanilla sampo_pickup.lua that everyone should get, not only the
    -- machine running the actual wake-up: battle music and the FINAL_BOSS_ACTIVE global.
    GlobalsSetValue("FINAL_BOSS_ACTIVE", "1")
    if ctx.my_player ~= nil and ctx.my_player.entity ~= nil and EntityGetIsAlive(ctx.my_player.entity) then
        local x, y = EntityGetTransform(ctx.my_player.entity)
        GameTriggerMusicFadeOutAndDequeueAll(10.0)
        GameTriggerMusicEvent("music/boss_arena/battle", false, x, y)
    end
end

rpc.opts_reliable()
function rpc.spawn_portal(x, y)
    EntityLoad("data/entities/buildings/teleport_ending_victory_delay.xml", x, y)
end

-- The boss whose fight actually counts is the one we own; the RPCs below only exist to make
-- *replicas* look right, so they must never touch a boss we are the authority of (vanilla logic
-- drives that one). Doing so used to e.g. attach an extra, permanently enabled shield to a
-- still dormant authoritative boss.
local function replica_kolmi()
    local kolmi = EntityGetClosestWithTag(0, 0, "boss_centipede")
    if kolmi == nil or kolmi == 0 or util.do_i_own(kolmi) then
        return nil
    end
    return kolmi
end

rpc.opts_reliable()
function rpc.kolmi_anim(current_name, next_name, is_aggro)
    local kolmi = replica_kolmi()
    if kolmi == nil then
        return
    end
    if not is_aggro then
        GamePlayAnimation(kolmi, current_name, 0, next_name, 0)
    else
        -- aggro overrides animations
        GamePlayAnimation(kolmi, "aggro", 0, "aggro", 0)
    end
end

local function switch_shield(entity_id, is_on)
    local children = EntityGetAllChildren(entity_id)
    if children == nil then
        return
    end
    for _, v in ipairs(children) do
        if EntityGetName(v) == "shield_entity" then
            if is_on then
                EntitySetComponentsWithTagEnabled(v, "shield", true)
                -- muzzle flash
                local x, y = EntityGetTransform(entity_id)
                EntityLoad("data/entities/particles/muzzle_flashes/muzzle_flash_circular_large_pink_reverse.xml", x, y)
                GameEntityPlaySound(v, "activate")
                return true
            else
                EntitySetComponentsWithTagEnabled(v, "shield", false)
                -- muzzle flash
                local x, y = EntityGetTransform(entity_id)
                EntityLoad("data/entities/particles/muzzle_flashes/muzzle_flash_circular_large_pink.xml", x, y)
                GameEntityPlaySound(v, "deactivate")
                return true
            end
        end
    end
end

rpc.opts_reliable()
function rpc.kolmi_shield(is_on, orbcount)
    local kolmi = replica_kolmi()
    if kolmi == nil then
        return
    end

    if switch_shield(kolmi, is_on) then
        return
    end

    -- No shield child on this replica yet (vanilla creates it in init_boss on the authority).
    local pos_x, pos_y = EntityGetTransform(kolmi)
    if orbcount == 0 then
        EntityAddChild(
            kolmi,
            EntityLoad("data/entities/animals/boss_centipede/boss_centipede_shield_weak.xml", pos_x, pos_y)
        )
    else
        EntityAddChild(
            kolmi,
            EntityLoad("data/entities/animals/boss_centipede/boss_centipede_shield_strong.xml", pos_x, pos_y)
        )
    end
    switch_shield(kolmi, is_on)
end

util.add_cross_call("ew_sampo_picked", rpc.sampo_picked)

util.add_cross_call("ew_kolmi_spawn_portal", rpc.spawn_portal)

util.add_cross_call("ew_kolmi_anim", rpc.kolmi_anim)

util.add_cross_call("ew_kolmi_shield", rpc.kolmi_shield)

return module
