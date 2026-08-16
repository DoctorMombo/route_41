class_name BiomeWeatherState
extends RefCounted

## The weather of one biome, simulated.
##
## Every biome owns one of these and weathers independently: its own
## temperature, its own event timer, its own storm. WeatherSystem holds them
## all and only *renders* the one the player is standing in. Adding a biome is
## adding a BiomeWeather resource and one more entry in that dictionary --
## nothing here needs to know which biome it is running.
##
## Unlike the previous system this is stateful, not a pure function of time.
## It has to be: temperature integrates (which is the only way the low lands at
## dawn rather than at midnight), and events have timers. For co-op that means
## the host is authoritative and replicates this handful of floats. That is a
## far smaller payload than terrain, and it buys weather that can actually
## build and break.
##
## The chain of causation, in order, because it matters:
##
##   sun altitude -> (blocked by cloud and dust) -> temperature target
##   temperature  -> chases the target, slowly    -> temperature
##   temperature  -> hot air holds no moisture    -> humidity
##   temperature + wind + sun exposure            -> felt temperature

signal event_started(event: WeatherEvent)
signal event_ended(event: WeatherEvent)

## Blend phase of the active event, for the HUD.
enum Phase { NONE, BUILDING, FULL, CLEARING }

var biome_id: StringName = &"desert"
var profile: BiomeWeather

# --- the six tracked stats --------------------------------------------------

## Air temperature in Celsius.
var temperature_c: float = 20.0
## Relative humidity, 0..1.
var humidity: float = 0.02
## Wind speed in km/h. Ordinary desert wind is 0-15; events go past that.
var wind_speed_kmh: float = 0.0
## Fraction of the sky under cloud, 0..1. Both decks combined.
var cloud_cover: float = 0.0
## Horizontal unit vector the wind blows *toward*.
var wind_direction: Vector3 = Vector3.FORWARD
## What the player actually experiences: air temperature plus the sun beating
## on them, minus what the wind takes away. This is the number survival reads.
var felt_temperature_c: float = 20.0

# --- supporting outputs -----------------------------------------------------

## Feathery high cirrus, 0..1. This is the desert's ordinary sky.
var cirrus_cover: float = 0.0
## The low solid deck, 0..1. Zero unless an event has closed the sky over.
var deck_cover: float = 0.0
## Airborne dust, 0..1. Outlives the storm that raised it.
var dust_haze: float = 0.0
## 0..1 while a thunderstorm is overhead -- drives lightning and cloud colour.
var storm_intensity: float = 0.0
## 0..1 while a dust storm is blowing (the wind, not the leftover haze).
var dust_storm_intensity: float = 0.0

# --- event state ------------------------------------------------------------

## The running event, or null when the sky is behaving itself.
var event: WeatherEvent = null
var phase: Phase = Phase.NONE
## 0..1 ramp from ordinary conditions to the event's targets.
var event_blend: float = 0.0
## In-game hours until the timer fires. Only counts down between events.
var hours_to_event: float = 24.0

# --- internals --------------------------------------------------------------

var _rng := RandomNumberGenerator.new()
var _n_regime := FastNoiseLite.new()
var _n_gust := FastNoiseLite.new()
var _n_bearing := FastNoiseLite.new()
var _n_cirrus := FastNoiseLite.new()

var _world_seed: int = 0
var _event_elapsed_h: float = 0.0
var _onset_h: float = 1.0
var _sustain_h: float = 4.0
var _fade_h: float = 1.0
var _dust_clear_h: float = 16.0
## Set when the timer (or an item, or the console) asks for an event but one is
## already running. Honoured the moment the current one lets go.
var _queued: WeatherEvent = null

## Debug override for the cloud decks. -1 means "follow the simulation".
var _forced_cirrus: float = -1.0
var _forced_deck: float = -1.0

## True until the first step, so temperature can be seeded to something
## plausible for the time of day rather than warming up from 20 C.
var _needs_seed: bool = true


func setup(id: StringName, weather_profile: BiomeWeather, world_seed: int) -> void:
	biome_id = id
	profile = weather_profile
	_world_seed = world_seed

	# Salted per biome, so two biomes on the same world seed do not gust in
	# lockstep. Kept well inside 32 bits: FastNoiseLite's seed is an int32 and
	# silently wraps anything larger, which would silently collide biomes.
	var salt := absi(String(id).hash()) % 100000
	_rng.seed = world_seed ^ salt
	for n: FastNoiseLite in [_n_regime, _n_gust, _n_bearing, _n_cirrus]:
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 1.0
		n.fractal_octaves = 2
	_n_regime.seed = world_seed + salt + 201
	_n_gust.seed = world_seed + salt + 211
	_n_bearing.seed = world_seed + salt + 223
	_n_cirrus.seed = world_seed + salt + 251

	_roll_event_timer()


# --- public API -------------------------------------------------------------

## One tick of the simulation.
##
## `dt_hours` is in-game hours, `sun_altitude` is the sine of the sun's
## elevation right now, and the two exposure values are 0..1 -- 0 when the
## player is fully sheltered from that thing, 1 when they are standing out in
## it. Biomes the player is not in are stepped with exposure 1.0; their felt
## temperature is simply what an unsheltered person there would experience.
func step(dt_hours: float, days_elapsed: float, sun_altitude: float,
		sun_exposure: float = 1.0, wind_exposure: float = 1.0) -> void:
	if profile == null:
		return

	_step_event(dt_hours)
	_step_wind(days_elapsed)
	_step_clouds(days_elapsed)
	_step_dust(dt_hours)
	_step_temperature(dt_hours, days_elapsed, sun_altitude)
	_step_humidity(days_elapsed)
	_step_felt(sun_altitude, sun_exposure, wind_exposure)


## Start an event now. This is the single entry point for all three ways an
## event can begin -- the timer, an in-game item, and the debug console -- so
## that a forced event is indistinguishable from a natural one, including how
## the timer behaves afterwards.
##
## With one already running the new event waits its turn, rather than cutting
## the current one off mid-blend and snapping the sky. That is right for the
## timer and for an item: neither is allowed to make the weather jump.
##
## `replace` overrides it, and the debug console passes true. A command that
## quietly queued itself behind an eight-hour storm would look like it had done
## nothing at all, which is the opposite of what a debug tool is for. The sky
## does jump -- the running event is dropped to nothing and the new one builds
## in from clear over its own onset -- and for a console command that is the
## point.
func trigger(e: WeatherEvent, replace: bool = false) -> void:
	if e == null:
		return
	if event != null:
		if not replace:
			_queued = e
			return
		# The caller asked for THIS event now, so anything already waiting in
		# line is stale -- drop it rather than have it surface later out of
		# nowhere. end_event() rolls a fresh timer, which the new event's own
		# ending will roll again; harmless, and it keeps the two paths
		# identical to a natural end followed by a natural start.
		_queued = null
		end_event()

	event = e
	_event_elapsed_h = 0.0
	event_blend = 0.0
	phase = Phase.BUILDING
	_onset_h = _rng.randf_range(e.onset_hours.x, e.onset_hours.y)
	_sustain_h = _rng.randf_range(e.sustain_hours.x, e.sustain_hours.y)
	_fade_h = _rng.randf_range(e.fade_hours.x, e.fade_hours.y)
	_dust_clear_h = _rng.randf_range(e.dust_clear_hours.x, e.dust_clear_hours.y)
	event_started.emit(e)


## Cut the running event short. Debug only -- nothing in the game does this.
func end_event() -> void:
	if event == null:
		return
	var finished := event
	event = null
	phase = Phase.NONE
	event_blend = 0.0
	_roll_event_timer()
	event_ended.emit(finished)


## Roll the next event now instead of waiting for the timer. Used by the timer
## itself, which only ever calls it with nothing running, and by 'weather
## random' in the console, which passes replace through.
func trigger_random(replace: bool = false) -> WeatherEvent:
	var choices := WeatherEvent.library()
	var total := 0.0
	for e in choices:
		total += e.weight
	var roll := _rng.randf() * total
	for e in choices:
		roll -= e.weight
		if roll <= 0.0:
			trigger(e, replace)
			return e
	trigger(choices[0], replace)
	return choices[0]


func condition_name() -> String:
	if event != null:
		return event.display_name
	if dust_haze > 0.02:
		return "Dust Haze"
	if cloud_cover > 0.55:
		return "Cloudy"
	if cloud_cover > 0.15:
		return "Scattered Cloud"
	return "Clear"


func phase_name() -> String:
	match phase:
		Phase.BUILDING: return "building"
		Phase.FULL: return "at full strength"
		Phase.CLEARING: return "clearing"
		_: return ""


func set_forced_clouds(cirrus: float, deck: float) -> void:
	_forced_cirrus = cirrus
	_forced_deck = deck


func clear_forced_clouds() -> void:
	_forced_cirrus = -1.0
	_forced_deck = -1.0


## Seconds between in-cloud flashes right now, or ZERO for no lightning.
## Scaled by blend, so a storm starts with widely spaced flashes and closes up.
func cloud_flash_period() -> Vector2:
	if event == null or event.cloud_flash_seconds == Vector2.ZERO:
		return Vector2.ZERO
	return event.cloud_flash_seconds / maxf(event_blend, 0.15)


## Seconds between ground strikes right now, or ZERO for none.
func ground_strike_period() -> Vector2:
	if event == null or event.ground_strike_seconds == Vector2.ZERO:
		return Vector2.ZERO
	return event.ground_strike_seconds / maxf(event_blend, 0.15)


# --- internals --------------------------------------------------------------

## FastNoiseLite returns roughly -1..1; weather wants 0..1.
func _unit(n: FastNoiseLite, t: float) -> float:
	return clampf(n.get_noise_1d(t) * 0.5 + 0.5, 0.0, 1.0)


func _roll_event_timer() -> void:
	hours_to_event = _rng.randf_range(
		profile.event_interval_min_hours, profile.event_interval_max_hours)


func _step_event(dt_hours: float) -> void:
	if event == null:
		storm_intensity = 0.0
		dust_storm_intensity = 0.0
		# The timer only runs between events, so an event that lasts eight
		# hours does not eat eight hours of the wait for the next one. A
		# forced event therefore pushes the next one out by exactly its own
		# duration, same as a natural one.
		hours_to_event -= dt_hours
		if hours_to_event <= 0.0:
			if _queued != null:
				var q := _queued
				_queued = null
				trigger(q)
			else:
				trigger_random()
		return

	_event_elapsed_h += dt_hours
	var hold_end := _onset_h + _sustain_h
	var total := hold_end + _fade_h

	if _event_elapsed_h < _onset_h:
		phase = Phase.BUILDING
		event_blend = clampf(_event_elapsed_h / maxf(_onset_h, 0.001), 0.0, 1.0)
	elif _event_elapsed_h < hold_end:
		phase = Phase.FULL
		event_blend = 1.0
	elif _event_elapsed_h < total:
		phase = Phase.CLEARING
		event_blend = 1.0 - clampf(
			(_event_elapsed_h - hold_end) / maxf(_fade_h, 0.001), 0.0, 1.0)
	else:
		var finished := event
		event = null
		phase = Phase.NONE
		event_blend = 0.0
		storm_intensity = 0.0
		dust_storm_intensity = 0.0
		_roll_event_timer()
		event_ended.emit(finished)
		# A queued event waits out the full interval rather than starting the
		# moment the last one lets go -- otherwise 'weather storm' twice in a
		# row would chain two storms back to back.
		return

	# Smoothstep the blend so an event eases in and out instead of ramping
	# linearly and visibly stopping when it lands.
	event_blend = event_blend * event_blend * (3.0 - 2.0 * event_blend)

	storm_intensity = event_blend if event.kind == WeatherEvent.Kind.STORM else 0.0
	dust_storm_intensity = event_blend if event.kind == WeatherEvent.Kind.DUST_STORM else 0.0


func _step_wind(days_elapsed: float) -> void:
	var p := profile

	# Ordinary band, widened or pinched by whatever event is running.
	var lo := p.wind_min_kmh
	var hi := p.wind_max_kmh
	if event != null and event.wind_kmh.x >= 0.0:
		lo = lerpf(lo, event.wind_kmh.x, event_blend)
		hi = lerpf(hi, event.wind_kmh.y, event_blend)

	# A slow regime says whether this is a blowy stretch of day; fast gusting
	# rides on top of it. Splitting them is what stops the wind reading as
	# either a constant or as pure noise.
	var regime := _unit(_n_regime, days_elapsed / maxf(p.wind_regime_days, 0.01))
	var gust := _unit(_n_gust, days_elapsed / maxf(p.wind_gust_days, 0.0001))

	# Events shift weight from the regime onto the gusts. The regime turns over
	# across days, so inside a five-hour event it is very nearly a constant --
	# leaving the wind pinned to a narrow slice of the band the event asked
	# for, which made "15 to 40 km/h" come out as a steady 30. Strong wind is
	# also genuinely gustier than light wind, so this reads better as well as
	# covering the range.
	var share := lerpf(p.wind_regime_share, p.wind_event_regime_share, event_blend)
	var t := clampf(regime * share + gust * (1.0 - share), 0.0, 1.0)
	wind_speed_kmh = lerpf(lo, hi, t)

	# Direction wanders round the compass. It steadies as an event takes hold:
	# a dust storm blows from one quarter, not from everywhere at once.
	var steadiness := 1.0 - 0.75 * event_blend
	var bearing := _n_bearing.get_noise_1d(
		days_elapsed / maxf(p.wind_bearing_days, 0.01)) * PI * steadiness
	wind_direction = Vector3(sin(bearing), 0.0, -cos(bearing)).normalized()


func _step_clouds(days_elapsed: float) -> void:
	var p := profile

	# The desert's ordinary sky: a few percent of feathery cirrus, thickening
	# and thinning on its own slow clock. Never more than cirrus_max.
	var base_cirrus := _unit(_n_cirrus, days_elapsed / maxf(p.cirrus_period_days, 0.01)) \
		* p.cirrus_max

	cirrus_cover = base_cirrus
	deck_cover = 0.0
	if event != null:
		if event.cirrus_cover >= 0.0:
			cirrus_cover = lerpf(base_cirrus, event.cirrus_cover, event_blend)
		if event.deck_cover >= 0.0:
			deck_cover = lerpf(0.0, event.deck_cover, event_blend)

	if _forced_cirrus >= 0.0:
		cirrus_cover = _forced_cirrus
	if _forced_deck >= 0.0:
		deck_cover = _forced_deck

	# Two decks in front of each other. What fraction of the sky is covered is
	# what neither of them leaves open.
	cloud_cover = 1.0 - (1.0 - cirrus_cover) * (1.0 - deck_cover)


func _step_dust(dt_hours: float) -> void:
	var target := 0.0
	if event != null and event.dust > 0.0:
		target = event.dust * event_blend

	if target > dust_haze:
		# Dust goes up fast -- a wall arrives, it does not seep in.
		dust_haze = minf(target, dust_haze + dt_hours / 0.35)
	else:
		# ...and comes down slowly, on its own clock, long after the wind that
		# raised it has dropped. This is the part that makes a dust storm a
		# problem for the rest of the day rather than for an hour.
		dust_haze = maxf(0.0, dust_haze - dt_hours / maxf(_dust_clear_h, 0.1))


func _step_temperature(dt_hours: float, days_elapsed: float, sun_altitude: float) -> void:
	var p := profile

	# How much sun is actually reaching the ground. Cloud and dust each hold
	# some of it back, and they do not stack -- whichever blocks more wins.
	var solar := clampf(smoothstep(-0.12, 0.35, sun_altitude), 0.0, 1.0)
	var blocked := maxf(cloud_cover * p.cloud_sun_block, dust_haze * p.dust_sun_block)
	var drive := solar * (1.0 - blocked)

	# Tonight's floor. Rolled per night, and switched over at solar noon rather
	# than at midnight -- midnight sits in the middle of the fall, where a jump
	# in the target would be visible on the readout.
	var night_floor := _night_floor(days_elapsed)
	# A closed sky traps the day's heat. An overcast night is survivable in a
	# way a clear one is not.
	#
	# Keyed off the low deck alone, not off total cover: thin high cirrus traps
	# almost nothing, and since the desert always carries a few percent of it,
	# billing that as insulation was quietly lifting every clear night's floor
	# and pushing the coldest hour out of the -24..-18 band it is meant to hit.
	night_floor += deck_cover * p.cloud_night_insulation_c

	var target := lerpf(night_floor, p.temp_day_c, drive)
	if event != null:
		target += event.temp_offset_c * event_blend

	if _needs_seed:
		# First frame: start where the day already is instead of warming up
		# from whatever the variable happened to be initialised to.
		_needs_seed = false
		temperature_c = target

	# Exponential approach, with separate rates up and down. The asymmetry is
	# the whole trick: heating is quick enough that a clear day genuinely
	# reaches 40 C, cooling is slow enough that the fall takes the entire night
	# and bottoms out only when the sun comes back -- which puts the coldest
	# moment just before sunrise, where it belongs.
	var rate := p.heat_response_per_hour if target > temperature_c \
		else p.cool_response_per_hour
	temperature_c = lerpf(temperature_c, target, 1.0 - exp(-rate * dt_hours))


## The coldest this night gets, rolled once per night from the world seed so
## every client agrees without replicating it.
func _night_floor(days_elapsed: float) -> float:
	var key := _night_key(days_elapsed)
	var r := _hash01(key, 17)
	return lerpf(profile.temp_night_low_c, profile.temp_night_high_c, r)


## Nights are indexed by the day they END on, and the index flips at solar
## noon. A night that starts on day 3 and ends at dawn on day 4 is night 4
## throughout, so the target never jumps part-way through the fall.
func _night_key(days_elapsed: float) -> int:
	var day := floori(days_elapsed)
	var tod := days_elapsed - float(day)
	return (day + 1) if tod >= 0.5 else day


## Stable 0..1 from a night index. Hashed off a string rather than packed into
## a Vector3i, whose components are int32 and would wrap on a randomised world
## seed. Every client derives the same nights from the same seed with nothing
## crossing the wire.
func _hash01(key: int, salt: int) -> float:
	var h := hash("%d:%d:%d:%s" % [_world_seed, key, salt, biome_id])
	return float(absi(h) % 1000003) / 1000003.0


func _step_humidity(days_elapsed: float) -> void:
	var p := profile

	# Humidity is not simulated separately -- it is read off the temperature.
	# Hot desert air holds nothing; as the ground cools overnight the same
	# water vapour becomes a larger fraction of what the air can carry, so
	# humidity climbs exactly as the temperature falls, peaking at dawn
	# alongside the cold.
	var floor_c := _night_floor(days_elapsed)
	var coldness := clampf(inverse_lerp(p.temp_day_c, floor_c, temperature_c), 0.0, 1.0)

	var cold_peak := lerpf(p.humidity_cold_low, p.humidity_cold_high,
		_hash01(_night_key(days_elapsed), 29))
	humidity = lerpf(p.humidity_hot, cold_peak, pow(coldness, p.humidity_curve))

	if event != null:
		humidity += event.humidity_bonus * event_blend
	humidity = clampf(humidity, 0.0, 1.0)


func _step_felt(sun_altitude: float, sun_exposure: float, wind_exposure: float) -> void:
	var p := profile

	# --- the sun on your back --------------------------------------------
	# Standing unshaded in desert sun is nothing like standing in the same air
	# in shade. Blocked by cloud and dust for the same reason the ground is,
	# and by anything the player is standing under.
	# The LIGHT block, not the heating one: this is the sun landing on the
	# player's skin, and it is gone the moment the sky closes over -- whatever
	# the air around them is still doing.
	var solar := clampf(smoothstep(-0.12, 0.35, sun_altitude), 0.0, 1.0)
	var blocked := maxf(cloud_cover * p.cloud_light_block, dust_haze * p.dust_light_block)
	var radiant := p.sun_radiant_c * solar * (1.0 - blocked) * clampf(sun_exposure, 0.0, 1.0)

	# --- the wind taking it away -----------------------------------------
	# The coefficient itself slides with how cold the air already is, so wind
	# barely touches a hot afternoon but guts a cold night. The drop scales
	# with sqrt(wind), not wind -- chill has strongly diminishing returns, the
	# same shape as a real wind-chill chart.
	var floor_c := lerpf(p.temp_night_low_c, p.temp_night_high_c, 0.5)
	var coldness := clampf(inverse_lerp(p.temp_day_c, floor_c, temperature_c), 0.0, 1.0)
	var per_ms := lerpf(p.wind_chill_hot, p.wind_chill_cold, coldness)
	var wind_ms := wind_speed_kmh / 3.6
	var chill := per_ms * sqrt(maxf(wind_ms, 0.0)) * clampf(wind_exposure, 0.0, 1.0)

	felt_temperature_c = temperature_c + radiant - chill
