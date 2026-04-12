-- Author: ImperialSkoom

local mod = get_mod("HoldFire")

local Breed = require("scripts/utilities/breed")
local HazardPropSettings = require("scripts/settings/hazard_prop/hazard_prop_settings")
local WeaponTemplate = require("scripts/utilities/weapon/weapon_template")

-- Performance: Cache frequently used globals and functions
local HEALTH_ALIVE = HEALTH_ALIVE
local Managers = Managers
local ScriptUnit = ScriptUnit
local Unit = Unit
local Actor = Actor
local PhysicsWorld = PhysicsWorld
local Vector3 = Vector3
local string_find = string.find
local table_clear = table.clear
local math_clamp = math.clamp

local Unit_alive = Unit.alive
local ScriptUnit_has_extension = ScriptUnit.has_extension
local WeaponTemplate_is_ranged = WeaponTemplate.is_ranged
local WeaponTemplate_current_weapon_template = WeaponTemplate.current_weapon_template

local HAZARD_CONTENT = HazardPropSettings.hazard_content
local HAZARD_STATE = HazardPropSettings.hazard_state
local HERETIC_IDOL_COLLECTIBLE_TYPE = "heretic_idol"
local DESTRUCTIBLE_BROADPHASE_CATEGORY = "destructibles"
local DESTRUCTIBLE_NEARBY_RADIUS = 2.5
local TARGETABLE_HAZARD_STATE = {
    [HAZARD_STATE.idle] = true,
    [HAZARD_STATE.triggered] = true,
}

local player_smart_targeting_extension = nil
local player_weapon_extension = nil
local cached_priority_target = false
local cached_priority_target_frame = -1
local cached_weapon_profile_name = "global_ranged"
local cached_weapon_display_name = "global_ranged"
local setting_enabled = true
local applying_weapon_profile = false
local can_block_cached = false

-- Performance: Reusable tables to avoid allocation in hot paths
local _profile_identifiers = {}
local _profile_seen = {}
local current_settings = {}

local PER_WEAPON_SETTING_DEFAULTS
local ALL_SETTING_DEFAULTS
local PROFILE_KEY_SCHEMA_VERSION = 3

-- Helper functions
local function clone_setting_value(value)
    if type(value) ~= "table" then return value end
    local clone = {}
    for key, entry in pairs(value) do
        clone[key] = clone_setting_value(entry)
    end
    return clone
end

local function setting_values_equal(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= "table" then return left == right end
    for key, value in pairs(left) do
        if not setting_values_equal(value, right[key]) then return false end
    end
    for key, value in pairs(right) do
        if not setting_values_equal(left[key], value) then return false end
    end
    return true
end

local function weapon_profiles()
    local profiles = mod:get("weapon_profiles")
    return type(profiles) == "table" and profiles or {}
end

local function save_weapon_profiles(profiles)
    mod:set("weapon_profiles", profiles, true)
end

local function get_dynamic_weapon_ids()
    local ids = mod:get("dynamic_weapon_ids")
    return type(ids) == "table" and ids or {}
end

local function save_dynamic_weapon_ids(ids)
    mod:set("dynamic_weapon_ids", ids, true)
end

local function register_dynamic_weapon_id(id)
    if not id or id == "" or id == "global_ranged" then return end

    local dynamic_ids = get_dynamic_weapon_ids()
    for _, dynamic_id in ipairs(dynamic_ids) do
        if dynamic_id == id then return end
    end

    table.insert(dynamic_ids, id)
    save_dynamic_weapon_ids(dynamic_ids)
end

local function remove_weapon_profile(weapon_name)
    if not weapon_name or weapon_name == "" then return end
    local profiles = weapon_profiles()
    if profiles[weapon_name] then
        profiles[weapon_name] = nil
        save_weapon_profiles(profiles)
    end
end

local function ensure_weapon_profile(weapon_name)
    if not weapon_name or weapon_name == "" then return nil end
    local profiles = weapon_profiles()
    local profile = profiles[weapon_name]
    if profile then return profile end

    profile = {}
    local global_profile = profiles["global_ranged"]

    for setting_id, default_value in pairs(PER_WEAPON_SETTING_DEFAULTS) do
        local base_value = default_value
        if weapon_name ~= "global_ranged" and global_profile and global_profile[setting_id] ~= nil then
            base_value = global_profile[setting_id]
        end
        profile[setting_id] = clone_setting_value(base_value)
    end
    return profile
end

local function persist_weapon_profile_setting(weapon_name, setting_id, value)
    if not weapon_name or weapon_name == "" or PER_WEAPON_SETTING_DEFAULTS[setting_id] == nil then return end
    local profiles = weapon_profiles()
    local profile = profiles[weapon_name] or {}
    profile[setting_id] = clone_setting_value(value)
    profiles[weapon_name] = profile
    save_weapon_profiles(profiles)
end

local function persist_current_weapon_profile(weapon_name)
    weapon_name = weapon_name or cached_weapon_profile_name
    if not weapon_name then return end
    local profiles = weapon_profiles()
    local profile = profiles[weapon_name] or {}
    local changed = false
    for setting_id, _ in pairs(PER_WEAPON_SETTING_DEFAULTS) do
        local value = current_settings[setting_id]
        if value == nil then value = mod:get(setting_id) end
        if not setting_values_equal(profile[setting_id], value) then
            profile[setting_id] = clone_setting_value(value)
            changed = true
        end
    end
    if changed then
        profiles[weapon_name] = profile
        save_weapon_profiles(profiles)
    end
end


local function reset_weapon_state()
    can_block_cached = false
    _last_weapon_template = nil
    _last_ranged_weapon = nil
    cached_priority_target_frame = -1
    cached_weapon_profile_name = "global_ranged"
    cached_weapon_display_name = "global_ranged"
end


local function apply_weapon_profile(weapon_name, display_name)
    -- Update indicator dropdown
    local selection_name = display_name or weapon_name
    cached_weapon_display_name = selection_name
    if selection_name ~= mod:get("ranged_weapon_selection") then
        mod:set("ranged_weapon_selection", selection_name, false)
    end

    local profile = ensure_weapon_profile(weapon_name)
    if not profile then return end

    applying_weapon_profile = true

    for setting_id, default_value in pairs(PER_WEAPON_SETTING_DEFAULTS) do
        local value = profile[setting_id]
        if value == nil then value = default_value end
        local cloned = clone_setting_value(value)
        mod:set(setting_id, cloned)
        current_settings[setting_id] = cloned
    end
    applying_weapon_profile = false
end


local function setting_value(setting_id)
    -- This function was removed for performance reasons.
    -- Settings are now cached in the 'current_settings' table to avoid frequent mod:get calls.
end

local function current_weapon_settings_match_template()
    local profiles = weapon_profiles()
    local template
    if cached_weapon_profile_name == "global_ranged" then
        template = PER_WEAPON_SETTING_DEFAULTS
    else
        template = profiles["global_ranged"] or PER_WEAPON_SETTING_DEFAULTS
    end

    for setting_id, _ in pairs(PER_WEAPON_SETTING_DEFAULTS) do
        local current_value = current_settings[setting_id]
        local template_value = template[setting_id]
        if not setting_values_equal(current_value, template_value) then
            return false
        end
    end
    return true
end

local function clear_all_weapon_profiles()
    -- This function was removed for performance reasons.
    -- Logic is now inlined where needed as save_weapon_profiles({}).
end

local function ensure_profile_key_schema()
    -- This function was removed for performance reasons.
    -- The schema check logic was moved to the end of the file to run once during initialization.
end

local ENEMY_SMART_TARGETING_TEMPLATE = {
    precision_target = {
        max_range = 9999,
        min_range = 1,
        smart_tagging = true,
        -- Keep the aim gate tighter than TriggerFire so "near the head" does not
        -- count as a valid shot when the projectile path would still miss.
        within_distance_to_box_x = 0.03,
        within_distance_to_box_y = 0.015,
    },
}

local OBJECT_SMART_TARGETING_TEMPLATE = {
    precision_target = {
        max_range = 9999,
        min_range = 1,
        smart_tagging = true,
        -- Destructibles such as idols and barrels can feel overly picky with a
        -- much tighter gate than enemies, so keep them slightly strict but not
        -- so strict that center-mass shots get rejected.
        within_distance_to_box_x = 0.03,
        within_distance_to_box_y = 0.012,
    },
}

local CROSSHAIR_READY_RED = { 255, 220, 32, 32 }

local BLOCKED_INPUTS = {
    action_one_hold = true,
    action_one_pressed = true,
}

PER_WEAPON_SETTING_DEFAULTS = {
    ads_filter = "ads_hip",
    target_radius = 0.10,
    destructible_radius = 0.10,
    target_elites = true,
    target_specials = true,
    target_bosses = true,
    target_normals = true,
    target_destructibles = true,
}

ALL_SETTING_DEFAULTS = {
    enable_mod = true,
    enable_skitarius_omnissiah_hook = true,
    load_current_weapon_settings = false,
    ranged_weapon_selection = "global_ranged",
    toggle_mod_keybind = {},
    toggle_ads_filter_keybind = {},
    purge_weapon_profiles = false,
    ads_filter = "ads_hip",
    target_radius = 0.10,
    destructible_radius = 0.10,
    target_elites = true,
    target_specials = true,
    target_bosses = true,
    target_normals = true,
    target_destructibles = true,
}

local BLOCKED_ACTION_TOKENS = {
    shoot = true,
    rapid = true,
    trigger = true,
    flame = true,
}

local MAX_TARGET_RAYCAST_DISTANCE = 9999
local SHOOTING_RAYCAST_FILTER = "filter_player_character_shooting_raycast"
local NEARBY_DESTRUCTIBLE_RESULTS = {}

-- Performance: Current settings cache to avoid mod:get calls in hot paths
for k, v in pairs(ALL_SETTING_DEFAULTS) do
    current_settings[k] = v
end



local function refresh_enabled_setting()
    local stored_value = mod:get("enable_mod")
    setting_enabled = stored_value == nil and true or stored_value
    return setting_enabled
end

local function reset_cached_targeting()
    -- This function was removed for performance reasons.
    -- Targeting cache is now reset by setting cached_priority_target_frame to -1.
end

local function ui_using_input()
    return Managers and Managers.ui and Managers.ui:using_input() or false
end

local function local_player()
    local player_manager = Managers and Managers.player
    return player_manager and player_manager:local_player_safe(1)
end

local function gameplay_input_service()
    local input_manager = Managers and Managers.input
    return input_manager and input_manager:get_input_service("Ingame")
end

local function current_ads_input_state()
    local service = gameplay_input_service()
    if not service then
        return false
    end

    local ads = service:get("action_two_hold")
    if ads == nil then
        ads = service:get("action_two_pressed")
    end

    return ads ~= nil and ads ~= false
end

local function local_player_unit()
    local player = local_player()
    return player and player.player_unit
end

local function current_weapon_template()
    if player_weapon_extension then
        local inventory = player_weapon_extension._inventory_component
        local wielded_slot = inventory and inventory.wielded_slot
        local weapons = player_weapon_extension._weapons
        local wielded_weapon = wielded_slot and weapons and weapons[wielded_slot]
        if wielded_weapon and wielded_weapon.weapon_template then
            return wielded_weapon.weapon_template
        end
    end
    if player_smart_targeting_extension then
        local weapon_action_component = player_smart_targeting_extension._weapon_action_component
        if weapon_action_component then
            return WeaponTemplate_current_weapon_template(weapon_action_component)
        end
    end
    return nil
end

local function current_weapon_name()
    -- This function was removed for performance reasons.
    -- Logic is now inlined or simplified within current_weapon_profile_name.
end

local function current_ranged_slot_weapon()
    return player_weapon_extension and player_weapon_extension._weapons and
        player_weapon_extension._weapons.slot_secondary
end

local function current_visual_loadout_data()
    local player_unit = local_player_unit()
    local visual_loadout = player_unit and ScriptUnit_has_extension(player_unit, "visual_loadout_system")
    local inventory = visual_loadout and visual_loadout._inventory_component
    local inventory_data = inventory and inventory.__data
    return inventory_data and inventory_data[1]
end

local function current_equipped_ranged_reference()
    local data = current_visual_loadout_data()
    local reference = data and data.slot_secondary
    return type(reference) == "string" and reference ~= "" and reference or nil
end

local function current_equipped_ranged_template()
    local player_unit = local_player_unit()
    local weapon_extension = player_weapon_extension or (player_unit and ScriptUnit_has_extension(player_unit, "weapon_system"))
    local weapons = weapon_extension and weapon_extension._weapons
    local ranged_weapon = weapons and weapons.slot_secondary
    return ranged_weapon and ranged_weapon.weapon_template
end

local function current_equipped_ranged_name()
    -- This function was removed for performance reasons.
    -- Logic is now simplified within current_weapon_profile_name.
end

local function append_unique_identifier(identifiers, seen, value)
    -- This function was removed for performance reasons.
    -- Unique identifier building is now inlined into current_weapon_profile_name.
end

local function nested_identifier_value(root, path)
    local value = root
    for i = 1, #path do
        if type(value) ~= "table" then return nil end
        value = value[path[i]]
    end
    return value
end

local STABLE_ID_PATHS = {
    { "gear_id" }, { "uuid" }, { "item", "gear_id" }, { "item", "uuid" },
    { "item",   "__raw", "gear_id" }, { "item", "__raw", "uuid" },
    { "inventory_item", "gear_id" }, { "inventory_item", "uuid" },
    { "inventory_item", "__raw",  "gear_id" }, { "inventory_item", "__raw", "uuid" },
}

local function detected_weapon_profile_name()
    local wielded_template = current_weapon_template()
    local secondary_weapon = current_ranged_slot_weapon()
    
    local subject_weapon = nil
    local subject_template = nil
    local subject_reference = nil
    
    if wielded_template and WeaponTemplate_is_ranged(wielded_template) then
        subject_template = wielded_template
        if secondary_weapon and secondary_weapon.weapon_template == wielded_template then
            subject_weapon = secondary_weapon
            subject_reference = current_equipped_ranged_reference()
        end
    else
        subject_weapon = secondary_weapon
        subject_template = subject_weapon and subject_weapon.weapon_template or current_equipped_ranged_template()
        subject_reference = current_equipped_ranged_reference()
    end

    if not subject_weapon and not subject_template and not subject_reference then return nil, nil end

    table_clear(_profile_identifiers)
    table_clear(_profile_seen)

    local count = 0
    local function add_id(val)
        if val and val ~= "" and not _profile_seen[val] then
            count = count + 1
            _profile_identifiers[count] = tostring(val)
            _profile_seen[val] = true
        end
    end

    if subject_weapon then
        for i = 1, #STABLE_ID_PATHS do
            add_id(nested_identifier_value(subject_weapon, STABLE_ID_PATHS[i]))
        end
    end
    
    add_id(subject_reference)
    add_id(subject_template and subject_template.name)
    
    if subject_weapon and subject_weapon.name then
        add_id(subject_weapon.name)
    end

    if count == 0 and subject_template then
        add_id(subject_template.base_template_name)
    end

    local full_id = count > 0 and table.concat(_profile_identifiers, "|", 1, count) or nil
    local display_name = (subject_template and (subject_template.name or subject_template.base_template_name)) or (subject_weapon and subject_weapon.name) or subject_reference

    if display_name then
        register_dynamic_weapon_id(display_name)
    end

    return full_id, display_name
end

local function current_weapon_profile_name()
    local player_unit = local_player_unit()
    if not player_unit then
        return "global_ranged", "global_ranged"
    end

    local detected, detected_display = detected_weapon_profile_name()
    local selected = mod:get("ranged_weapon_selection")

    -- In mission, prioritize detected weapon to allow auto-switching
    if not ui_using_input() then
        if detected then return detected, detected_display end
    end

    -- In settings menu: prioritize detected weapon if available to ensure it's on the equipped weapon
    if detected then return detected, detected_display end

    -- Fallback when no weapon detected (shouldn't happen in world, but just in case)
    return (selected and selected ~= "") and selected or "global_ranged", selected
end



local function toggle_target_setting(setting_id, enabled_label)
    local detected_name, detected_display = detected_weapon_profile_name()
    local weapon_name = detected_name or "global_ranged"
    local weapon_display = detected_display or "Global"

    local new_value
    if weapon_name == "global_ranged" then
        new_value = not current_settings[setting_id]
    else
        local profiles = weapon_profiles()
        local profile = ensure_weapon_profile(weapon_name)
        new_value = not profile[setting_id]
        profile[setting_id] = new_value
        profiles[weapon_name] = profile
        save_weapon_profiles(profiles)
    end

    if weapon_name == cached_weapon_profile_name then
        applying_weapon_profile = true
        mod:set(setting_id, new_value)
        current_settings[setting_id] = new_value
        applying_weapon_profile = false
    end

    cached_priority_target_frame = -1
    mod:echo("%s (%s) %s", enabled_label, weapon_display, new_value and "enabled" or "disabled")
end

local function current_ads_input(input_service)
    -- This function was removed for performance reasons.
    -- Logic is now inlined where needed.
end

local function current_live_ads_input()
    -- This function was removed for performance reasons.
    -- Logic is now inlined where needed.
end

local function current_skitarius_ads_input(omnissiah)
    -- This function was removed for performance reasons.
    -- Logic is now inlined where needed.
end

local function current_ads_filter()
    -- This function was removed for performance reasons.
    -- Filter value is now accessed via current_settings.ads_filter.
end

local function normalize_ads_state(is_adsing)
    -- This function was removed for performance reasons.
    -- State normalization is now inlined.
end

local function ads_filter_allows(is_adsing)
    local filter = current_settings.ads_filter
    if filter == "disabled" then return false end
    if filter == "ads_only" then return is_adsing end
    if filter == "hip_only" then return not is_adsing end
    return true
end

local function current_enemy_lock_tolerance()
    -- This function was removed for performance reasons.
    -- Tolerance calculation is now inlined into hovered_priority_target.
end

local function current_destructible_lock_tolerance()
    -- This function was removed for performance reasons.
    -- Tolerance calculation is now inlined into hovered_priority_target.
end

local function is_crosshair_hit_indicator_style(style_name)
    -- This function was removed for performance reasons.
    -- Style checks are now inlined into the crosshair update hook.
end

local function clone_color(color)
    -- This function was removed for performance reasons.
    -- Color cloning is now performed in-place where needed.
end

local _last_weapon_template = nil
local _last_ranged_weapon = nil

-- This function was added for performance reasons to cache weapon-related data and
-- minimize expensive checks during fixed_update and input hooks.
local function update_weapon_cache()
    local player_unit = local_player_unit()
    if not player_unit or (HEALTH_ALIVE and not HEALTH_ALIVE[player_unit]) or not Unit_alive(player_unit) then
        can_block_cached = false
        _last_weapon_template = nil
        _last_ranged_weapon = nil
        return
    end

    local weapon_template = current_weapon_template()
    local ranged_weapon = current_ranged_slot_weapon()

    if weapon_template == _last_weapon_template and ranged_weapon == _last_ranged_weapon then
        return
    end

    -- Save old weapon profile before switching
    if cached_weapon_profile_name then
        persist_current_weapon_profile(cached_weapon_profile_name)
    end

    _last_weapon_template = weapon_template
    _last_ranged_weapon = ranged_weapon

    if not weapon_template or not WeaponTemplate_is_ranged(weapon_template) then
        can_block_cached = false
        return
    end

    can_block_cached = true

    -- Update profile name and apply settings
    local profile_name, display_name = current_weapon_profile_name()
    if profile_name ~= cached_weapon_profile_name then
        cached_weapon_profile_name = profile_name
        apply_weapon_profile(profile_name, display_name)
    end
end

local function can_block_current_weapon()
    -- This function was removed for performance reasons.
    -- Blocking state is now managed by update_weapon_cache and the can_block_cached flag.
end

local function refresh_weapon_logic()
    -- This function was removed for performance reasons.
    -- Logic is now handled by update_weapon_cache.
end

mod.toggle_target_elites = function()
    toggle_target_setting("target_elites", "HoldFire elites")
end

mod.toggle_target_specials = function()
    toggle_target_setting("target_specials", "HoldFire specials")
end

mod.toggle_target_bosses = function()
    toggle_target_setting("target_bosses", "HoldFire bosses")
end

mod.toggle_target_normals = function()
    toggle_target_setting("target_normals", "HoldFire normals")
end

mod.toggle_target_destructibles = function()
    toggle_target_setting("target_destructibles", "HoldFire destructibles")
end

mod.toggle_ads_filter_enabled = function()
    local detected_name, detected_display = detected_weapon_profile_name()
    local weapon_name = detected_name or "global_ranged"
    local weapon_display = detected_display or "Global"

    local profiles = weapon_profiles()
    local profile = ensure_weapon_profile(weapon_name)
    local current_filter = profile.ads_filter

    if current_filter ~= "disabled" then
        profile.ads_filter_last_on_value = current_filter
        profile.ads_filter = "disabled"
    else
        local last_on = profile.ads_filter_last_on_value or "ads_hip"
        profile.ads_filter = last_on
        profile.ads_filter_last_on_value = nil
    end

    profiles[weapon_name] = profile
    save_weapon_profiles(profiles)

    local filter_text = mod:localize(profile.ads_filter)
    mod:notify(string.format("HoldFire ADS Filter (%s): %s", weapon_display, filter_text))

    -- Force refresh of current settings if this is the active weapon
    if weapon_name == cached_weapon_profile_name then
        applying_weapon_profile = true
        mod:set("ads_filter", profile.ads_filter)
        current_settings.ads_filter = profile.ads_filter
        applying_weapon_profile = false
    end
end

function mod.toggle_mod_enabled()
    setting_enabled = not refresh_enabled_setting()
    mod:set("enable_mod", setting_enabled)
    cached_priority_target_frame = -1
    mod:notify(string.format("HoldFire: %s", setting_enabled and "Enabled" or "Disabled"))
end

local function is_blocked_shot_action(action_name)
    -- This function was removed for performance reasons.
    -- Action check logic is now inlined into the start_action hook.
end

local function is_ads_shot_action(action_name)
    -- This function was removed for performance reasons.
    -- ADS action check logic is now inlined into the start_action hook.
end

local function get_target_breed_data(target_unit)
    local unit_data_extension = target_unit and ScriptUnit_has_extension(target_unit, "unit_data_system")
    return unit_data_extension and unit_data_extension:breed()
end

local function is_target_alive(target_unit)
    -- This function was removed for performance reasons.
    -- Aliveness checks are now inlined into targeting logic.
end

local function is_pickup_unit(target_unit)
    -- This function was removed for performance reasons.
    -- Pickup checks are now inlined into is_destructible_target.
end

local function is_health_station_unit(target_unit)
    -- This function was removed for performance reasons.
    -- Health station checks are now inlined into is_destructible_target.
end

local function unit_data_value(target_unit, key)
    -- This function was removed for performance reasons.
    -- Unit data access is now inlined.
end

local function update_precision_target(template)
    -- This function was removed for performance reasons.
    -- Precision targeting updates are now inlined into hovered_priority_target.
end

local function is_intact_destructible(target_unit, destructible_extension)
    -- This function was removed for performance reasons.
    -- Destructible state checks are now inlined into is_destructible_target.
end

local function is_heretic_idol_target(target_unit)
    -- This function was removed for performance reasons.
    -- Idol targeting logic is now inlined into is_destructible_target.
end

local function is_targetable_hazard_prop(target_unit)
    -- This function was removed for performance reasons.
    -- Hazard prop checks are now inlined into is_destructible_target.
end

local function is_destructible_target(target_unit)
    if not target_unit or not Unit_alive(target_unit) then return false end
    if ScriptUnit_has_extension(target_unit, "health_station_system") then return false end
    if (Unit.has_data(target_unit, "is_pickup") and Unit.get_data(target_unit, "is_pickup")) or (Unit.has_data(target_unit, "pickup_type") and Unit.get_data(target_unit, "pickup_type") ~= nil) then return false end

    -- Idol/Destructible check
    local destructible_ext = ScriptUnit_has_extension(target_unit, "destructible_system")
    if destructible_ext then
        local collectible_type = Unit.has_data(target_unit, "collectible_type") and
            Unit.get_data(target_unit, "collectible_type")
        if collectible_type == HERETIC_IDOL_COLLECTIBLE_TYPE or destructible_ext._collectible_data then
            local info = destructible_ext._destruction_info
            return not info or (info.current_stage_index or 0) > 0
        end
    end

    -- Hazard Prop
    local hazard_ext = ScriptUnit_has_extension(target_unit, "hazard_prop_system")
    if hazard_ext then
        local content = hazard_ext:content()
        return content ~= HAZARD_CONTENT.none and content ~= HAZARD_CONTENT.undefined and
            TARGETABLE_HAZARD_STATE[hazard_ext:current_state()]
    end

    return false
end

local function nearby_destructible_target(hit_position, ignored_unit)
    -- This function was removed for performance reasons.
    -- Nearby destructible search is now inlined into resolve_destructible_target.
end

local function resolve_destructible_target(target_unit, target_position)
    if is_destructible_target(target_unit) then return target_unit end

    local pos = target_position or
        (target_unit and ((POSITION_LOOKUP and POSITION_LOOKUP[target_unit]) or Unit.world_position(target_unit, 1)))
    if not pos then return nil end

    local broadphase_system = Managers.state.extension:system("broadphase_system")
    local broadphase = broadphase_system and broadphase_system.broadphase
    if not broadphase then return nil end

    table_clear(NEARBY_DESTRUCTIBLE_RESULTS)
    local num = broadphase:query(pos, DESTRUCTIBLE_NEARBY_RADIUS, NEARBY_DESTRUCTIBLE_RESULTS,
        DESTRUCTIBLE_BROADPHASE_CATEGORY)
    if not num or num <= 0 then return nil end

    local best_unit, best_dist_sq = nil, math.huge
    for i = 1, num do
        local u = NEARBY_DESTRUCTIBLE_RESULTS[i]
        if u ~= target_unit and is_destructible_target(u) then
            local u_pos = (POSITION_LOOKUP and POSITION_LOOKUP[u]) or Unit.world_position(u, 1)
            local d_sq = Vector3.distance_squared(u_pos, pos)
            if d_sq < best_dist_sq then
                best_unit, best_dist_sq = u, d_sq
            end
        end
    end
    return best_unit
end

local function raycasted_destructible_target()
    if not player_smart_targeting_extension then
        return false
    end

    local physics_world = player_smart_targeting_extension._physics_world
    local ray_origin, forward = player_smart_targeting_extension:_targeting_parameters()
    local hits = PhysicsWorld.raycast(physics_world, ray_origin, forward, MAX_TARGET_RAYCAST_DISTANCE, "all", "types",
        "both", "collision_filter", SHOOTING_RAYCAST_FILTER)
    if not hits then return false end

    local player_unit = local_player_unit()
    for i = 1, #hits do
        local hit = hits[i]
        local h_pos = hit.position or hit[1]
        local h_unit = hit.actor and Actor.unit(hit.actor)
        if h_unit ~= player_unit then
            if resolve_destructible_target(h_unit, h_pos) then return true end
        end
    end
    return false
end

local function is_eligible_target(target_unit, breed_data)
    -- This function was removed for performance reasons.
    -- Eligibility checks are now inlined into hovered_priority_target.
end

local function hovered_priority_target()
    if not player_smart_targeting_extension then return false end

    -- Performance: Frame-based caching
    local current_frame = player_smart_targeting_extension._latest_fixed_frame
    if current_frame and current_frame == cached_priority_target_frame then
        return cached_priority_target
    end
    cached_priority_target_frame = current_frame

    -- Performance: Early exit if all target types are disabled
    local s = current_settings
    if not s.target_elites and not s.target_specials and not s.target_bosses
        and not s.target_normals and not s.target_destructibles then
        cached_priority_target = false
        return false
    end

    local h_tol = math_clamp(s.target_radius or 0.1, 0.01, 0.2)
    local v_tol = math_clamp(h_tol * 0.5, 0.008, 0.1)
    ENEMY_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_x = h_tol
    ENEMY_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_y = v_tol
    ENEMY_SMART_TARGETING_TEMPLATE.precision_target.smart_tagging = not s.target_normals

    local ray_origin, forward, right, up = player_smart_targeting_extension:_targeting_parameters()
    player_smart_targeting_extension._precision_target_aim_assist:update_precision_target(
        player_smart_targeting_extension._unit, ENEMY_SMART_TARGETING_TEMPLATE, ray_origin, forward, right, up,
        player_smart_targeting_extension._smart_tag_targeting_data, current_frame,
        player_smart_targeting_extension._visibility_cache, player_smart_targeting_extension._visibility_check_frame
    )

    local target_data = player_smart_targeting_extension:smart_tag_targeting_data()
    local target_unit = target_data and target_data.unit
    local breed = get_target_breed_data(target_unit)
    local is_alive = target_unit and (not HEALTH_ALIVE or HEALTH_ALIVE[target_unit] ~= false)

    if is_alive and breed then
        local tags = breed.tags or {}
        if breed.is_boss then
            cached_priority_target = s.target_bosses
        elseif tags.special then
            cached_priority_target = s.target_specials
        elseif tags.elite then
            cached_priority_target = s.target_elites
        else
            cached_priority_target = s.target_normals
        end
    else
        if not s.target_destructibles then
            cached_priority_target = false
        else
            local dh_tol = math_clamp(s.destructible_radius or 0.1, 0.01, 0.2)
            local dv_tol = math_clamp(dh_tol * 0.4, 0.006, 0.08)
            OBJECT_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_x = dh_tol
            OBJECT_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_y = dv_tol

            player_smart_targeting_extension._precision_target_aim_assist:update_precision_target(
                player_smart_targeting_extension._unit, OBJECT_SMART_TARGETING_TEMPLATE, ray_origin, forward, right, up,
                player_smart_targeting_extension._smart_tag_targeting_data, current_frame,
                player_smart_targeting_extension._visibility_cache,
                player_smart_targeting_extension._visibility_check_frame
            )
            target_data = player_smart_targeting_extension:smart_tag_targeting_data()
            target_unit = target_data and target_data.unit
            cached_priority_target = resolve_destructible_target(target_unit) ~= nil or raycasted_destructible_target()

            -- Improved destructible check: If still false, try a wider raycast for "cursed" destructibles
            if not cached_priority_target then
                -- Briefly increase tolerance for a second check
                OBJECT_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_x = dh_tol * 1.5
                OBJECT_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_y = dv_tol * 1.5
                player_smart_targeting_extension._precision_target_aim_assist:update_precision_target(
                    player_smart_targeting_extension._unit, OBJECT_SMART_TARGETING_TEMPLATE, ray_origin, forward, right,
                    up,
                    player_smart_targeting_extension._smart_tag_targeting_data, current_frame,
                    player_smart_targeting_extension._visibility_cache,
                    player_smart_targeting_extension._visibility_check_frame
                )
                target_data = player_smart_targeting_extension:smart_tag_targeting_data()
                target_unit = target_data and target_data.unit
                cached_priority_target = resolve_destructible_target(target_unit) ~= nil
            end
        end
    end

    return cached_priority_target
end

local function update_holdfire_state()
    -- This function was removed for performance reasons.
    -- Direct calls to hovered_priority_target are now used.
end


local function should_allow_fire_now()
    if not setting_enabled or not mod:is_enabled() then return true end
    if ui_using_input() then return true end
    if not can_block_cached or not ads_filter_allows(current_ads_input_state()) then return true end
    return hovered_priority_target()
end


local function should_tint_crosshair()
    -- This function was removed for performance reasons.
    -- Tinting logic is now inlined into the crosshair update hook.
end

local function apply_crosshair_tint(widget, tint_color)
    -- This function was removed for performance reasons.
    -- Crosshair tinting is now handled directly in the crosshair update hook.
end

local function input_hook(func, self, action_name)
    local value = func(self, action_name)
    if not value or not BLOCKED_INPUTS[action_name] then return value end

    if not should_allow_fire_now() then return false end
    return value
end


mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "init", function(self)
    if self._player and self._player.viewport_name == "player1" then
        player_smart_targeting_extension = self
    end
end)

mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "delete", function(self)
    if self == player_smart_targeting_extension then
        persist_current_weapon_profile()
        player_smart_targeting_extension = nil
        reset_weapon_state()
    end
end)

mod:hook_safe(CLASS.PlayerUnitWeaponExtension, "on_slot_wielded", function(self)
    if self._player == local_player() then
        player_weapon_extension = self
        update_weapon_cache()
        cached_priority_target_frame = -1
    end
end)

mod:hook_safe(CLASS.PlayerUnitWeaponExtension, "fixed_update", function(self, unit)
    if unit == local_player_unit() then
        player_weapon_extension = self
        update_weapon_cache()
    end
end)

--mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "fixed_update", function(self)
-- This hook's logic is now handled by other update hooks and inlined targeting.
--end)

mod:hook_safe(CLASS.HudElementCrosshair, "update", function(self)
    if not setting_enabled or not mod:is_enabled() then return end

    local widget = self._widget
    if not widget or not widget.style then return end

    -- Crosshair tinting based on hovered target
    local should_tint = should_allow_fire_now() and hovered_priority_target()
    widget.content = widget.content or {}
    local tint_cache = widget.content.holdfire_tint_cache or {}
    widget.content.holdfire_tint_cache = tint_cache

    for style_name, style_data in pairs(widget.style) do
        local color = style_data.color
        if color and not string_find(style_name, "^hit_") then
            if should_tint then
                if not tint_cache[style_name] then
                    tint_cache[style_name] = { color[1], color[2], color[3], color[4] }
                end
                color[1], color[2], color[3], color[4] = CROSSHAIR_READY_RED[1], CROSSHAIR_READY_RED[2],
                    CROSSHAIR_READY_RED[3], CROSSHAIR_READY_RED[4]
            elseif tint_cache[style_name] then
                local orig = tint_cache[style_name]
                color[1], color[2], color[3], color[4] = orig[1], orig[2], orig[3], orig[4]
                tint_cache[style_name] = nil
            end
        end
    end
end)

mod:hook(CLASS.InputService, "_get", input_hook)
mod:hook(CLASS.InputService, "_get_simulate", input_hook)

mod:hook(CLASS.ActionHandler, "start_action",
    function(func, self, id, action_objects, action_name, action_params, action_settings, used_input, ...)
        if id == "weapon_action" and self._unit == local_player_unit() then
            local is_blocked = false
            for token, _ in pairs(BLOCKED_ACTION_TOKENS) do
                if string_find(action_name, token, 1, true) then
                    is_blocked = true
                    break
                end
            end
            if current_settings.enable_skitarius_omnissiah_hook and is_blocked and string_find(action_name, "zoom", 1, true) and not should_allow_fire_now() then
                return
            end
        end
        return func(self, id, action_objects, action_name, action_params, action_settings, used_input, ...)
    end)


mod:hook("SkitariusOmnissiah", "omnissiah", function(func, self, queried_input, user_value)
    local outcome = func(self, queried_input, user_value)

    if current_settings.enable_skitarius_omnissiah_hook and BLOCKED_INPUTS[queried_input] and outcome then
        if not should_allow_fire_now() then return false end
    end
    return outcome
end)


mod.on_game_state_changed = function(status, state_name)
    if status == "enter" then
        mod:debug("Enter " .. state_name)
        if state_name == "StateMainMenu" then
            reset_weapon_state()
            apply_weapon_profile("global_ranged")
        elseif state_name == "GameplayStateRun" then
            local detected, display_name = detected_weapon_profile_name()
            if detected then
                mod:debug("Found " .. display_name)
                cached_weapon_profile_name = detected
                apply_weapon_profile(detected, display_name)
            else
                mod:debug("No weapons found!!")
            end
        end
    end
end


mod.on_enabled = function()
    -- This function was added to ensure mod state is properly refreshed when enabled.
    refresh_enabled_setting()
    reset_weapon_state()
end

mod.on_disabled = function()
    persist_current_weapon_profile()
    player_weapon_extension = nil
    refresh_enabled_setting()
    reset_weapon_state()
end

mod.reset_to_defaults = function()
    applying_weapon_profile = true
    reset_weapon_state()
    save_weapon_profiles({})

    for id, val in pairs(ALL_SETTING_DEFAULTS) do
        mod:set(id, clone_setting_value(val), true)
        current_settings[id] = val
    end

    applying_weapon_profile = false

    update_weapon_cache()

    player_weapon_extension = nil
    refresh_enabled_setting()
    reset_weapon_state()
end

mod.reset_saved_weapon_profiles = function()
    applying_weapon_profile = true
    reset_weapon_state()
    save_weapon_profiles({})
    mod:set("ranged_weapon_selection", "global_ranged", false)
    for setting_id, default_value in pairs(PER_WEAPON_SETTING_DEFAULTS) do
        mod:set(setting_id, clone_setting_value(default_value), false)
    end
    applying_weapon_profile = false
    cached_priority_target_frame = -1
    update_weapon_cache()
    mod:set("purge_weapon_profiles", false, false)
    mod:notify("HoldFire: Cleared saved weapon profiles")
end

mod.on_setting_changed = function(setting_id)
    if applying_weapon_profile then return end

    if setting_id == "enable_mod" then
        refresh_enabled_setting()
    elseif setting_id == "enable_skitarius_omnissiah_hook" then
        current_settings.enable_skitarius_omnissiah_hook = mod:get(setting_id)
    elseif setting_id == "load_current_weapon_settings" then
        if mod:get("load_current_weapon_settings") then
            local detected, display_name = detected_weapon_profile_name()
            if detected then
                cached_weapon_profile_name = detected
                apply_weapon_profile(detected, display_name)
            end
            mod:set("load_current_weapon_settings", false, false)
        end
    elseif setting_id == "ranged_weapon_selection" then
        if not applying_weapon_profile then
            -- Revert manual changes to this dropdown
            mod:set("ranged_weapon_selection", cached_weapon_display_name, false)
            return
        end
        local selection = mod:get("ranged_weapon_selection")
        if selection then
            cached_weapon_display_name = selection
            apply_weapon_profile(selection)
        end
    elseif setting_id == "purge_weapon_profiles" and mod:get("purge_weapon_profiles") then
        mod.reset_saved_weapon_profiles()
        return
    elseif PER_WEAPON_SETTING_DEFAULTS[setting_id] ~= nil then
        local value = mod:get(setting_id)
        current_settings[setting_id] = value

        persist_weapon_profile_setting(cached_weapon_profile_name, setting_id, value)

        if current_weapon_settings_match_template() then
            remove_weapon_profile(cached_weapon_profile_name)
        end
    end
    cached_priority_target_frame = -1
end


-- Initialize
local saved_version = mod:get("weapon_profile_key_schema_version")
if saved_version ~= PROFILE_KEY_SCHEMA_VERSION then
    save_weapon_profiles({})
    mod:set("weapon_profile_key_schema_version", PROFILE_KEY_SCHEMA_VERSION, true)
    reset_weapon_state()
end

refresh_enabled_setting()
apply_weapon_profile("global_ranged")
current_settings.enable_skitarius_omnissiah_hook = mod:get("enable_skitarius_omnissiah_hook")
if current_settings.enable_skitarius_omnissiah_hook == nil then
    current_settings.enable_skitarius_omnissiah_hook = ALL_SETTING_DEFAULTS.enable_skitarius_omnissiah_hook
end
