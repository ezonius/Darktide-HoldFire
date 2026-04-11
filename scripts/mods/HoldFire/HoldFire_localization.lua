local WeaponTemplates = require("scripts/settings/equipment/weapon_templates/weapon_templates")

local localizations = {
	mod_name = {
		en = "HoldFire",
	},
	mod_description = {
		en = "Blocks ranged fire unless an allowed enemy target is under your crosshair, with optional destructible support.",
	},
	global_settings = {
		en = "Global Settings",
	},
	global_settings_description = {
		en = "Settings in this section affect HoldFire globally, regardless of which weapon you have equipped.",
	},
	weapon_settings = {
		en = "Per-Weapon Settings",
	},
	weapon_settings_description = {
		en = "These settings are saved per weapon, so each ranged weapon can keep its own allowed target and fire-blocking rules.",
	},
	ranged_weapon_selection = {
		en = "Weapon Selection",
	},
	global_ranged = {
		en = "CURRENTLY EQUIPPED",
	},
	ads_filter = {
		en = "ADS / Hipfire Filter",
	},
	ads_filter_description = {
		en = "Choose whether HoldFire blocks shots while aiming, while hipfiring, in both modes, or not at all for this weapon.",
	},
	target_radius = {
		en = "Enemy Lock Tolerance",
	},
	target_radius_description = {
		en = "Controls how strict HoldFire is about an enemy target being under the crosshair. Higher values are more permissive.",
	},
	destructible_radius = {
		en = "Destructible Lock Tolerance",
	},
	destructible_radius_description = {
		en = "Controls how strict HoldFire is about destructible objects being under the crosshair. Lower values are tighter; higher values are more permissive.",
	},
	disabled = {
		en = "Disabled for This Weapon",
	},
	ads_only = {
		en = "Aim Only",
	},
	ads_hip = {
		en = "Aim + Hipfire",
	},
	hip_only = {
		en = "Hipfire Only",
	},
	enable_mod = {
		en = "Enable Mod",
	},
	enable_mod_description = {
		en = "Enable or disable HoldFire while keeping the mod loaded.",
	},
	purge_weapon_profiles = {
		en = "Clear Saved Weapon Profiles",
	},
	purge_weapon_profiles_description = {
		en = "Wipes every per-weapon HoldFire profile and restores the current weapon settings to defaults.",
	},
	toggle_mod_keybind = {
		en = "Toggle Mod Keybind",
	},
	toggle_mod_keybind_description = {
		en = "Turns Enable Mod on or off while in mission.",
	},
	toggle_ads_filter_keybind = {
		en = "Toggle ADS Filter Keybind",
	},
	toggle_ads_filter_keybind_description = {
		en = "Toggles between 'Disabled' and your previous ADS filter setting for the current weapon.",
	},
	enable_skitarius_omnissiah_hook = {
		en = "Enable Skitarius Compatibility",
	},
	enable_skitarius_omnissiah_hook_description = {
		en = "When enabled, HoldFire will also block inputs from the Skitarius mod if no valid target is present.",
	},
	target_elites = {
		en = "Target Elites",
	},
	target_elites_description = {
		en = "Allow firing when hovering elite enemies.",
	},
	target_specials = {
		en = "Target Specials",
	},
	target_specials_description = {
		en = "Allow firing when hovering special enemies.",
	},
	target_bosses = {
		en = "Target Bosses",
	},
	target_bosses_description = {
		en = "Allow firing when hovering boss enemies.",
	},
	target_normals = {
		en = "Target Normals",
	},
	target_normals_description = {
		en = "Allow firing when hovering normal enemies that are not elites, specials, or bosses.",
	},
	target_destructibles = {
		en = "Allow Destructibles",
	},
	target_destructibles_description = {
		en = "Allow firing at Heretic Idols and active hazard props such as barrels, gas tanks, or hanging explosives. Pickups and Medicae stations are excluded.",
	},
}

local family_prefix = "loc_weapon_family_"
local pattern_prefix = "loc_weapon_pattern_"
local mark_prefix = "loc_weapon_mark_"

for weapon, _ in pairs(WeaponTemplates) do
	local localized_family = Localize(family_prefix .. weapon)
	local localized_pattern = Localize(pattern_prefix .. weapon)
	if not localized_pattern or string.find(localized_pattern, "unlocalized") then
		local alt_pattern = weapon:gsub("_m%d+", "_m1")
		localized_pattern = Localize(pattern_prefix .. alt_pattern)
	end
	local localized_mark = Localize(mark_prefix .. weapon)

	local localized = localized_family and localized_pattern and localized_mark and string.format("%s %s %s", localized_pattern, localized_mark, localized_family)
	if localized and not string.find(localized, "unlocalized") then
		localizations[weapon] = {
			en = localized
		}
	end
end

return localizations
