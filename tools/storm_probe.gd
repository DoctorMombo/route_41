extends SceneTree

## Headless-ish smoke test for the code paths that only run during a storm:
## bolt mesh construction, the flash light, thunder players, the dust veil and
## the fog/sky pushes. Nothing waits 12 hours for a natural event, so this
## loads the world, forces one, and runs long enough for lightning to fire.
##
##   godot --path <project> --windowed --resolution 480x270 \
##         --script res://tools/storm_probe.gd

const EVENT := &"dust"
## In-game hours per real second. Fast enough that the onset lands in a couple
## of seconds, slow enough that the strike schedule -- which is in REAL
## seconds -- still gets to fire several times before the storm blows out.
const TIME_SCALE := 20.0
const RUN_FRAMES := 1500

var _frames := 0
var _peak_dust := 0.0
var _peak_flash := 0.0
var _bolts_seen := 0
var _weather: WeatherSystem
var _lightning: LightningDirector


func _initialize() -> void:
	var world: Node = load("res://scenes/World.tscn").instantiate()
	root.add_child(world)


func _process(_delta: float) -> bool:
	_frames += 1

	if _frames == 20:
		_weather = get_first_node_in_group("weather") as WeatherSystem
		_lightning = root.find_child("LightningDirector", true, false) as LightningDirector
		var dn := get_first_node_in_group("day_night") as DayNightCycle
		if _weather == null or dn == null:
			print("PROBE FAIL: weather or day_night missing")
			return true
		dn.time_scale = TIME_SCALE
		# Midday, so the dust has bright sky to occlude and the fog colour and
		# sun-blocking paths are both exercised.
		dn.set_time(dn.get_day_index(), 0.5)
		_weather.trigger_event(EVENT)
		print("triggered %s; lightning node: %s"
			% [EVENT, "found" if _lightning else "MISSING"])

	if _weather:
		var s := _weather.get_state()
		_peak_dust = maxf(_peak_dust, s.dust_haze)
		_peak_flash = maxf(_peak_flash, _weather.flash_energy)
		if _lightning:
			_bolts_seen = maxi(_bolts_seen, _lightning.get_child_count())

	if _frames >= RUN_FRAMES:
		var s := _weather.get_state()
		print("--- storm probe ---")
		print("  condition       %s (%s)" % [s.condition_name(), s.phase_name()])
		print("  peak dust haze  %.0f%%" % [_peak_dust * 100.0])
		print("  peak flash      %.2f" % _peak_flash)
		print("  most children on LightningDirector at once: %d" % _bolts_seen)
		print("  wind            %.1f km/h" % s.wind_speed_kmh)
		print("  temp / felt     %.1f / %.1f C" % [s.temperature_c, s.felt_temperature_c])
		print("  sun exposure    %.2f" % _weather.sun_exposure)
		return true
	return false
