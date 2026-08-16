class_name WeatherSystem
extends Node

## Weather driver for ROUTE 41.
##
## This node owns nothing about the *physics* of weather -- that all lives in
## BiomeWeatherState, one per biome, each weathering independently. What lives
## here is the three jobs that are not per-biome:
##
##   1. Stepping every biome's state on the in-game clock.
##   2. Working out how exposed the player is -- to the sun, to the wind --
##      which is what turns air temperature into felt temperature.
##   3. Rendering the biome the player is standing in: sky uniforms, cloud
##      shadow on the terrain, fog, and how much light gets through.
##
## Everything downstream (HUD, wind audio, lightning, the player's body glow)
## reads this node rather than reaching into a state directly.

signal weather_event_started(event: WeatherEvent)
signal weather_event_ended(event: WeatherEvent)

@export var day_night: DayNightCycle
## Profile for the starting biome. Later this is selected by distance west.
@export var desert_profile: BiomeWeather
## Left empty, found via the "chunk_manager" group. Only needed so cloud
## shadow can be pushed onto the terrain material.
@export var chunk_manager: ChunkManager
@export var world_seed: int = 0

@export_group("Clouds")
## Metres above the ground for the thin, high cirrus deck.
@export var cirrus_altitude: float = 2600.0
## World metres to uv for the cirrus. One uv unit is 1.0 / this many metres.
@export var cirrus_scale: float = 0.00016
@export var cirrus_region_scale: float = 0.20
## Radius of the shell the cirrus sits on -- bounds how far toward the horizon
## it reaches, and so how many times its pattern repeats.
@export var cirrus_curvature_radius: float = 45000.0
## High: thin and sparse rather than a solid sheet. This is what makes the
## desert's ordinary cloud read as feathery streaks rather than as puffs.
@export var cirrus_shape_floor: float = 0.58
## Stretched hard along one axis: draws puffs out into wispy cirrus streaks.
@export var cirrus_stretch: Vector2 = Vector2(4.0, 1.0)
## Metres above the ground for the lower, solid deck -- the one events close
## the sky over with.
@export var deck_altitude: float = 900.0
@export var deck_scale: float = 0.00034
@export var deck_region_scale: float = 0.30
@export var deck_curvature_radius: float = 30000.0
## Shape floor at partial cover. Driven down toward zero as the deck closes
## over, which is what turns scattered lumps into an unbroken sheet.
@export var deck_shape_floor: float = 0.26
## The low deck scrolls faster than the cirrus for the same wind -- it is
## closer, so it reads as moving faster. Parallax, not physics.
@export var deck_parallax: float = 1.3
## Clouds drift at wind speed times this. 1.0 would be physically real, which
## is too slow to read against gameplay timescales.
@export var cloud_drift_multiplier: float = 4.0
## How hard the puff shape churns over time, independent of wind-driven drift.
@export var cloud_turbulence: float = 0.35
## Cloud colour on an ordinary day, and under a storm. Storms are lit from
## below by almost nothing, so the deck goes near-black.
@export var cloud_shade_color: Color = Color(0.40, 0.46, 0.60)
@export var cloud_storm_color: Color = Color(0.10, 0.11, 0.14)

@export_group("Dust")
## Colour of the airborne dust, both in the fog and across the sky.
@export var dust_color: Color = Color(0.60, 0.42, 0.24)
## Fog distance in metres at full dust. Small enough that the player genuinely
## cannot see -- feeling your way by your own light is the intent.
@export var dust_fog_distance: float = 7.0
## Fog distance in metres with clear air. Matches the scene's ordinary haze.
@export var clear_fog_distance: float = 520.0
@export var clear_fog_begin: float = 280.0

@export_group("Exposure")
## Metres of raycast used to decide whether the player is standing in shade.
@export var shade_ray_length: float = 80.0
## Metres of upward raycast used to decide whether they are under cover, which
## is what shelters them from the wind.
@export var cover_ray_length: float = 8.0
## Wind still finds you under an overhang, just less of it.
@export_range(0.0, 1.0) var sheltered_wind_fraction: float = 0.35
## Windows let light in. A driver is out of the wind but not out of the sun.
@export_range(0.0, 1.0) var vehicle_sun_fraction: float = 0.25
## Seconds for an exposure change to land, so walking past a rock does not
## make felt temperature flicker.
@export var exposure_slew_seconds: float = 0.5
## How often the exposure raycasts run. No reason for this to be per-frame.
@export var exposure_hz: float = 12.0

# --- outputs. Read these; never write them. --------------------------------

## The biome the player is standing in. One entry per biome in `_states`.
var active_biome: StringName = &"desert"

## Lightning flash, written by LightningDirector and pushed to the sky here.
var flash_energy: float = 0.0
var flash_direction: Vector3 = Vector3.UP

## 0..1, smoothed. 1 = standing in unobstructed sunlight.
var sun_exposure: float = 1.0
## 0..1, smoothed. 1 = standing out in the open wind.
var wind_exposure: float = 1.0

var _states: Dictionary = {}
var _cirrus_offset := Vector2.ZERO
var _deck_offset := Vector2.ZERO
var _env: Environment
var _player: Node3D
var _exposure_clock: float = 0.0
var _sun_exposure_target: float = 1.0
var _wind_exposure_target: float = 1.0


func _ready() -> void:
	if desert_profile == null:
		desert_profile = BiomeWeather.new()
		push_warning("WeatherSystem: no BiomeWeather assigned, using defaults.")

	# Built before the clock is checked, so get_state() is never null for the
	# HUD, the wind, the dust or the lightning even in a scene with no
	# DayNightCycle in it.
	# One biome so far. A second is one more line here plus its resource.
	_add_biome(&"desert", desert_profile)

	if day_night == null:
		day_night = get_tree().get_first_node_in_group("day_night") as DayNightCycle
	if day_night == null:
		push_warning("WeatherSystem: no DayNightCycle in group 'day_night'. "
			+ "Weather is frozen.")
		set_process(false)
		return

	if chunk_manager == null:
		chunk_manager = get_tree().get_first_node_in_group("chunk_manager") as ChunkManager
	_player = get_tree().get_first_node_in_group("player") as Node3D

	if day_night.world_environment and day_night.world_environment.environment:
		_env = day_night.world_environment.environment

	_step_states(0.0)
	_render()


## Re-seed every biome. Called by world.gd once the session seed is known --
## which is after this node's _ready(), since children are readied before their
## parent. In co-op this is the host's seed, replicated to every client.
func set_world_seed(value: int) -> void:
	world_seed = value
	for id: StringName in _states:
		var state: BiomeWeatherState = _states[id]
		state.setup(id, state.profile, world_seed)


func _add_biome(id: StringName, profile: BiomeWeather) -> void:
	var state := BiomeWeatherState.new()
	state.setup(id, profile, world_seed)
	state.event_started.connect(_on_state_event_started.bind(id))
	state.event_ended.connect(_on_state_event_ended.bind(id))
	_states[id] = state


func _process(delta: float) -> void:
	_update_exposure(delta)
	_step_states(delta * day_night.get_hours_per_second())
	_drift_clouds(delta)
	_render()


# --- public API -------------------------------------------------------------

## The weather where the player is standing. Never null after _ready().
func get_state() -> BiomeWeatherState:
	return _states.get(active_biome) as BiomeWeatherState


## The weather in some other biome. Null if that biome does not exist.
func get_biome_state(id: StringName) -> BiomeWeatherState:
	return _states.get(id) as BiomeWeatherState


func get_biome_ids() -> Array:
	return _states.keys()


## Start a weather event in the active biome. This is what an in-game item
## calls, and what the debug console calls -- both land on exactly the same
## path the timer uses, including how the timer behaves afterwards.
func trigger_event(token: StringName) -> bool:
	var e := WeatherEvent.by_id(token)
	if e == null:
		return false
	get_state().trigger(e)
	return true


func trigger_random_event() -> WeatherEvent:
	return get_state().trigger_random()


## Debug only: cut the running event short and roll a fresh timer.
func clear_event() -> void:
	get_state().end_event()


## Run the simulation forward without waiting for it, in in-game hours. Used by
## the console's 'time' command so a jump to dawn does not leave the weather
## standing at yesterday's temperature. Substepped rather than taken in one
## bite, so events inside the skipped window still start and finish.
func fast_forward(hours: float) -> void:
	var remaining := absf(hours)
	var step_h := 0.25
	var days := day_night.days_elapsed
	var guard := 0
	while remaining > 0.0 and guard < 4000:
		var dt := minf(step_h, remaining)
		remaining -= dt
		guard += 1
		days += dt / 24.0
		var alt := day_night.sun_altitude_at(days)
		for id: StringName in _states:
			(_states[id] as BiomeWeatherState).step(dt, days, alt)


## Which biome profile applies at a given distance west. A stub for now --
## every 150 km this will pick a different profile and blend across the seam.
func profile_for_distance(_metres_west: float) -> BiomeWeather:
	return desert_profile


# --- helpers other systems read --------------------------------------------

func get_wind_speed_kmh() -> float:
	return get_state().wind_speed_kmh


## Metres per second, for particles, audio and vehicle drag.
func get_wind_speed_ms() -> float:
	return get_state().wind_speed_kmh / 3.6


func get_wind_vector() -> Vector3:
	return get_state().wind_direction * get_wind_speed_ms()


## Unit vector pointing at where the wind is coming from. Used to place things
## upwind of the player -- dust, sound sources, anything that should approach
## with the air rather than against it.
func get_upwind() -> Vector3:
	return -get_state().wind_direction


## Compass point the wind is coming FROM. Meteorological convention: a
## "westerly" blows from the west. North is -Z, matching the celestial pole
## in DayNightCycle.
func get_wind_compass() -> String:
	const POINTS := ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
		"S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
	var from := -get_state().wind_direction
	var bearing := fposmod(rad_to_deg(atan2(from.x, -from.z)), 360.0)
	return POINTS[int(round(bearing / 22.5)) % 16]


## Beaufort-style label in km/h, for the HUD and later for dialogue.
func get_wind_label() -> String:
	var kmh := get_state().wind_speed_kmh
	if kmh < 1.0:
		return "Still"
	if kmh < 6.0:
		return "Light air"
	if kmh < 12.0:
		return "Light breeze"
	if kmh < 20.0:
		return "Moderate"
	if kmh < 30.0:
		return "Fresh"
	if kmh < 45.0:
		return "Strong"
	return "Gale"


## How much of the sky's light actually reaches the ground, 0..1. Cloud takes
## some, dust takes nearly all of it. Read by the player's body glow so it
## comes on inside a dust storm at noon, which is when it is most needed.
func get_light_transmission() -> float:
	var s := get_state()
	# The LIGHT figures, not the heating ones -- cloud and dust swallow far
	# more of the view than they do of the warmth. See BiomeWeather.
	var cloud_block := s.cloud_cover * s.profile.cloud_light_block
	var dust_block := s.dust_haze * s.profile.dust_light_block
	return clampf(1.0 - maxf(cloud_block, dust_block), 0.0, 1.0)


## Light level after weather, 0..1. Same contract as DayNightCycle's, which
## knows about the sun and moon but not about what is in the way of them.
func get_effective_light_level() -> float:
	return day_night.get_light_level() * get_light_transmission()


## Force cloud coverage instead of the simulation, for the console's 'clouds'
## command. Pass -1 for a layer to leave it natural.
func debug_set_cloud_coverage(cirrus: float, deck: float) -> void:
	get_state().set_forced_clouds(
		cirrus if cirrus < 0.0 else clampf(cirrus, 0.0, 1.0),
		deck if deck < 0.0 else clampf(deck, 0.0, 1.0))


func debug_clear_cloud_override() -> void:
	get_state().clear_forced_clouds()


# --- internals --------------------------------------------------------------

func _on_state_event_started(e: WeatherEvent, id: StringName) -> void:
	if id == active_biome:
		weather_event_started.emit(e)


func _on_state_event_ended(e: WeatherEvent, id: StringName) -> void:
	if id == active_biome:
		weather_event_ended.emit(e)


func _step_states(dt_hours: float) -> void:
	var days := day_night.days_elapsed
	var alt := day_night.sun_direction.y
	for id: StringName in _states:
		var state: BiomeWeatherState = _states[id]
		if id == active_biome:
			state.step(dt_hours, days, alt, sun_exposure, wind_exposure)
		else:
			# Nobody is standing there, so there is nobody to shelter. Its felt
			# temperature is what an exposed person would experience.
			state.step(dt_hours, days, alt)


## Two raycasts, a few times a second, from wherever the player's eyes are.
## Using the active camera rather than the player node means this keeps working
## while they are driving, when the player node itself is dormant.
func _update_exposure(delta: float) -> void:
	_exposure_clock += delta
	if _exposure_clock >= 1.0 / maxf(exposure_hz, 1.0):
		_exposure_clock = 0.0
		_sample_exposure()

	var k := clampf(delta / maxf(exposure_slew_seconds, 0.001), 0.0, 1.0)
	sun_exposure = lerpf(sun_exposure, _sun_exposure_target, k)
	wind_exposure = lerpf(wind_exposure, _wind_exposure_target, k)


func _sample_exposure() -> void:
	# In a vehicle: out of the wind entirely, but the sun still comes through
	# the glass. No raycast needed, and none would give the right answer -- the
	# camera sits inside the car's own collision shape.
	# call() rather than _player.is_driving(): _player is typed Node3D here, and
	# a direct call to a method the base class does not declare will not
	# compile, however sure we are that the player script has it.
	if _player and _player.has_method(&"is_driving") and bool(_player.call(&"is_driving")):
		_sun_exposure_target = vehicle_sun_fraction
		_wind_exposure_target = 0.0
		return

	var cam := get_viewport().get_camera_3d()
	if cam == null:
		_sun_exposure_target = 1.0
		_wind_exposure_target = 1.0
		return

	var space := cam.get_world_3d().direct_space_state
	var origin := cam.global_position
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())

	# Sun: anything between the player and the sun is shade. Below the horizon
	# there is nothing to be exposed to, so skip the cast.
	var sun_dir := day_night.sun_direction
	if sun_dir.y <= 0.0:
		_sun_exposure_target = 0.0
	else:
		var q := PhysicsRayQueryParameters3D.create(
			origin, origin + sun_dir * shade_ray_length)
		q.exclude = exclude
		_sun_exposure_target = 0.0 if space.intersect_ray(q) else 1.0

	# Wind: a roof overhead is what shelters you, and only partly.
	var up := PhysicsRayQueryParameters3D.create(
		origin, origin + Vector3.UP * cover_ray_length)
	up.exclude = exclude
	_wind_exposure_target = sheltered_wind_fraction if space.intersect_ray(up) else 1.0


## Wind-driven scroll for both cloud decks. The low deck moves faster than the
## cirrus for the same wind -- parallax, since it sits closer.
func _drift_clouds(delta: float) -> void:
	var s := get_state()
	var v := Vector2(s.wind_direction.x, s.wind_direction.z) * (s.wind_speed_kmh / 3.6)
	_cirrus_offset += v * cirrus_scale * cloud_drift_multiplier * delta
	_deck_offset += v * deck_scale * cloud_drift_multiplier * deck_parallax * delta


func _render() -> void:
	_push_sky()
	_push_lights()
	_push_fog()
	_push_terrain_shadow()


func _push_sky() -> void:
	var mat := day_night.get_sky_material()
	if mat == null:
		return
	var s := get_state()

	mat.set_shader_parameter("cloud_time", day_night.days_elapsed)
	mat.set_shader_parameter("cloud_turbulence", cloud_turbulence)

	# Storm cloud is lit from below by nothing at all. Driving the shade colour
	# rather than the opacity is what keeps the silhouette while killing the
	# brightness -- a dark sky, not a thin one.
	mat.set_shader_parameter("cloud_shade_color",
		cloud_shade_color.lerp(cloud_storm_color, s.storm_intensity))

	mat.set_shader_parameter("cloud_hi_coverage", s.cirrus_cover)
	mat.set_shader_parameter("cloud_hi_offset", _cirrus_offset)
	mat.set_shader_parameter("cloud_hi_altitude", cirrus_altitude)
	mat.set_shader_parameter("cloud_hi_curvature_radius", cirrus_curvature_radius)
	mat.set_shader_parameter("cloud_hi_scale", cirrus_scale)
	mat.set_shader_parameter("cloud_hi_region_scale", cirrus_region_scale)
	mat.set_shader_parameter("cloud_hi_shape_floor", cirrus_shape_floor)
	mat.set_shader_parameter("cloud_hi_stretch", cirrus_stretch)

	mat.set_shader_parameter("cloud_lo_coverage", s.deck_cover)
	mat.set_shader_parameter("cloud_lo_offset", _deck_offset)
	mat.set_shader_parameter("cloud_lo_altitude", deck_altitude)
	mat.set_shader_parameter("cloud_lo_curvature_radius", deck_curvature_radius)
	mat.set_shader_parameter("cloud_lo_scale", deck_scale)
	mat.set_shader_parameter("cloud_lo_region_scale", deck_region_scale)
	# As the deck closes over, drop the floor so the puffs merge into one
	# unbroken sheet instead of staying separate lumps at 100% coverage.
	mat.set_shader_parameter("cloud_lo_shape_floor",
		lerpf(deck_shape_floor, 0.02, s.deck_cover))
	mat.set_shader_parameter("cloud_lo_stretch", Vector2.ONE)

	mat.set_shader_parameter("flash_energy", flash_energy)
	mat.set_shader_parameter("flash_direction", flash_direction)

	# Dust hides the sky itself -- sun disk, stars, moon and all. The fog below
	# does the same for anything on the ground.
	mat.set_shader_parameter("dust_amount", s.dust_haze)
	mat.set_shader_parameter("dust_color", dust_color)
	# Dust is lit by whatever is above it, so it goes from a bright tan wall by
	# day to near-black at night. That is what makes a night dust storm the
	# genuinely frightening version.
	mat.set_shader_parameter("dust_light",
		lerpf(0.03, 1.0, day_night.get_light_level()) + flash_energy * 0.35)

	# Starlight, moonlight and sunlight all have to get through the same dust.
	mat.set_shader_parameter("star_energy",
		day_night.star_brightness
		* (1.0 - day_night.star_moon_washout * day_night.moon_illumination
			* smoothstep(-0.10, 0.14, day_night.moon_direction.y))
		* (1.0 - s.dust_haze))


## DayNightCycle sets these to their clear-sky values every frame; this node
## runs after it and takes some of it back.
func _push_lights() -> void:
	var t := get_light_transmission()
	if day_night.sun:
		day_night.sun.light_energy *= t
		day_night.sun.visible = day_night.sun.light_energy > 0.001
	if day_night.moon:
		day_night.moon.light_energy *= t
		day_night.moon.visible = day_night.moon.light_energy > 0.0005


func _push_fog() -> void:
	if _env == null:
		return
	var s := get_state()
	var dust := clampf(s.dust_haze, 0.0, 1.0)
	if dust <= 0.001:
		_env.fog_depth_begin = clear_fog_begin
		_env.fog_depth_end = clear_fog_distance
		return

	# Curved, not linear: the last stretch from "hazy" to "cannot see your own
	# hand" happens over the tail of the dust, which is where it matters.
	var reach := lerpf(clear_fog_distance, dust_fog_distance, pow(dust, 0.45))
	_env.fog_depth_begin = minf(clear_fog_begin, reach * 0.15)
	_env.fog_depth_end = reach
	# The dust is lit by the sky above it, same as the sky-side haze.
	var lit := lerpf(0.05, 1.0, day_night.get_light_level()) + flash_energy * 0.4
	_env.fog_light_color = _env.fog_light_color.lerp(dust_color * lit, dust)


## The moving shadow the cloud decks cast on the ground. Sampled at world XZ
## rather than view direction, so it drifts with the same offset the sky uses
## without needing to match it pixel-for-pixel.
func _push_terrain_shadow() -> void:
	if chunk_manager == null:
		return
	var mat := chunk_manager.get_terrain_material()
	if mat == null:
		return
	var s := get_state()
	# Under a closed deck the shadow is the deck's; otherwise it is the
	# cirrus's, which is faint and fast-moving.
	var use_deck := s.deck_cover > s.cirrus_cover
	mat.set_shader_parameter("cloud_shadow_time", day_night.days_elapsed)
	mat.set_shader_parameter("cloud_shadow_offset",
		_deck_offset if use_deck else _cirrus_offset)
	mat.set_shader_parameter("cloud_shadow_scale",
		deck_scale if use_deck else cirrus_scale)
	mat.set_shader_parameter("cloud_shadow_coverage",
		s.deck_cover if use_deck else s.cirrus_cover)
	mat.set_shader_parameter("cloud_shadow_region_scale",
		deck_region_scale if use_deck else cirrus_region_scale)
	mat.set_shader_parameter("cloud_shadow_turbulence", cloud_turbulence)
	mat.set_shader_parameter("cloud_shadow_strength",
		s.profile.cloud_shadow_strength)
