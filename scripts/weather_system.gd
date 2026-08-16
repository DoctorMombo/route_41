class_name WeatherSystem
extends Node

## Weather driver for ROUTE 41.
##
## Every output is a pure function of (world_seed, days_elapsed) and the
## active BiomeWeather profile. No accumulated state, no random walk.
##
## That is load-bearing for co-op: the host replicates nothing. Every client
## already has days_elapsed from DayNightCycle, so all of them independently
## compute the same temperature, the same wind. It also means weather can be
## scrubbed forward and back for testing, which a stateful simulation could
## not do.
##
## Temperature, wind speed, wind direction and humidity drive survival, per
## BiomeWeather. Two cloud decks ride alongside them, procedurally generated
## rather than sampled from a texture, so they can be driven by the same
## clock -- coverage, drift and the roiling of the puffs themselves are all
## functions of days_elapsed. A new biome is a new profile resource; the
## simulation itself never needs to know which one it is running.

@export var day_night: DayNightCycle
## Profile for the starting biome. Later this is selected by distance west.
@export var desert_profile: BiomeWeather
## Left empty, found via the "chunk_manager" group. Only needed so cloud
## shadow can be pushed onto the terrain material.
@export var chunk_manager: ChunkManager
@export var world_seed: int = 0
## Scrub this in the Inspector while stopped to preview a different moment.
@export var preview_days: float = -1.0

@export_group("Clouds")
## Metres above the ground for the thin, high deck.
@export var cloud_high_altitude: float = 2600.0
## World metres to uv for the high deck. One uv unit is 1.0 / this many metres.
@export var cloud_high_scale: float = 0.00016
@export var cloud_high_region_scale: float = 0.20
## Radius of the shell the high deck sits on -- bounds how far toward the
## horizon it reaches, and so how many times its pattern repeats.
@export var cloud_high_curvature_radius: float = 45000.0
## Higher than the low deck's -- thin and sparse rather than a solid sheet.
@export var cloud_high_shape_floor: float = 0.52
## Stretched hard along one axis: draws puffs out into wispy cirrus streaks.
@export var cloud_high_stretch: Vector2 = Vector2(3.2, 1.0)
## Metres above the ground for the lower, puffier deck.
@export var cloud_low_altitude: float = 900.0
@export var cloud_low_scale: float = 0.00034
@export var cloud_low_region_scale: float = 0.30
@export var cloud_low_curvature_radius: float = 30000.0
## Lower than the high deck's -- fills in to solid, rounded lumps.
@export var cloud_low_shape_floor: float = 0.24
## Round: no stretch. This is the fat, puffy cumulus-style deck.
@export var cloud_low_stretch: Vector2 = Vector2(1.0, 1.0)
## The low deck scrolls faster than the high deck for the same wind -- it is
## closer, so it reads as moving faster. Parallax, not physics. Kept modest:
## anything higher and a deck that is meant to read as large and slow-moving
## visibly crosses its own width every few seconds instead.
@export var cloud_low_parallax: float = 1.3
## Clouds drift at wind speed times this. 1.0 would be physically real wind
## speed, which is too slow to read against gameplay timescales; this is an
## artistic exaggeration, not a scale factor to push higher without watching
## it drift first.
@export var cloud_drift_multiplier: float = 4.0
## How hard the puff shape churns over time, independent of wind-driven drift.
## A large domain warp sourced from a coarse field is what produces visible
## boxy creases, so keep this modest rather than cranking it for "roil".
@export var cloud_turbulence: float = 0.35

# --- outputs. Read these; never write them. --------------------------------

## Horizontal unit vector the wind blows toward.
var wind_direction: Vector3 = Vector3.FORWARD
## Metres per second.
var wind_speed: float = 0.0
## Actual air temperature in Celsius.
var temperature_c: float = 20.0
## What it feels like after wind chill. This is what survival should read.
var felt_temperature_c: float = 20.0
## Relative humidity, 0..1 (the desert never exceeds ~0.05).
var humidity: float = 0.0
## 0..1 fraction of sky covered by the high, thin deck.
var cloud_high_coverage: float = 0.0
## 0..1 fraction of sky covered by the lower, puffier deck.
var cloud_low_coverage: float = 0.0

var _profile: BiomeWeather
var _n_regime := FastNoiseLite.new()
var _n_gust := FastNoiseLite.new()
var _n_bearing := FastNoiseLite.new()
var _n_humidity := FastNoiseLite.new()
var _n_cloud_high := FastNoiseLite.new()
var _n_cloud_low := FastNoiseLite.new()

## Integrated, not derived from days_elapsed. Wind direction changes over
## time, so offset = direction * speed * elapsed would swing the whole sky
## sideways every time the bearing moved. The one stateful cosmetic value
## here -- everything else stays a pure function of time.
var _cloud_offset_high := Vector2.ZERO
var _cloud_offset_low := Vector2.ZERO

## Debug override for cloud coverage. -1 means "follow the natural
## simulation"; the debug console's 'clouds' command is the only writer.
var _debug_cloud_hi := -1.0
var _debug_cloud_lo := -1.0


func _ready() -> void:
	if day_night == null:
		day_night = get_tree().get_first_node_in_group("day_night") as DayNightCycle
	if day_night == null:
		push_warning("WeatherSystem: no DayNightCycle in group 'day_night'.")
		set_process(false)
		return

	if desert_profile == null:
		desert_profile = BiomeWeather.new()
		push_warning("WeatherSystem: no BiomeWeather assigned, using defaults.")
	_profile = desert_profile

	if chunk_manager == null:
		chunk_manager = get_tree().get_first_node_in_group("chunk_manager") as ChunkManager

	for n in [_n_regime, _n_gust, _n_bearing, _n_humidity, _n_cloud_high, _n_cloud_low]:
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 1.0
		n.fractal_octaves = 2
	_n_regime.seed = world_seed + 201
	_n_gust.seed = world_seed + 211
	_n_bearing.seed = world_seed + 223
	_n_humidity.seed = world_seed + 233
	_n_cloud_high.seed = world_seed + 251
	_n_cloud_low.seed = world_seed + 257

	_evaluate()


func _process(delta: float) -> void:
	_evaluate()
	_drift_clouds(delta)
	_push_sky()
	_push_terrain_shadow()


# --- public helpers ---------------------------------------------------------

func get_clock_source() -> DayNightCycle:
	return day_night


## Wind as a velocity vector, for particles and later for vehicle drag.
func get_wind_vector() -> Vector3:
	return wind_direction * wind_speed


## Unit vector pointing at where the wind is coming from. Used to place things
## upwind of the player -- dust, sound sources, anything that should approach
## with the air rather than against it.
func get_upwind() -> Vector3:
	return -wind_direction


## Compass point the wind is coming FROM. Meteorological convention: a
## "westerly" blows from the west. North is -Z, matching the celestial pole
## in DayNightCycle.
func get_wind_compass() -> String:
	const POINTS := ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
		"S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
	var from := -wind_direction
	var bearing := fposmod(rad_to_deg(atan2(from.x, -from.z)), 360.0)
	return POINTS[int(round(bearing / 22.5)) % 16]


## Rough Beaufort-style label, for HUD and later for dialogue.
func get_wind_label() -> String:
	if wind_speed < 1.5:
		return "Still"
	if wind_speed < 5.0:
		return "Light breeze"
	if wind_speed < 10.0:
		return "Steady wind"
	if wind_speed < 17.0:
		return "Strong wind"
	return "Gale"


## Which biome profile applies at a given distance west. A stub for now --
## every 150 km this will pick a different profile and blend across the seam.
func profile_for_distance(_metres_west: float) -> BiomeWeather:
	return desert_profile


## Force cloud coverage instead of the natural simulation, for the debug
## console's 'clouds' command. Pass -1 for a layer to leave it natural.
func debug_set_cloud_coverage(hi: float, lo: float) -> void:
	_debug_cloud_hi = hi if hi < 0.0 else clampf(hi, 0.0, 1.0)
	_debug_cloud_lo = lo if lo < 0.0 else clampf(lo, 0.0, 1.0)


func debug_clear_cloud_override() -> void:
	_debug_cloud_hi = -1.0
	_debug_cloud_lo = -1.0


# --- internals --------------------------------------------------------------

## FastNoiseLite returns roughly -1..1; weather wants 0..1.
func _unit(n: FastNoiseLite, t: float) -> float:
	return clampf(n.get_noise_1d(t) * 0.5 + 0.5, 0.0, 1.0)


func _evaluate() -> void:
	var days := day_night.days_elapsed
	if preview_days >= 0.0:
		days = preview_days

	_profile = profile_for_distance(0.0)
	var p := _profile

	# --- wind speed ----------------------------------------------------
	# A slow regime (calm spells vs. blowy ones) modulated by fast gusts.
	var regime := _unit(_n_regime, days / maxf(p.wind_regime_days, 0.01))
	var base := lerpf(p.wind_calm, p.wind_strong, pow(regime, 1.8))
	var gust := _unit(_n_gust, days / maxf(p.wind_gust_days, 0.0001))
	wind_speed = base * lerpf(0.7, 1.4, gust)

	# --- wind direction --------------------------------------------------
	# Random, and drifts gradually round the compass over wind_bearing_days.
	var bearing := _n_bearing.get_noise_1d(days / maxf(p.wind_bearing_days, 0.01)) * PI
	wind_direction = Vector3(sin(bearing), 0.0, -cos(bearing)).normalized()

	# --- temperature -------------------------------------------------------
	# Driven by where the sun was a couple of hours ago, not where it is now --
	# rock and sand heat and cool slowly, so peak temperature lands
	# mid-afternoon and the minimum just before dawn.
	var lag := p.temperature_lag_hours / 24.0
	var lagged_alt := day_night.sun_altitude_at(day_night.time_of_day - lag)
	var warmth := clampf(inverse_lerp(-0.45, 0.90, lagged_alt), 0.0, 1.0)

	var mean := (p.temp_day_c + p.temp_night_c) * 0.5
	var half := (p.temp_day_c - p.temp_night_c) * 0.5
	temperature_c = mean + half * (warmth * 2.0 - 1.0)

	# --- felt temperature: wind chill ---------------------------------------
	# Wind makes a hot day feel a little cooler and a cold night feel frigid,
	# so the coefficient itself slides with how cold it already is. The drop
	# scales with sqrt(wind), not wind directly -- chill has strongly
	# diminishing returns as wind climbs, same shape as real wind-chill charts.
	var coldness := clampf(inverse_lerp(p.temp_day_c, p.temp_night_c, temperature_c), 0.0, 1.0)
	var chill_per_ms := lerpf(p.wind_chill_hot_per_ms, p.wind_chill_cold_per_ms, coldness)
	felt_temperature_c = temperature_c - chill_per_ms * sqrt(wind_speed)

	# --- humidity ------------------------------------------------------
	# Wanders between the biome's floor and ceiling. In the desert that ceiling
	# never exceeds 5%.
	var humid_raw := _unit(_n_humidity, days / maxf(p.humidity_period_days, 0.01))
	humidity = lerpf(p.humidity_min, p.humidity_max, humid_raw)

	# --- clouds --------------------------------------------------------
	# Each deck wanders independently between bare sky and its own ceiling; the
	# low deck cycles on a slightly different period so the two decks are never
	# building or clearing in lockstep.
	var hi_raw := _unit(_n_cloud_high, days / maxf(p.cloud_period_days, 0.01))
	cloud_high_coverage = hi_raw * p.cloud_high_max
	var lo_raw := _unit(_n_cloud_low, days / maxf(p.cloud_period_days * 1.35, 0.01))
	cloud_low_coverage = lo_raw * p.cloud_low_max

	if _debug_cloud_hi >= 0.0:
		cloud_high_coverage = _debug_cloud_hi
	if _debug_cloud_lo >= 0.0:
		cloud_low_coverage = _debug_cloud_lo

	# Clouds block the sun and moon a little as they thicken. This is a global
	# approximation -- "how much of the sky is covered right now" standing in
	# for "is a cloud directly overhead" -- rather than a true positional
	# shadow, which is what the terrain's per-pixel cloud shadow is for.
	var block := 1.0 - (1.0 - cloud_high_coverage) * (1.0 - cloud_low_coverage)
	var dim := 1.0 - block * p.cloud_shadow_strength
	if day_night.sun:
		day_night.sun.light_energy *= dim
	if day_night.moon:
		day_night.moon.light_energy *= dim


## Wind-driven scroll for both cloud decks. The low deck moves faster than the
## high one for the same wind -- parallax, since it sits closer.
func _drift_clouds(delta: float) -> void:
	var v := Vector2(wind_direction.x, wind_direction.z) * wind_speed
	_cloud_offset_high += v * cloud_high_scale * cloud_drift_multiplier * delta
	_cloud_offset_low += v * cloud_low_scale * cloud_drift_multiplier \
		* cloud_low_parallax * delta


func _push_sky() -> void:
	var mat := day_night.get_sky_material()
	if mat == null:
		return
	mat.set_shader_parameter("cloud_time", day_night.days_elapsed)
	mat.set_shader_parameter("cloud_turbulence", cloud_turbulence)
	mat.set_shader_parameter("cloud_hi_coverage", cloud_high_coverage)
	mat.set_shader_parameter("cloud_hi_offset", _cloud_offset_high)
	mat.set_shader_parameter("cloud_hi_altitude", cloud_high_altitude)
	mat.set_shader_parameter("cloud_hi_curvature_radius", cloud_high_curvature_radius)
	mat.set_shader_parameter("cloud_hi_scale", cloud_high_scale)
	mat.set_shader_parameter("cloud_hi_region_scale", cloud_high_region_scale)
	mat.set_shader_parameter("cloud_hi_shape_floor", cloud_high_shape_floor)
	mat.set_shader_parameter("cloud_hi_stretch", cloud_high_stretch)
	mat.set_shader_parameter("cloud_lo_coverage", cloud_low_coverage)
	mat.set_shader_parameter("cloud_lo_offset", _cloud_offset_low)
	mat.set_shader_parameter("cloud_lo_altitude", cloud_low_altitude)
	mat.set_shader_parameter("cloud_lo_curvature_radius", cloud_low_curvature_radius)
	mat.set_shader_parameter("cloud_lo_scale", cloud_low_scale)
	mat.set_shader_parameter("cloud_lo_region_scale", cloud_low_region_scale)
	mat.set_shader_parameter("cloud_lo_shape_floor", cloud_low_shape_floor)
	mat.set_shader_parameter("cloud_lo_stretch", cloud_low_stretch)


## The moving shadow the high deck casts on the ground. Sampled at world XZ
## rather than view direction, so it drifts with the same offset the sky uses
## without needing to match it pixel-for-pixel.
func _push_terrain_shadow() -> void:
	if chunk_manager == null:
		return
	var mat := chunk_manager.get_terrain_material()
	if mat == null:
		return
	mat.set_shader_parameter("cloud_shadow_time", day_night.days_elapsed)
	mat.set_shader_parameter("cloud_shadow_offset", _cloud_offset_high)
	mat.set_shader_parameter("cloud_shadow_scale", cloud_high_scale)
	mat.set_shader_parameter("cloud_shadow_coverage", cloud_high_coverage)
	mat.set_shader_parameter("cloud_shadow_region_scale", cloud_high_region_scale)
	mat.set_shader_parameter("cloud_shadow_turbulence", cloud_turbulence)
	mat.set_shader_parameter("cloud_shadow_strength", _profile.cloud_shadow_strength)
