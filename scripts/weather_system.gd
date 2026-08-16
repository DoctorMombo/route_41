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
## Four dials drive everything, per BiomeWeather: temperature, wind speed,
## wind direction and humidity. A new biome is a new profile resource; the
## simulation itself never needs to know which one it is running.

@export var day_night: DayNightCycle
## Profile for the starting biome. Later this is selected by distance west.
@export var desert_profile: BiomeWeather
@export var world_seed: int = 0
## Scrub this in the Inspector while stopped to preview a different moment.
@export var preview_days: float = -1.0

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

var _profile: BiomeWeather
var _n_regime := FastNoiseLite.new()
var _n_gust := FastNoiseLite.new()
var _n_bearing := FastNoiseLite.new()
var _n_humidity := FastNoiseLite.new()


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

	for n in [_n_regime, _n_gust, _n_bearing, _n_humidity]:
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 1.0
		n.fractal_octaves = 2
	_n_regime.seed = world_seed + 201
	_n_gust.seed = world_seed + 211
	_n_bearing.seed = world_seed + 223
	_n_humidity.seed = world_seed + 233

	_evaluate()


func _process(_delta: float) -> void:
	_evaluate()


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
