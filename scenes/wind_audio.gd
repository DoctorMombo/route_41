class_name WindAudio
extends Node

## Wind ambience for ROUTE 41.
##
## Two independent controls, deliberately separated:
##   1. Crossfade decides WHICH loop is heard -- the timbre of the wind.
##   2. A loudness curve decides HOW LOUD the result is.
##
## Folding those together is the obvious mistake: a pure crossfade normalises,
## so a breeze and a gale come out at the same level with only their character
## differing. Silence below a threshold, a whisper through the middle, a roar
## at the top is a property of (2), not (1).
##
## Both streams play continuously from startup and are only ever faded.
## Starting and stopping them would click, and a restarting loop is extremely
## audible on broadband noise -- the ear locks onto the repeat immediately.

## Left empty, found via the "weather" group.
@export var weather: WeatherSystem

@export_group("Loudness")
## Below this wind speed (m/s) there is no wind sound at all.
@export var silent_below: float = 1.5
## Wind speed (m/s) at which the wind is at full roar.
@export var full_at: float = 24.0
## Level at the quietest audible wind. This is the whisper.
@export_range(-60.0, 0.0) var quiet_db: float = -28.0
## Level at full gale. This is the roar.
@export_range(-24.0, 12.0) var loud_db: float = 0.0
## Above 1.0 holds the quiet end down longer before the climb; below 1.0 makes
## light winds louder sooner.
@export_range(0.3, 3.0) var speed_curve: float = 1.3
## Overall trim on top of everything.
@export_range(-40.0, 24.0) var master_gain_db: float = 0.0

@export_group("Layer Trim")
## Per-layer correction, for when one recording sits hotter than the others.
@export_range(-24.0, 12.0) var light_trim_db: float = 0.0
@export_range(-24.0, 12.0) var heavy_trim_db: float = 0.0

@export_group("Response")
## Seconds for a level change to land. Gusts should be felt, not chattered --
## the weather gust noise moves far faster than a mix should follow.
@export var slew_seconds: float = 0.8
## Pitch rise across the wind range. Adds urgency without another recording.
@export_range(0.0, 0.4) var pitch_range: float = 0.12

@onready var _light: AudioStreamPlayer = $Light
@onready var _heavy: AudioStreamPlayer = $Heavy

var _l := 0.0
var _h := 0.0


func _ready() -> void:
	if weather == null:
		weather = get_tree().get_first_node_in_group("weather") as WeatherSystem
	if weather == null:
		push_warning("WindAudio: no WeatherSystem in group 'weather'. Wind muted.")
		set_process(false)
		return

	for p: AudioStreamPlayer in [_light, _heavy]:
		if p.stream == null:
			push_warning("WindAudio: %s has no stream assigned." % p.name)
			continue
		p.volume_db = -80.0
		p.play()


func _process(delta: float) -> void:
	var w := weather.wind_speed

	# --- 1. which loop -----------------------------------------------------
	# Light carries the calm end, heavy takes over as the wind builds.
	var t_light := _band(w, 1.2, 4.5, 9.0, 16.0)
	var t_heavy := _band(w, 6.0, 14.0, 1e6, 1e6)

	var k := clampf(delta / maxf(slew_seconds, 0.01), 0.0, 1.0)
	_l = lerpf(_l, t_light, k)
	_h = lerpf(_h, t_heavy, k)

	# --- 2. how loud -------------------------------------------------------
	# Hard gate first, so still air is genuinely silent rather than merely
	# quiet, then a curve from whisper to roar across the usable range.
	var gate := smoothstep(silent_below * 0.6, silent_below, w)
	var t := clampf(inverse_lerp(silent_below, full_at, w), 0.0, 1.0)
	var speed_db := lerpf(quiet_db, loud_db, pow(t, speed_curve))

	_apply(_light, _l * gate, light_trim_db + speed_db)
	_apply(_heavy, _h * gate, heavy_trim_db + speed_db)

	var pitch := 1.0 + pitch_range * clampf(w / 25.0, 0.0, 1.0)
	_light.pitch_scale = pitch
	_heavy.pitch_scale = pitch


## 0 below `a`, rising to 1 by `b`, holding to `c`, back to 0 by `d`.
func _band(x: float, a: float, b: float, c: float, d: float) -> float:
	return smoothstep(a, b, x) * (1.0 - smoothstep(c, d, x))


func _apply(p: AudioStreamPlayer, level: float, offset_db: float) -> void:
	if p.stream == null:
		return
	if level < 0.002:
		p.volume_db = -80.0
		return
	# sqrt() gives an equal-power crossfade. These are three uncorrelated
	# recordings, so a linear fade would dip in loudness through the middle of
	# every transition between them.
	p.volume_db = linear_to_db(sqrt(level)) + offset_db + master_gain_db
