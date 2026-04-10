return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`HoldFire` encountered an error loading the Darktide Mod Framework.")

		new_mod("HoldFire", {
			mod_script = "HoldFire/scripts/mods/HoldFire/HoldFire",
			mod_data = "HoldFire/scripts/mods/HoldFire/HoldFire_data",
			mod_localization = "HoldFire/scripts/mods/HoldFire/HoldFire_localization",
		})
	end,
	load_before = { "Skitarius" },
	packages = {},
}
