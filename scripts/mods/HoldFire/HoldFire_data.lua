local mod = get_mod("HoldFire")

return {
	name = mod:localize("mod_name"),
	description = mod:localize("mod_description"),
	is_togglable = true,
	allow_rehooking = true,
	reset_function = function()
		get_mod("HoldFire").reset_to_defaults()
	end,
	options = {
		widgets = {
			{
				setting_id = "global_settings",
				type = "group",
				sub_widgets = {
					{
						setting_id = "enable_mod",
						type = "checkbox",
						default_value = true,
					},
					{
						setting_id = "toggle_mod_keybind",
						tooltip = "toggle_mod_keybind_description",
						type = "keybind",
						default_value = {},
						keybind_trigger = "pressed",
						keybind_type = "function_call",
						function_name = "toggle_mod_enabled",
					},
					{
						setting_id = "toggle_ads_filter_keybind",
						tooltip = "toggle_ads_filter_keybind_description",
						type = "keybind",
						default_value = {},
						keybind_trigger = "pressed",
						keybind_type = "function_call",
						function_name = "toggle_ads_filter_enabled",
					},
					{
						setting_id = "enable_skitarius_omnissiah_hook",
						type = "checkbox",
						default_value = true,
					},
					{
						setting_id = "purge_weapon_profiles",
						type = "checkbox",
						default_value = false,
					},
				},
			},
			{
				setting_id = "weapon_settings",
				type = "group",
				sub_widgets = {
					{
						setting_id = "ads_filter",
						type = "dropdown",
						default_value = "ads_hip",
						options = {
							{ text = "disabled", value = "disabled" },
							{ text = "ads_hip", value = "ads_hip" },
							{ text = "ads_only", value = "ads_only" },
							{ text = "hip_only", value = "hip_only" },
						},
					},
					{
						setting_id = "target_radius",
						type = "numeric",
						default_value = 0.10,
						range = { 0.01, 0.20 },
						decimals_number = 2,
					},
					{
						setting_id = "destructible_radius",
						type = "numeric",
						default_value = 0.10,
						range = { 0.01, 0.20 },
						decimals_number = 2,
					},
					{
						setting_id = "target_elites",
						type = "checkbox",
						default_value = true,
					},
					{
						setting_id = "target_specials",
						type = "checkbox",
						default_value = true,
					},
					{
						setting_id = "target_bosses",
						type = "checkbox",
						default_value = true,
					},
					{
						setting_id = "target_normals",
						type = "checkbox",
						default_value = true,
					},
					{
						setting_id = "target_destructibles",
						type = "checkbox",
						default_value = true,
					},
				},
			},
		},
	},
}
