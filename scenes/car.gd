class_name Car
extends VehicleBody3D

## Drivable test vehicle. Driving input reuses the player's move_* actions --
## only one of Player/Car ever has control at a time, so there's no conflict.
## Entered/exited through the DriverSeat Area3D (see driver_seat.gd), which
## forwards into interact() below.
##
## Propulsion is a direct forward force (F = mass * acceleration) rather than
## VehicleWheel3D's engine_force. engine_force's actual accel curve depends on
## Jolt's wheel-slip model in ways that don't map predictably to a "reach
## max speed in N seconds" target; a plain F=ma push does, and traction loss
## on sand is easy to express as a multiplier on that force. VehicleWheel3D
## is still doing real work here -- suspension, steering, rolling, braking --
## just not driving the wheels.

## Rate the steering angle ramps toward the input target, radians/sec of
## `steering` value. Slower than it looks like it should be on purpose --
## this is standing in for the time it takes to physically crank a wheel
## over, not an instant snap to lock.
@export var steer_speed: float = 0.7
@export var steer_limit: float = 0.5
@export var brake_force: float = 4.0
@export var max_speed_kmh: float = 140.0
@export var reverse_speed_kmh: float = 25.0
@export var mouse_sensitivity: float = 0.0025
@export var camera_yaw_limit: float = 1.2   ## cockpit head-turn range, radians
@export var camera_pitch_limit: float = 0.7

## Tuned via a throwaway headless physics harness so full throttle in a
## straight line on paved road reaches max_speed_kmh in about 5 seconds.
@export var forward_acceleration: float = 9.5   ## m/s^2
@export var reverse_acceleration: float = 3.0    ## m/s^2

## Wheel grip by surface. Paved road holds; sand lets the tyres slip, so
## acceleration and steering both go soft off-road.
@export var road_friction_slip: float = 5.0
@export var sand_friction_slip: float = 0.8
@export var sand_traction_factor: float = 0.35   ## propulsion force multiplier off-road

## Engine pitch/volume interpolate between these two points as speed goes
## from 0 to max_speed_kmh, standing in for idle-to-redline revs.
@export var engine_min_pitch: float = 0.75
@export var engine_max_pitch: float = 2.2
@export var engine_min_volume_db: float = -10.0
@export var engine_max_volume_db: float = 2.0

## Below this forward speed, holding "brake" reverses instead of braking.
const REVERSE_THRESHOLD_MPS := 1.0

## Cabin sound isolation: the "Outside" bus carries ambience + engine, and
## "Inside" is reserved for cabin sfx we don't have yet (see
## default_bus_layout.tres). Both start in the "player is outside" state;
## entering/exiting swaps which one is muffled.
const OUTSIDE_BUS := &"Outside"
const INSIDE_BUS := &"Inside"
const NORMAL_CUTOFF_HZ := 20500.0   ## effectively unfiltered -- above hearing range
const MUFFLED_CUTOFF_HZ := 600.0
const NORMAL_VOLUME_DB := 0.0
const MUFFLED_VOLUME_DB := -14.0

@onready var driver_camera: Camera3D = $DriverCamera
@onready var exit_point: Marker3D = $ExitPoint
@onready var parking_brake_label: RichTextLabel = $Hud/ParkingBrakeLabel
@onready var engine_audio: AudioStreamPlayer3D = $EngineAudio
@onready var _wheels: Array[VehicleWheel3D] = [$wheel_fl, $wheel_fr, $wheel_rl, $wheel_rr]

var _driver: CharacterBody3D = null
var _cam_yaw: float = 0.0
var _cam_pitch: float = 0.0
var _chunk_manager: ChunkManager
var _traction_factor: float = 1.0

## Keeps the car from rolling away on its own. On by default, same as a real
## handbrake -- the player has to release it before driving off.
var parking_brake_engaged: bool = true


func _ready() -> void:
	_chunk_manager = get_tree().get_first_node_in_group("chunk_manager")
	_update_parking_brake_label()

	engine_audio.stream = load("res://assets/vehicles/doge/engine.wav")
	# AudioStreamWAV's own loop metadata isn't reliable across arbitrary
	# source files; replaying on "finished" loops it regardless.
	engine_audio.finished.connect(engine_audio.play)


func get_interact_prompt() -> String:
	return "Press Enter to drive" if _driver == null else ""


## Toggles between entering and exiting depending on current state, so the
## same "interact" key works for both.
func interact(player: CharacterBody3D) -> void:
	if _driver == null:
		_enter(player)
	else:
		_exit()


func _enter(player: CharacterBody3D) -> void:
	_driver = player
	player.set_driving(true)
	_cam_yaw = 0.0
	_cam_pitch = 0.0
	driver_camera.rotation = Vector3.ZERO
	driver_camera.current = true
	parking_brake_label.visible = true
	engine_audio.play()
	# Player is now inside: outside sounds go dull; cabin sounds (none yet)
	# would come in clear.
	_set_bus_muffled(OUTSIDE_BUS, true)
	_set_bus_muffled(INSIDE_BUS, false)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _exit() -> void:
	var player := _driver
	_driver = null
	# Never leave the car free-rolling once the player walks away.
	parking_brake_engaged = true
	_update_parking_brake_label()
	parking_brake_label.visible = false
	engine_audio.stop()
	_set_bus_muffled(OUTSIDE_BUS, false)
	_set_bus_muffled(INSIDE_BUS, true)
	player.global_position = exit_point.global_position
	player.set_driving(false)


func _unhandled_input(event: InputEvent) -> void:
	if _driver == null:
		return
	if event.is_action_pressed("interact"):
		_exit()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("parking_brake"):
		parking_brake_engaged = not parking_brake_engaged
		_update_parking_brake_label()
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_cam_yaw = clampf(_cam_yaw - event.relative.x * mouse_sensitivity,
			-camera_yaw_limit, camera_yaw_limit)
		_cam_pitch = clampf(_cam_pitch - event.relative.y * mouse_sensitivity,
			-camera_pitch_limit, camera_pitch_limit)
		driver_camera.rotation.y = _cam_yaw
		driver_camera.rotation.x = _cam_pitch


## Muffles (dulls + quiets) everything on the given bus, or restores it to
## normal. Reaches into AudioServer directly rather than through a node --
## buses aren't scene-tree objects, and this only ever needs to run twice
## (on enter, on exit), so a stored reference would just be more state to
## keep in sync for no benefit.
func _set_bus_muffled(bus_name: StringName, muffled: bool) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	var filter := AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter
	if filter:
		filter.cutoff_hz = MUFFLED_CUTOFF_HZ if muffled else NORMAL_CUTOFF_HZ
	AudioServer.set_bus_volume_db(idx, MUFFLED_VOLUME_DB if muffled else NORMAL_VOLUME_DB)


func _update_parking_brake_label() -> void:
	var state_bbcode := "[color=green]Y[/color]" if parking_brake_engaged else "[color=red]N[/color]"
	parking_brake_label.text = "P - Parking Brake: %s" % state_bbcode


func _physics_process(delta: float) -> void:
	var horizontal_speed := Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()

	# Speed-proportional downforce keeps the car planted at higher speeds
	# instead of getting light and skittish over bumps. Horizontal speed
	# only -- using the full 3D vector meant a bump's vertical velocity
	# added extra downforce, which fed right back into more bounce.
	apply_central_force(Vector3.DOWN * horizontal_speed)
	_update_wheel_traction()
	engine_force = 0.0   ## propulsion is applied manually below

	if _driver != null:
		# ChunkManager streams terrain around the player node; keep it
		# glued to the car so the road ahead keeps loading while driving.
		_driver.global_position = global_position
		_update_engine_audio()

	if _driver == null or parking_brake_engaged:
		brake = 1.0
		steering = move_toward(steering, 0.0, steer_speed * delta)
		_clamp_speed()
		return

	var forward := -global_transform.basis.z
	var forward_speed := linear_velocity.dot(forward)
	var max_mps := max_speed_kmh / 3.6

	if Input.is_action_pressed("move_forward"):
		# Stop pushing once at the cap. Continuing to apply full force here
		# and then clamping it off below was fighting itself every physics
		# frame at top speed -- that fight is what was reading as bouncing.
		if forward_speed < max_mps:
			apply_central_force(forward * mass * forward_acceleration * _traction_factor)
		brake = 0.0
	elif Input.is_action_pressed("move_back"):
		if forward_speed > REVERSE_THRESHOLD_MPS:
			# Still rolling forward: this is a brake press, not reverse.
			brake = brake_force
		else:
			apply_central_force(-forward * mass * reverse_acceleration * _traction_factor)
			brake = 0.0
	else:
		brake = 0.0

	var steer_target := (Input.get_action_strength("move_left") - Input.get_action_strength("move_right")) * steer_limit
	steering = move_toward(steering, steer_target, steer_speed * delta)

	_clamp_speed()


## Caps horizontal (road-plane) speed only. Clamping the full 3D vector
## would bleed vertical suspension movement into the speed cap and back --
## the other half of the bounce-at-top-speed feedback loop.
func _clamp_speed() -> void:
	var forward_speed := linear_velocity.dot(-global_transform.basis.z)
	var cap_kmh := max_speed_kmh if forward_speed >= 0.0 else reverse_speed_kmh
	var cap_mps := cap_kmh / 3.6
	var horizontal := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	if horizontal.length() > cap_mps:
		var clamped := horizontal.normalized() * cap_mps
		linear_velocity.x = clamped.x
		linear_velocity.z = clamped.z


## Revs with road speed rather than throttle/RPM -- no gearbox model here,
## just enough to make accelerating and slowing down audible.
func _update_engine_audio() -> void:
	var speed_ratio := clampf(linear_velocity.length() / (max_speed_kmh / 3.6), 0.0, 1.0)
	engine_audio.pitch_scale = lerpf(engine_min_pitch, engine_max_pitch, speed_ratio)
	engine_audio.volume_db = lerpf(engine_min_volume_db, engine_max_volume_db, speed_ratio)


## Grippy on paved road, slippery on sand/gravel. Falls back to full road
## grip when there's no terrain to sample yet (e.g. the tuning harness).
func _update_wheel_traction() -> void:
	if _chunk_manager == null or _chunk_manager.gen == null:
		_traction_factor = 1.0
		return
	var gen := _chunk_manager.gen
	for wheel in _wheels:
		var on_road := gen.is_paved_road(wheel.global_position.x, wheel.global_position.z)
		wheel.wheel_friction_slip = road_friction_slip if on_road else sand_friction_slip
	# Drive wheels are the front pair (wheel_fl, wheel_fr) -- see use_as_traction
	# in Car.tscn -- so traction for propulsion follows their surface.
	var drive_on_road := gen.is_paved_road(_wheels[0].global_position.x, _wheels[0].global_position.z)
	_traction_factor = 1.0 if drive_on_road else sand_traction_factor
