-- Author: ImperialSkoom

local mod = get_mod("HoldFire")

local Breed = require("scripts/utilities/breed")
local HazardPropSettings = require("scripts/settings/hazard_prop/hazard_prop_settings")
local WeaponTemplate = require("scripts/utilities/weapon/weapon_template")

local HEALTH_ALIVE = HEALTH_ALIVE
local Managers = Managers
local ScriptUnit = ScriptUnit
local Unit = Unit
local Actor = Actor
local string_find = string.find
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
local cached_priority_target = nil
local cached_priority_target_frame = nil
local cached_weapon_name = nil
local is_aiming = false
local setting_enabled = true
local applying_weapon_profile = false
local current_weapon_name
local current_weapon_profile_name
local current_equipped_ranged_name
local PER_WEAPON_SETTING_DEFAULTS
local ALL_SETTING_DEFAULTS
local PROFILE_KEY_SCHEMA_VERSION = 3

local function clone_setting_value(value)
	if type(value) ~= "table" then
		return value
	end

	local clone = {}

	for key, entry in pairs(value) do
		clone[key] = clone_setting_value(entry)
	end

	return clone
end

local function setting_values_equal(left, right)
	if type(left) ~= type(right) then
		return false
	end

	if type(left) ~= "table" then
		return left == right
	end

	for key, value in pairs(left) do
		if not setting_values_equal(value, right[key]) then
			return false
		end
	end

	for key, value in pairs(right) do
		if not setting_values_equal(left[key], value) then
			return false
		end
	end

	return true
end

local function weapon_profiles()
	local profiles = mod:get("weapon_profiles")

	if type(profiles) ~= "table" then
		return {}
	end

	return profiles
end

local function save_weapon_profiles(profiles)
	mod:set("weapon_profiles", profiles, true)
end

local function remove_weapon_profile(weapon_name)
	if type(weapon_name) ~= "string" or weapon_name == "" then
		return
	end

	local profiles = weapon_profiles()

	if profiles[weapon_name] == nil then
		return
	end

	profiles[weapon_name] = nil
	save_weapon_profiles(profiles)
end

local function ensure_weapon_profile(weapon_name)
	if type(weapon_name) ~= "string" or weapon_name == "" then
		return nil
	end

	local profiles = weapon_profiles()
	local profile = profiles[weapon_name]

	if profile then
		return profile
	end

	profile = {}

	for setting_id, default_value in pairs(PER_WEAPON_SETTING_DEFAULTS) do
		-- New weapon profiles should start from stable per-weapon defaults.
		-- Copying the currently active UI values causes freshly swapped weapons
		-- to inherit the previous weapon's profile and appear unsaved.
		profile[setting_id] = clone_setting_value(default_value)
	end

	profiles[weapon_name] = profile
	save_weapon_profiles(profiles)

	return profile
end

local function persist_weapon_profile_setting(weapon_name, setting_id, value)
	if type(weapon_name) ~= "string" or weapon_name == "" then
		return
	end

	if PER_WEAPON_SETTING_DEFAULTS[setting_id] == nil then
		return
	end

	local profiles = weapon_profiles()
	local profile = profiles[weapon_name] or {}

	profile[setting_id] = clone_setting_value(value)
	profiles[weapon_name] = profile

	save_weapon_profiles(profiles)
end

local function persist_current_weapon_profile(weapon_name)
	weapon_name = weapon_name or current_weapon_profile_name()

	if not weapon_name then
		return
	end

	for setting_id, _ in pairs(PER_WEAPON_SETTING_DEFAULTS) do
		persist_weapon_profile_setting(weapon_name, setting_id, mod:get(setting_id))
	end
end

local function apply_weapon_profile(weapon_name)
	local profile = ensure_weapon_profile(weapon_name)

	if not profile then
		return
	end

	applying_weapon_profile = true

	for setting_id, default_value in pairs(PER_WEAPON_SETTING_DEFAULTS) do
		local value = profile[setting_id]

		if value == nil then
			value = clone_setting_value(default_value)
		end

		mod:set(setting_id, clone_setting_value(value))
	end

	applying_weapon_profile = false
end

local function setting_value(setting_id)
	if PER_WEAPON_SETTING_DEFAULTS[setting_id] == nil then
		return mod:get(setting_id)
	end

	local weapon_name = current_weapon_profile_name()

	if not weapon_name then
		local value = mod:get(setting_id)

		if value ~= nil then
			return value
		end

		return clone_setting_value(PER_WEAPON_SETTING_DEFAULTS[setting_id])
	end

	local profile = ensure_weapon_profile(weapon_name)
	local value = profile and profile[setting_id]

	if value ~= nil then
		return value
	end

	return clone_setting_value(PER_WEAPON_SETTING_DEFAULTS[setting_id])
end

local function current_weapon_settings_match_defaults()
	for setting_id, default_value in pairs(PER_WEAPON_SETTING_DEFAULTS) do
		if not setting_values_equal(mod:get(setting_id), default_value) then
			return false
		end
	end

	return true
end

local function clear_all_weapon_profiles()
	save_weapon_profiles({})
end

local function ensure_profile_key_schema()
	local saved_version = mod:get("weapon_profile_key_schema_version")

	if saved_version == PROFILE_KEY_SCHEMA_VERSION then
		return
	end

	clear_all_weapon_profiles()
	mod:set("weapon_profile_key_schema_version", PROFILE_KEY_SCHEMA_VERSION, true)
	cached_weapon_name = nil
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
	toggle_mod_keybind = {},
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

local function refresh_enabled_setting()
	local stored_value = mod:get("enable_mod")
	setting_enabled = stored_value == nil and true or stored_value
	return setting_enabled
end

local function reset_cached_targeting()
	cached_priority_target = nil
	cached_priority_target_frame = nil
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

local function local_player_unit()
	local player = local_player()
	return player and player.player_unit
end

local function current_weapon_template()
	if player_weapon_extension then
		local inventory = player_weapon_extension._inventory_component
		local wielded_slot = inventory and inventory.wielded_slot
		local wielded_weapon = wielded_slot and player_weapon_extension._weapons and player_weapon_extension._weapons[wielded_slot]
		local weapon_template = wielded_weapon and wielded_weapon.weapon_template

		if weapon_template then
			return weapon_template
		end
	end

	if player_smart_targeting_extension then
		local weapon_action_component = player_smart_targeting_extension._weapon_action_component

		if weapon_action_component then
			return WeaponTemplate.current_weapon_template(weapon_action_component)
		end
	end

	return nil
end

current_weapon_name = function()
	local weapon_template = current_weapon_template()

	return weapon_template and weapon_template.name
end

local function current_ranged_slot_weapon()
	if not player_weapon_extension or not player_weapon_extension._weapons then
		return nil
	end

	return player_weapon_extension._weapons.slot_secondary
end

local function current_visual_loadout_data()
	local player_unit = local_player_unit()
	local visual_loadout = player_unit and ScriptUnit.has_extension(player_unit, "visual_loadout_system")
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
	local ranged_weapon = current_ranged_slot_weapon()
	local weapon_template = ranged_weapon and ranged_weapon.weapon_template

	if weapon_template and WeaponTemplate.is_ranged(weapon_template) then
		return weapon_template
	end

	local current_template = current_weapon_template()

	if current_template and WeaponTemplate.is_ranged(current_template) then
		return current_template
	end

	return nil
end

current_equipped_ranged_name = function()
	local reference = current_equipped_ranged_reference()

	if reference then
		return reference:match("([^/]+)$") or reference
	end

	local ranged_weapon = current_ranged_slot_weapon()
	local weapon_template = current_equipped_ranged_template()

	return ranged_weapon and ranged_weapon.name
		or ranged_weapon and ranged_weapon.item and ranged_weapon.item.name
		or ranged_weapon and ranged_weapon.inventory_item and ranged_weapon.inventory_item.name
		or weapon_template and weapon_template.name
end

local function append_unique_identifier(identifiers, seen, value)
	if type(value) == "number" then
		value = tostring(value)
	end

	if type(value) ~= "string" or value == "" or seen[value] then
		return
	end

	identifiers[#identifiers + 1] = value
	seen[value] = true
end

local function nested_identifier_value(root, path)
	local value = root

	for i = 1, #path do
		if type(value) ~= "table" then
			return nil
		end

		value = value[path[i]]
	end

	return value
end

current_weapon_profile_name = function()
	local ranged_weapon = current_ranged_slot_weapon()
	local weapon_template = current_equipped_ranged_template()
	local equipped_reference = current_equipped_ranged_reference()

	if not ranged_weapon and not weapon_template and not equipped_reference then
		return nil
	end

	local identifiers = {}
	local seen = {}

	local stable_id_paths = {
		{ "gear_id" },
		{ "uuid" },
		{ "item", "gear_id" },
		{ "item", "uuid" },
		{ "item", "__raw", "gear_id" },
		{ "item", "__raw", "uuid" },
		{ "inventory_item", "gear_id" },
		{ "inventory_item", "uuid" },
		{ "inventory_item", "__raw", "gear_id" },
		{ "inventory_item", "__raw", "uuid" },
	}

	for i = 1, #stable_id_paths do
		local value = nested_identifier_value(ranged_weapon, stable_id_paths[i])

		append_unique_identifier(identifiers, seen, value)
	end

	append_unique_identifier(identifiers, seen, equipped_reference)
	append_unique_identifier(identifiers, seen, current_equipped_ranged_name())
	append_unique_identifier(identifiers, seen, ranged_weapon and ranged_weapon.name)
	append_unique_identifier(identifiers, seen, ranged_weapon and ranged_weapon.item and ranged_weapon.item.name)
	append_unique_identifier(identifiers, seen, ranged_weapon and ranged_weapon.inventory_item and ranged_weapon.inventory_item.name)
	append_unique_identifier(identifiers, seen, weapon_template and weapon_template.name)

	if #identifiers == 0 then
		return nil
	end

	return table.concat(identifiers, "|")
end

local function toggle_target_setting(setting_id, enabled_label)
	local new_value = not setting_value(setting_id)
	local weapon_name = current_weapon_profile_name()

	mod:set(setting_id, new_value)

	if weapon_name then
		persist_weapon_profile_setting(weapon_name, setting_id, new_value)
	end

	reset_cached_targeting()
	mod:echo("%s %s", enabled_label, new_value and "enabled" or "disabled")
end

local function current_ads_input(input_service)
	if not input_service then
		return false
	end

	return (input_service("action_two_hold") or input_service("action_two_pressed")) and true or false
end

local function current_live_ads_input()
	local input_service = gameplay_input_service()

	if input_service and input_service.get then
		if input_service:get("action_two_hold") or input_service:get("action_two_pressed") then
			return true
		end
	end

	return false
end

local function current_skitarius_ads_input(omnissiah)
	local bind_manager = omnissiah and omnissiah.bind_manager

	if bind_manager and bind_manager.input_value then
		return bind_manager:input_value("action_two_hold") and true or false
	end

	return nil
end

local function current_ads_filter()
	local filter = setting_value("ads_filter")

	if filter == nil then
		return "ads_hip"
	end

	return filter
end

local function normalize_ads_state(is_adsing)
	if is_adsing ~= nil then
		return is_adsing
	end

	return is_aiming
end

local function ads_filter_allows(is_adsing)
	local adsing = normalize_ads_state(is_adsing)
	local filter = current_ads_filter()

	if filter == "disabled" then
		return false
	end

	if filter == "ads_only" then
		return adsing
	end

	if filter == "hip_only" then
		return not adsing
	end

	return true
end

local function current_enemy_lock_tolerance()
	local target_radius = tonumber(setting_value("target_radius")) or 0.03
	local horizontal_tolerance = math.clamp(target_radius, 0.01, 0.20)
	local enemy_vertical_tolerance = math.clamp(horizontal_tolerance * 0.5, 0.008, 0.10)

	return horizontal_tolerance, enemy_vertical_tolerance
end

local function current_destructible_lock_tolerance()
	local destructible_radius = tonumber(setting_value("destructible_radius")) or 0.03
	local horizontal_tolerance = math.clamp(destructible_radius, 0.01, 0.20)
	local object_vertical_tolerance = math.clamp(horizontal_tolerance * 0.4, 0.006, 0.08)

	return horizontal_tolerance, object_vertical_tolerance
end

local function is_crosshair_hit_indicator_style(style_name)
	return type(style_name) == "string" and string_find(style_name, "^hit_") ~= nil
end

local function clone_color(color)
	return { color[1], color[2], color[3], color[4] }
end

local function can_block_current_weapon()
	local player_unit = local_player_unit()

	if not player_unit or not HEALTH_ALIVE[player_unit] or not Unit.alive(player_unit) then
		return false
	end

	local weapon_template = current_weapon_template()

	if not weapon_template or not WeaponTemplate.is_ranged(weapon_template) then
		return false
	end

	local wielded_slot = player_weapon_extension
		and player_weapon_extension._inventory_component
		and player_weapon_extension._inventory_component.wielded_slot

	if wielded_slot == "slot_grenade_ability" then
		return false
	end

	return true
end

local function refresh_weapon_logic()
	local weapon_name = current_weapon_profile_name()

	if not weapon_name then
		if cached_weapon_name then
			persist_current_weapon_profile(cached_weapon_name)
			cached_weapon_name = nil
		end

		return
	end

	if weapon_name ~= cached_weapon_name then
		persist_current_weapon_profile(cached_weapon_name)
		cached_weapon_name = weapon_name
		apply_weapon_profile(weapon_name)
	end
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

function mod.toggle_mod_enabled()
	setting_enabled = not refresh_enabled_setting()
	mod:set("enable_mod", setting_enabled)
	reset_cached_targeting()
	mod:notify(string.format("HoldFire: %s", setting_enabled and "Enabled" or "Disabled"))
end

local function is_blocked_shot_action(action_name)
	if type(action_name) ~= "string" then
		return false
	end

	for token, _ in pairs(BLOCKED_ACTION_TOKENS) do
		if string.find(action_name, token, 1, true) then
			return true
		end
	end

	return false
end

local function is_ads_shot_action(action_name)
	return type(action_name) == "string" and string.find(action_name, "zoom", 1, true) ~= nil
end

local function get_target_breed_data(target_unit)
	local unit_data_extension = target_unit and ScriptUnit.has_extension(target_unit, "unit_data_system")
	return unit_data_extension and unit_data_extension:breed()
end

local function is_target_alive(target_unit)
	if not target_unit or not Unit.alive(target_unit) then
		return false
	end

	if HEALTH_ALIVE[target_unit] ~= nil then
		return HEALTH_ALIVE[target_unit]
	end

	return true
end

local function is_pickup_unit(target_unit)
	if not target_unit then
		return false
	end

	if Unit.has_data(target_unit, "is_pickup") and Unit.get_data(target_unit, "is_pickup") then
		return true
	end

	return Unit.has_data(target_unit, "pickup_type") and Unit.get_data(target_unit, "pickup_type") ~= nil
end

local function is_health_station_unit(target_unit)
	return target_unit and ScriptUnit.has_extension(target_unit, "health_station_system") ~= nil
end

local function unit_data_value(target_unit, key)
	if not target_unit or not Unit.has_data(target_unit, key) then
		return nil
	end

	return Unit.get_data(target_unit, key)
end

local function update_precision_target(template)
	local ray_origin, forward, right, up = player_smart_targeting_extension:_targeting_parameters()

	player_smart_targeting_extension._precision_target_aim_assist:update_precision_target(
		player_smart_targeting_extension._unit,
		template,
		ray_origin,
		forward,
		right,
		up,
		player_smart_targeting_extension._smart_tag_targeting_data,
		player_smart_targeting_extension._latest_fixed_frame,
		player_smart_targeting_extension._visibility_cache,
		player_smart_targeting_extension._visibility_check_frame
	)

	local target_data = player_smart_targeting_extension:smart_tag_targeting_data()

	return target_data and target_data.unit
end

local function is_intact_destructible(target_unit, destructible_extension)
	destructible_extension = destructible_extension or (target_unit and ScriptUnit.has_extension(target_unit, "destructible_system"))

	if not destructible_extension then
		return false
	end

	local destruction_info = destructible_extension._destruction_info

	if not destruction_info then
		return true
	end

	return (destruction_info.current_stage_index or 0) > 0
end

local function is_heretic_idol_target(target_unit)
	local destructible_extension = target_unit and ScriptUnit.has_extension(target_unit, "destructible_system")

	if not destructible_extension then
		return false
	end

	local collectible_type = unit_data_value(target_unit, "collectible_type")
	local has_collectible_data = destructible_extension._collectible_data ~= nil

	return (collectible_type == HERETIC_IDOL_COLLECTIBLE_TYPE or has_collectible_data)
		and is_intact_destructible(target_unit, destructible_extension)
end

local function is_targetable_hazard_prop(target_unit)
	local hazard_prop_extension = target_unit and ScriptUnit.has_extension(target_unit, "hazard_prop_system")

	if not hazard_prop_extension then
		return false
	end

	local content = hazard_prop_extension:content()
	local current_state = hazard_prop_extension:current_state()

	return content ~= HAZARD_CONTENT.none
		and content ~= HAZARD_CONTENT.undefined
		and TARGETABLE_HAZARD_STATE[current_state] == true
end

local function is_destructible_target(target_unit)
	if not target_unit or not Unit.alive(target_unit) then
		return false
	end

	if is_pickup_unit(target_unit) or is_health_station_unit(target_unit) then
		return false
	end

	return is_heretic_idol_target(target_unit) or is_targetable_hazard_prop(target_unit)
end

local function nearby_destructible_target(hit_position, ignored_unit)
	if not hit_position then
		return nil
	end

	local extension_manager = Managers and Managers.state and Managers.state.extension
	local broadphase_system = extension_manager and extension_manager:system("broadphase_system")
	local broadphase = broadphase_system and broadphase_system.broadphase

	if not broadphase then
		return nil
	end

	table.clear(NEARBY_DESTRUCTIBLE_RESULTS)

	local num_results = broadphase.query(
		broadphase,
		hit_position,
		DESTRUCTIBLE_NEARBY_RADIUS,
		NEARBY_DESTRUCTIBLE_RESULTS,
		DESTRUCTIBLE_BROADPHASE_CATEGORY
	)

	if not num_results or num_results <= 0 then
		return nil
	end

	local best_unit = nil
	local best_distance_squared = math.huge

	for i = 1, num_results do
		local nearby_unit = NEARBY_DESTRUCTIBLE_RESULTS[i]

		if nearby_unit ~= ignored_unit and is_destructible_target(nearby_unit) then
			local nearby_position = POSITION_LOOKUP and POSITION_LOOKUP[nearby_unit]

			if not nearby_position and Unit.alive(nearby_unit) then
				nearby_position = Unit.world_position(nearby_unit, 1)
			end

			if nearby_position then
				local distance_squared = Vector3.distance_squared(nearby_position, hit_position)

				if distance_squared < best_distance_squared then
					best_unit = nearby_unit
					best_distance_squared = distance_squared
				end
			end
		end
	end

	return best_unit
end

local function resolve_destructible_target(target_unit, target_position)
	if target_unit and is_destructible_target(target_unit) then
		return target_unit
	end

	local fallback_position = target_position

	if not fallback_position and target_unit then
		fallback_position = POSITION_LOOKUP and POSITION_LOOKUP[target_unit]

		if not fallback_position and Unit.alive(target_unit) then
			fallback_position = Unit.world_position(target_unit, 1)
		end
	end

	return nearby_destructible_target(fallback_position, target_unit)
end

local function raycasted_destructible_target()
	if not player_smart_targeting_extension then
		return false
	end

	local physics_world = player_smart_targeting_extension._physics_world

	if not physics_world then
		return false
	end

	local ray_origin, forward = player_smart_targeting_extension:_targeting_parameters()
	local hits = PhysicsWorld.raycast(
		physics_world,
		ray_origin,
		forward,
		MAX_TARGET_RAYCAST_DISTANCE,
		"all",
		"types",
		"both",
		"collision_filter",
		SHOOTING_RAYCAST_FILTER
	)

	if not hits then
		return false
	end

	local player_unit = local_player_unit()

	for i = 1, #hits do
		local hit = hits[i]
		local hit_position = hit.position or hit[1]
		local hit_actor = hit.actor or hit[4]
		local hit_unit = hit_actor and Actor.unit(hit_actor)

		if hit_unit and hit_unit ~= player_unit then
			return resolve_destructible_target(hit_unit, hit_position) ~= nil
		end

		if not hit_unit then
			return resolve_destructible_target(nil, hit_position) ~= nil
		end
	end

	return false
end

local function is_eligible_target(target_unit, breed_data)
	if not breed_data then
		return false
	end

	if breed_data.is_boss then
		return setting_value("target_bosses")
	end

	if not Breed.is_minion(breed_data) then
		return false
	end

	local tags = breed_data.tags or {}

	if tags.special then
		return setting_value("target_specials")
	end

	if tags.elite then
		return setting_value("target_elites")
	end

	return setting_value("target_normals")
end

local function hovered_priority_target()
	if not player_smart_targeting_extension then
		return false
	end

	local current_frame = player_smart_targeting_extension._latest_fixed_frame

	if current_frame and cached_priority_target_frame == current_frame and cached_priority_target ~= nil then
		return cached_priority_target
	end

	local horizontal_tolerance, enemy_vertical_tolerance = current_enemy_lock_tolerance()
	local object_horizontal_tolerance, object_vertical_tolerance = current_destructible_lock_tolerance()

	ENEMY_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_x = horizontal_tolerance
	ENEMY_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_y = enemy_vertical_tolerance
	ENEMY_SMART_TARGETING_TEMPLATE.precision_target.smart_tagging = not setting_value("target_normals")
	OBJECT_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_x = object_horizontal_tolerance
	OBJECT_SMART_TARGETING_TEMPLATE.precision_target.within_distance_to_box_y = object_vertical_tolerance

	local target_unit = update_precision_target(ENEMY_SMART_TARGETING_TEMPLATE)
	local breed_data = get_target_breed_data(target_unit)

	if is_target_alive(target_unit) and breed_data then
		cached_priority_target = is_eligible_target(target_unit, breed_data)
	else
		if not setting_value("target_destructibles") then
			cached_priority_target = false
		else
			target_unit = update_precision_target(OBJECT_SMART_TARGETING_TEMPLATE)
			cached_priority_target = resolve_destructible_target(target_unit) ~= nil

			if not cached_priority_target then
				cached_priority_target = raycasted_destructible_target()
			end
		end
	end

	cached_priority_target_frame = current_frame

	return cached_priority_target
end

local function update_holdfire_state()
	hovered_priority_target()
end

local function should_allow_fire_now(is_adsing)
	if not mod:is_enabled() or ui_using_input() then
		return true
	end

	if not setting_enabled then
		return true
	end

	refresh_weapon_logic()

	if not ads_filter_allows(is_adsing) then
		return true
	end

	if not can_block_current_weapon(is_adsing) then
		return true
	end

	return hovered_priority_target()
end

local function should_tint_crosshair()
	local adsing = current_live_ads_input() or is_aiming

	if not mod:is_enabled() or ui_using_input() then
		return false
	end

	if not setting_enabled then
		return false
	end

	refresh_weapon_logic()

	if not ads_filter_allows(adsing) then
		return false
	end

	if not can_block_current_weapon(adsing) then
		return false
	end

	return hovered_priority_target()
end

local function apply_crosshair_tint(widget, tint_color)
	if not widget or not widget.style then
		return
	end

	widget.content = widget.content or {}
	local tint_cache = widget.content.holdfire_tint_cache

	if not tint_cache then
		tint_cache = {}
		widget.content.holdfire_tint_cache = tint_cache
	end

	for style_name, style_data in pairs(widget.style) do
		local color = style_data and style_data.color

		if color and not is_crosshair_hit_indicator_style(style_name) then
			if tint_color then
				if not tint_cache[style_name] then
					tint_cache[style_name] = clone_color(color)
				end

				color[1] = tint_color[1]
				color[2] = tint_color[2]
				color[3] = tint_color[3]
				color[4] = tint_color[4]
			else
				local original_color = tint_cache[style_name]

				if original_color then
					color[1] = original_color[1]
					color[2] = original_color[2]
					color[3] = original_color[3]
					color[4] = original_color[4]
					tint_cache[style_name] = nil
				end
			end
		end
	end
end

local function input_hook(func, self, action_name)
	local value = func(self, action_name)

	if not BLOCKED_INPUTS[action_name] then
		return value
	end

	if not mod:is_enabled() or value == false then
		return value
	end

	local is_adsing = current_ads_input(function(action_name)
		return func(self, action_name)
	end)

	if not can_block_current_weapon(is_adsing) then
		return value
	end

	if should_allow_fire_now(is_adsing) then
		return value
	end

	return false
end

mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "init", function(self)
	if self._player and self._player.viewport_name == "player1" then
		player_smart_targeting_extension = self
		self._num_visibility_checks_this_frame = 0
	end
end)

mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "delete", function(self)
	if self._player and self._player.viewport_name == "player1" and player_smart_targeting_extension == self then
		persist_current_weapon_profile()
		player_smart_targeting_extension = nil
		cached_priority_target = nil
		cached_priority_target_frame = nil
		is_aiming = false
	end
end)

mod:hook_safe(CLASS.PlayerUnitWeaponExtension, "on_slot_wielded", function(self)
	local player = local_player()

	if player and self._player == player then
		player_weapon_extension = self
		refresh_weapon_logic()
		reset_cached_targeting()
	end
end)

mod:hook_safe(CLASS.PlayerUnitWeaponExtension, "fixed_update", function(self, unit)
	local player_unit = local_player_unit()

	if player_unit and unit == player_unit then
		player_weapon_extension = self
		refresh_weapon_logic()
	end
end)

mod:hook_safe(CLASS.PlayerUnitSmartTargetingExtension, "fixed_update", function(self)
	if self == player_smart_targeting_extension then
		update_holdfire_state()
	end
end)

mod:hook_safe(CLASS.HudElementCrosshair, "update", function(self)
	apply_crosshair_tint(self._widget, should_tint_crosshair() and CROSSHAIR_READY_RED or nil)
end)

mod:hook_require("scripts/utilities/alternate_fire", function(AlternateFire)
	mod:hook_safe(AlternateFire, "start", function(_, _, _, _, _, _, _, _, _, _, _, _, _, player_unit)
		local local_unit = local_player_unit()

		if local_unit and player_unit == local_unit then
			is_aiming = true
		end
	end)

	mod:hook_safe(AlternateFire, "stop", function(_, _, _, _, _, _, _, player_unit)
		local local_unit = local_player_unit()

		if local_unit and player_unit == local_unit then
			is_aiming = false
		end
	end)
end)

mod:hook(CLASS.InputService, "_get", input_hook)
mod:hook(CLASS.InputService, "_get_simulate", input_hook)
mod:hook(CLASS.ActionHandler, "start_action", function(func, self, id, action_objects, action_name, action_params, action_settings, used_input, ...)
	if id == "weapon_action"
		and self._unit == local_player_unit()
		and is_blocked_shot_action(action_name)
		and is_ads_shot_action(action_name)
		and not should_allow_fire_now(true)
	then
		return
	end

	return func(self, id, action_objects, action_name, action_params, action_settings, used_input, ...)
end)
mod:hook("SkitariusOmnissiah", "omnissiah", function(func, self, queried_input, user_value)
	local outcome = func(self, queried_input, user_value)
	local is_adsing = current_skitarius_ads_input(self)

	if BLOCKED_INPUTS[queried_input] and outcome and not should_allow_fire_now(is_adsing) then
		return false
	end

	return outcome
end)

mod.on_disabled = function()
	persist_current_weapon_profile()
	player_weapon_extension = nil
	refresh_enabled_setting()
	reset_cached_targeting()
	is_aiming = false
	cached_weapon_name = nil
end

mod.reset_to_defaults = function()
	applying_weapon_profile = true
	cached_weapon_name = nil
	clear_all_weapon_profiles()

	for setting_id, default_value in pairs(ALL_SETTING_DEFAULTS) do
		mod:set(setting_id, clone_setting_value(default_value), true)
	end

	applying_weapon_profile = false
	clear_all_weapon_profiles()

	local weapon_name = current_weapon_profile_name()

	if weapon_name then
		apply_weapon_profile(weapon_name)
	end

	player_weapon_extension = nil
	refresh_enabled_setting()
	reset_cached_targeting()
	is_aiming = false
	cached_weapon_name = nil
end

mod.reset_saved_weapon_profiles = function()
	applying_weapon_profile = true
	cached_weapon_name = nil
	clear_all_weapon_profiles()

	for setting_id, default_value in pairs(PER_WEAPON_SETTING_DEFAULTS) do
		mod:set(setting_id, clone_setting_value(default_value), false)
	end

	applying_weapon_profile = false
	reset_cached_targeting()
	refresh_weapon_logic()
	mod:set("purge_weapon_profiles", false, false)
	mod:notify("HoldFire: Cleared saved weapon profiles")
end

mod.on_setting_changed = function(setting_id)
	if setting_id == "enable_mod" then
		refresh_enabled_setting()
	end

	if setting_id == "purge_weapon_profiles" and mod:get("purge_weapon_profiles") then
		mod.reset_saved_weapon_profiles()
		return
	end

	if not applying_weapon_profile and PER_WEAPON_SETTING_DEFAULTS[setting_id] ~= nil then
		local weapon_name = current_weapon_profile_name()

		persist_weapon_profile_setting(weapon_name, setting_id, mod:get(setting_id))

		if current_weapon_settings_match_defaults() then
			remove_weapon_profile(weapon_name)
		end
	end

	reset_cached_targeting()
end

ensure_profile_key_schema()
refresh_enabled_setting()
