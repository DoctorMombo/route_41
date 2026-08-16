class_name LightningDirector
extends Node3D

## Lightning for ROUTE 41.
##
## Two separate things, deliberately, because they read completely differently:
##
##   1. In-cloud flashes. No bolt is drawn at all -- the cloud deck lights up
##      from within (via the sky shader) and the world gets a brief wash of
##      light. This is most of the lightning you ever see in a storm.
##   2. Ground strikes. An actual bolt, drawn as a camera-facing ribbon, with
##      a bright point light at the impact and thunder that arrives late.
##
## Both schedules come from the running weather event, so this node has no
## opinion about when lightning happens -- a dust storm asking for a strike
## every 3 to 7 seconds and a thunderstorm asking for one every 15 to 45 get
## the same code path.
##
## Nothing here needs wiring in the scene: it finds the weather through its
## group and builds its own light and meshes.

## Left empty, found via the "weather" group.
@export var weather: WeatherSystem
## Left empty, found via the "chunk_manager" group. Used to put the foot of a
## bolt on the ground rather than in the air.
@export var chunk_manager: ChunkManager

@export_group("Flash")
## Peak sky-shader flash energy for an in-cloud flash.
@export var flash_energy: float = 3.2
## Seconds for a single stroke to decay. Short -- lightning is not a fade.
@export var flash_decay: float = 0.12
## Strokes per flash. Real lightning flickers; a single clean pulse reads as a
## light being switched on and off.
@export var flash_strokes := Vector2i(2, 5)
## Energy of the world-space light that accompanies a flash.
@export var flash_light_energy: float = 2.4

@export_group("Ground Strike")
## Metres from the camera a bolt can land.
@export var strike_distance := Vector2(70.0, 420.0)
## Metres above the ground the bolt comes out of the cloud.
@export var cloud_base_height: float = 340.0
## Metres wide the main channel is drawn. Bolts are thin, but a sub-metre
## ribbon at 300 m is a single dithered pixel.
@export var bolt_width: float = 1.6
## Seconds the drawn bolt and its light last.
@export var bolt_life: float = 0.30
## Energy of the point light at the foot of the bolt.
@export var strike_light_energy: float = 60.0
@export var strike_light_range: float = 320.0
@export var bolt_color: Color = Color(0.86, 0.92, 1.0)

@export_group("Thunder")
## Cracks heard when a bolt lands close. Left empty, filled from NEAR_CLIPS.
@export var thunder_near: Array[AudioStream] = []
## Rolling booms for distant strikes and in-cloud flashes. Left empty, filled
## from FAR_CLIPS.
@export var thunder_far: Array[AudioStream] = []
## Metres per second sound travels. Real is 343; lower it to shorten the wait.
@export var sound_speed: float = 343.0
## Longest delay thunder will ever wait, in seconds.
@export var max_thunder_delay: float = 9.0
@export_range(-40.0, 12.0) var thunder_db: float = -2.0
## Random level spread between claps, in dB either way. Small: this is meant to
## stop them sounding stamped from the same die, not to make the mix wander.
@export_range(0.0, 8.0) var thunder_db_jitter: float = 2.5
## Random pitch spread. Kept narrow -- push it and thunder starts sounding like
## a sample being played back at the wrong speed, which it is.
@export var thunder_pitch := Vector2(0.92, 1.08)
## Metres past which air absorption has clearly dulled the high end. Distant
## thunder is a rumble largely because the crack never survives the journey.
@export var thunder_air_cutoff_hz: float = 3200.0

## Baked one-shots, in res://assets. Loaded by name rather than assigned in the
## Inspector so this node stays drop-in, same as the rest of the project. Any
## that fail to load are skipped, so removing a file is not a crash.
const NEAR_CLIPS := [
	"res://assets/thunder_near_01.ogg",
	"res://assets/thunder_near_02.ogg",
	"res://assets/thunder_near_03.ogg",
	"res://assets/thunder_near_04.ogg",
]
const FAR_CLIPS := [
	"res://assets/thunder_far_01.ogg",
	"res://assets/thunder_far_02.ogg",
	"res://assets/thunder_far_03.ogg",
]

var _rng := RandomNumberGenerator.new()
var _flash_light: DirectionalLight3D
## Live strokes: {"t": seconds since it fired, "gain": relative brightness}.
var _strokes: Array[Dictionary] = []
## Live bolts: {"mesh": MeshInstance3D, "light": OmniLight3D, "t": float}.
var _bolts: Array[Dictionary] = []
var _next_flash: float = 0.0
var _next_strike: float = 0.0
## Index of the clip each pool played last, so it is never played twice running.
var _last_near: int = -1
var _last_far: int = -1


func _ready() -> void:
	_rng.randomize()
	if weather == null:
		weather = get_tree().get_first_node_in_group("weather") as WeatherSystem
	if chunk_manager == null:
		chunk_manager = get_tree().get_first_node_in_group("chunk_manager") as ChunkManager
	if weather == null:
		push_warning("LightningDirector: no WeatherSystem in group 'weather'.")
		set_process(false)
		return

	if thunder_near.is_empty():
		thunder_near = _load_clips(NEAR_CLIPS)
	if thunder_far.is_empty():
		thunder_far = _load_clips(FAR_CLIPS)
	if thunder_near.is_empty() and thunder_far.is_empty():
		push_warning("LightningDirector: no thunder clips found in res://assets. "
			+ "Lightning will be silent.")

	# A directional light rather than an omni: a flash inside a cloud deck a
	# kilometre up illuminates the whole landscape evenly, not a bubble around
	# the player. No shadows -- the cost is real and nobody reads shadow
	# direction during a 0.1 second flash.
	_flash_light = DirectionalLight3D.new()
	_flash_light.light_energy = 0.0
	_flash_light.light_color = bolt_color
	_flash_light.shadow_enabled = false
	_flash_light.visible = false
	add_child(_flash_light)


func _process(delta: float) -> void:
	var state := weather.get_state()
	_advance_schedules(delta, state)
	_advance_flash(delta)
	_advance_bolts(delta)


# --- scheduling -------------------------------------------------------------

func _advance_schedules(delta: float, state: BiomeWeatherState) -> void:
	var flash_period := state.cloud_flash_period()
	if flash_period == Vector2.ZERO:
		_next_flash = 0.0
	else:
		_next_flash -= delta
		if _next_flash <= 0.0:
			_next_flash = _rng.randf_range(flash_period.x, flash_period.y)
			_fire_flash(state)

	var strike_period := state.ground_strike_period()
	if strike_period == Vector2.ZERO:
		_next_strike = 0.0
	else:
		_next_strike -= delta
		if _next_strike <= 0.0:
			_next_strike = _rng.randf_range(strike_period.x, strike_period.y)
			_fire_ground_strike(state)


# --- in-cloud flash ---------------------------------------------------------

func _fire_flash(state: BiomeWeatherState) -> void:
	# Somewhere up in the deck, and never straight overhead -- a flash on the
	# horizon behind cloud is the shot that sells a storm.
	var azimuth := _rng.randf() * TAU
	var elevation := _rng.randf_range(0.08, 0.55)
	weather.flash_direction = Vector3(
		cos(azimuth) * (1.0 - elevation), elevation, sin(azimuth) * (1.0 - elevation)
	).normalized()

	# A flash is several strokes down the same channel, milliseconds apart.
	var count := _rng.randi_range(flash_strokes.x, flash_strokes.y)
	var offset := 0.0
	for _stroke in count:
		_strokes.append({
			"t": -offset,
			"gain": _rng.randf_range(0.45, 1.0) * maxf(state.event_blend, 0.2),
		})
		offset += _rng.randf_range(0.03, 0.11)

	# Placed out along the flash direction rather than at this node's origin,
	# so the rumble comes from where the flash was and its delay matches the
	# distance -- otherwise thunder would drift as the player walked away from
	# world zero.
	var cam := get_viewport().get_camera_3d()
	var eye := cam.global_position if cam else global_position
	var far := _rng.randf_range(600.0, 2400.0)
	_play_thunder(eye + weather.flash_direction * far, far, false)


func _advance_flash(delta: float) -> void:
	var total := 0.0
	var i := _strokes.size() - 1
	while i >= 0:
		var s := _strokes[i]
		s["t"] = float(s["t"]) + delta
		var t: float = s["t"]
		if t > flash_decay * 6.0:
			_strokes.remove_at(i)
		elif t >= 0.0:
			total += float(s["gain"]) * exp(-t / maxf(flash_decay, 0.001))
		i -= 1

	weather.flash_energy = total * flash_energy
	if _flash_light:
		_flash_light.light_energy = total * flash_light_energy
		_flash_light.visible = _flash_light.light_energy > 0.01
		if _flash_light.visible:
			# Light arrives from the flash, so the light points away from it.
			# Built by hand rather than with look_at(), which fails outright
			# when the flash is directly overhead.
			var z := weather.flash_direction.normalized()
			var up := Vector3.UP if absf(z.y) < 0.999 else Vector3.FORWARD
			var x := up.cross(z).normalized()
			_flash_light.global_transform = Transform3D(
				Basis(x, z.cross(x), z), Vector3.ZERO)


# --- ground strike ----------------------------------------------------------

func _fire_ground_strike(state: BiomeWeatherState) -> void:
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position

	var azimuth := _rng.randf() * TAU
	var distance := _rng.randf_range(strike_distance.x, strike_distance.y)
	var foot := eye + Vector3(cos(azimuth), 0.0, sin(azimuth)) * distance
	foot.y = _ground_height(foot.x, foot.z)

	# The channel leaves the cloud somewhere near, but not directly above, the
	# point it lands on -- a perfectly vertical bolt looks like a pillar.
	var top := foot + Vector3(
		_rng.randf_range(-70.0, 70.0), cloud_base_height, _rng.randf_range(-70.0, 70.0))

	var mesh := _build_bolt(top, foot, eye)
	add_child(mesh)
	mesh.top_level = true
	mesh.global_transform = Transform3D.IDENTITY

	var light := OmniLight3D.new()
	add_child(light)
	light.top_level = true
	light.global_position = foot + Vector3.UP * 6.0
	light.light_color = bolt_color
	light.light_energy = strike_light_energy
	light.omni_range = strike_light_range
	light.shadow_enabled = false

	_bolts.append({"mesh": mesh, "light": light, "t": 0.0})

	# A ground strike also lights the cloud deck it came out of.
	_strokes.append({"t": 0.0, "gain": _rng.randf_range(0.8, 1.4)})
	weather.flash_direction = (top - eye).normalized()

	_play_thunder(foot, distance, distance < 160.0)
	if state.dust_storm_intensity > 0.0:
		# Inside a dust storm the bolt itself is invisible through the haze --
		# what you get is the haze lighting up. Kill the geometry so it does
		# not punch through the fog as a clean white line.
		mesh.visible = state.dust_haze < 0.6


func _advance_bolts(delta: float) -> void:
	var i := _bolts.size() - 1
	while i >= 0:
		var b := _bolts[i]
		b["t"] = float(b["t"]) + delta
		var t: float = b["t"]
		var k := clampf(1.0 - t / maxf(bolt_life, 0.001), 0.0, 1.0)
		if k <= 0.0:
			(b["mesh"] as Node).queue_free()
			(b["light"] as Node).queue_free()
			_bolts.remove_at(i)
		else:
			# Flicker on the way out rather than fading smoothly.
			var flicker := k * (0.55 + 0.45 * absf(sin(t * 90.0)))
			var mi := b["mesh"] as MeshInstance3D
			if mi.material_override is StandardMaterial3D:
				var m := mi.material_override as StandardMaterial3D
				m.albedo_color = Color(bolt_color.r, bolt_color.g, bolt_color.b, 1.0) * flicker
			(b["light"] as OmniLight3D).light_energy = strike_light_energy * flicker
		i -= 1


## The bolt as a camera-facing ribbon. Godot draws every 3D line one pixel
## wide regardless of distance, so a LINE_STRIP would vanish at 400 m -- this
## builds actual triangles whose width is in metres.
func _build_bolt(top: Vector3, foot: Vector3, eye: Vector3) -> MeshInstance3D:
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = bolt_color
	mat.disable_receive_shadows = true

	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	var spine := _jagged_path(top, foot, 18, 16.0)
	_ribbon(mesh, spine, eye, bolt_width)

	# One or two forks that die in mid-air. Every real bolt has them and they
	# are most of what makes the silhouette read as lightning.
	for _fork in _rng.randi_range(1, 3):
		var i := _rng.randi_range(2, spine.size() - 4)
		var start: Vector3 = spine[i]
		var away := Vector3(_rng.randfn(0.0, 1.0), -1.6, _rng.randfn(0.0, 1.0)).normalized()
		var end := start + away * _rng.randf_range(25.0, 90.0)
		end.y = maxf(end.y, foot.y + 4.0)
		_ribbon(mesh, _jagged_path(start, end, 6, 7.0), eye, bolt_width * 0.5)
	mesh.surface_end()

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The bolt is built in world coordinates and lives for a third of a second;
	# there is no point letting the engine cull it against a stale AABB.
	mi.extra_cull_margin = 16384.0
	return mi


## A straight run broken into segments that wander off the line, most in the
## middle and least at the two ends, which are pinned.
func _jagged_path(from: Vector3, to: Vector3, segments: int, spread: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for i in segments + 1:
		var t := float(i) / float(segments)
		var p := from.lerp(to, t)
		if i > 0 and i < segments:
			var taper := 1.0 - absf(t * 2.0 - 1.0)
			p += Vector3(_rng.randfn(0.0, 1.0), 0.0, _rng.randfn(0.0, 1.0)) * spread * taper
		pts.append(p)
	return pts


## Expand a polyline into quads that face the eye. The facing is computed once,
## at spawn -- the bolt is gone in a third of a second, long before the player
## could walk far enough for a fixed facing to be wrong.
func _ribbon(mesh: ImmediateMesh, pts: PackedVector3Array, eye: Vector3, width: float) -> void:
	var half := width * 0.5
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var seg := b - a
		if seg.length_squared() < 1e-6:
			continue
		var to_eye := eye - (a + b) * 0.5
		var side := seg.normalized().cross(to_eye)
		if side.length_squared() < 1e-6:
			side = Vector3.RIGHT
		side = side.normalized() * half

		mesh.surface_add_vertex(a - side)
		mesh.surface_add_vertex(a + side)
		mesh.surface_add_vertex(b + side)
		mesh.surface_add_vertex(a - side)
		mesh.surface_add_vertex(b + side)
		mesh.surface_add_vertex(b - side)


func _ground_height(x: float, z: float) -> float:
	if chunk_manager and chunk_manager.gen:
		return chunk_manager.gen.get_height(x, z)
	return 0.0


# --- thunder ----------------------------------------------------------------

func _load_clips(paths: Array) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	for path: String in paths:
		if not ResourceLoader.exists(path):
			continue
		var s := load(path) as AudioStream
		if s:
			out.append(s)
	return out


## An index into `pool` that is never the one played last.
##
## Straight random is the wrong tool here. With four clips it repeats a quarter
## of the time, and a thunderclap repeating back to back is the single loudest
## tell that a game is playing samples at you. Drawing from the other n-1 and
## shifting past the last one keeps the choice uniform while making an
## immediate repeat impossible.
func _pick(pool: Array[AudioStream], last: int) -> int:
	if pool.is_empty():
		return -1
	if pool.size() == 1:
		return 0
	var i := _rng.randi_range(0, pool.size() - 2)
	if i >= last:
		i += 1
	return i


## Thunder arrives late, by distance over the speed of sound. That delay is the
## single cue that tells a player how far away the strike was, so it is worth
## the wait even though it means the sound is decoupled from the flash.
func _play_thunder(at: Vector3, distance: float, near: bool) -> void:
	var pool := thunder_near if near else thunder_far
	var index := _pick(pool, _last_near if near else _last_far)
	if index < 0:
		return
	if near:
		_last_near = index
	else:
		_last_far = index

	var delay := minf(distance / maxf(sound_speed, 1.0), max_thunder_delay)

	var p := AudioStreamPlayer3D.new()
	add_child(p)
	p.top_level = true
	p.global_position = at
	p.stream = pool[index]
	# Level and pitch jitter on top of the clip choice. Three or four
	# recordings is not many; varying each playing is what stretches them far
	# enough that a dust storm firing every three seconds does not sound like
	# a loop.
	p.volume_db = thunder_db + _rng.randf_range(-thunder_db_jitter, thunder_db_jitter)
	p.pitch_scale = _rng.randf_range(thunder_pitch.x, thunder_pitch.y)
	p.max_distance = 4000.0
	p.unit_size = 60.0
	# Air swallows the high end over distance, which is most of why far-off
	# thunder rumbles instead of cracking.
	p.attenuation_filter_cutoff_hz = thunder_air_cutoff_hz
	p.attenuation_filter_db = -24.0
	p.bus = &"Outside" if AudioServer.get_bus_index(&"Outside") >= 0 else &"Master"
	p.finished.connect(p.queue_free)

	await get_tree().create_timer(delay).timeout
	if is_instance_valid(p):
		p.play()
