### Technical Feature Spec HoldFire

#### 1. Shot Gating
Hooks `InputService:_get`, `InputService:_get_simulate`. Blocks `action_one_hold`, `action_one_pressed`.
Hooks `ActionHandler:start_action`. Blocks tokens: `shoot`, `rapid`, `trigger`, `flame`.
Returns `false` input system when `should_allow_fire_now` false.

#### 2. Target Filters
Queries `PlayerUnitSmartTargetingExtension`.
Classifies via breed tags: `special`, `elite`, `is_boss`.
Destructibles check `destructible_system` (Stage > 0) or `hazard_prop_system` (Idle/Triggered).
Broadphase query 2.5m finds nearby destructibles.

#### 3. Per-Weapon Profiles
Identifies weapon using composite key.
Key components: `gear_id|uuid|item_reference|template_name|internal_name`.
Scans `STABLE_ID_PATHS` unique identifiers.
Saves `weapon_profiles` table.
Schema version 3 wipes incompatible keys.
Performance: Caches active settings `current_settings`.

#### 4. ADS Filters
States: `ads_hip`, `ads_only`, `hip_only`, `disabled`.
Queries `action_two_hold`, `action_two_pressed` via `Ingame` service.
`ads_filter_allows` bypasses gating based state.

#### 5. Adjustable Precision
Modifies `within_distance_to_box_x/y` in targeting templates.
Slider range 0.01-0.2.
Vertical tolerance 0.5x enemies, 0.4x objects.

#### 6. Integration Management
Hooks `SkitariusOmnissiah:omnissiah`.
Controlled by `enable_skitarius_omnissiah_hook`.
Overrides Omnissiah input gating active.
