# Darktide-HoldFire

HoldFire is a Warhammer 40,000: Darktide mod for the Darktide Mod Framework. It blocks ranged fire unless an allowed target is directly under your crosshair and includes:

- Separate target filters for Elites, Specials, Bosses, Normals, and Destructibles
- Per-weapon settings so each ranged weapon can keep its own configuration
- A target lock tolerance slider for stricter or more permissive shot gating
- A clear saved weapon profiles option to wipe per-weapon setup and start fresh

This mod is built around trigger discipline and cleaner target selection, helping prevent wasted ammo, accidental shots, and firing at the wrong enemy.

## Install

1. Extract `HoldFire` into your Darktide `mods` directory.
2. Add `HoldFire` to `mod_load_order.txt`.
3. Launch with DMF enabled.

## Files

```text
HoldFire/
  HoldFire.mod
  README.md
  scripts/
    mods/
      HoldFire/
        HoldFire.lua
        HoldFire_data.lua
        HoldFire_localization.lua
```
