class_name Car
extends VehicleBody3D

## Drivable vehicle for ROUTE 41.
##
## Driving input reuses the player's move_* actions -- only one of Player/Car
## ever has control at a time, so there is no conflict. Entered and left through
## the DriverSeat Area3D (see driver_seat.gd), which forwards into interact().
##
## Four things here are deliberately not the textbook VehicleBody3D approach.
## Each is worth reading before changing it:
##
## 1. Propulsion is a central force (F = mass * acceleration) rather than
##    VehicleWheel3D.engine_force. engine_force's accel curve depends on the
##    wheel-slip solver in ways that do not map to "reach top speed in N
##    seconds"; a plain F = ma does. Top speed then falls out of aerodynamic
##    drag rather than out of clamping linear_velocity. Nothing here writes the
##    velocity at all, which matters: a clamp overwrites what the solver just
##    produced, every physics frame, and the solver spends the next frame
##    putting it back.
##
## 2. Because nothing is driving the wheels, they cannot spin up on their own
##    either. Wheelspin on sand is therefore drawn rather than simulated; see
##    _update_wheelspin() for why that lands in exactly the right place.
##
## 3. VehicleBody3D.brake is an IMPULSE in newton-seconds, not a force, and it
##    is not scaled by the physics step. A brake of 4.0 on a 2.2 tonne car is
##    about 0.4 m/s^2 -- which is why the old handbrake did not hold. Every
##    brake figure here is written as a target deceleration and converted in
##    _brake_impulse(), so the numbers mean something and stay right if the
##    tick rate changes.
##
## 4. The parking brake parks by freezing the body once the car has settled.
##    Wheel brakes are friction, and friction lets a heavy car creep down a
##    grade over a few minutes -- creeping away from where the player left it is
##    the entire bug the parking brake exists to prevent.
##
## Audio: two sides of a pane of glass. The "Outside" bus carries the world --
## wind, thunder, this car's engine -- and "Inside" carries the cabin, which is
## a radio and not much else so far. Whichever side the player is NOT on gets
## muffled; see _update_isolation(). Adding a cabin sound is one
## AudioStreamPlayer on the "Inside" bus and nothing else. The only thing
## default_bus_layout.tres has to provide is an AudioEffectLowPassFilter at
## effect index 0 on each of the two buses -- that is the one written here, and
## the levels stored in the layout are just the state the game starts in.
##
## Climate: the cabin has its own air (see CabinClimate). A driver is indoors --
## no direct sun, no wind -- and what they feel is the cabin's temperature and
## humidity, not the biome's. WeatherSystem asks through the get_shelter_*
## methods at the bottom of this file.
##
##
## SUSPENSION, and why the figures in Car.tscn are what they are
## -------------------------------------------------------------
## They are derived rather than eyeballed, and this is where the derivation
## lives -- the editor rewrites Car.tscn whenever the scene is saved, and would
## drop a comment written in there.
##
## This is also where the bouncing came from, and the swerving after it: a car
## that cannot hold itself up on its springs corners on whatever its chassis is
## resting on.
##
## Godot multiplies BOTH the spring and the damper term by the chassis mass, so
## the static compression each wheel settles at is:
##
##     compression = g / (4 * suspension_stiffness)
##
## -- independent of mass, which is why the car's weight can change without
## touching the ride height. At stiffness 28 that is 9.8 / 112 = 0.0875 m, and
## it MUST fit comfortably inside wheel_rest_length. The old scene paired
## stiffness 22 with a rest length of 0.0998 m, which needs 0.111 m of travel:
## the springs could not hold the car up, so it sat on its bump stops and the
## chassis took every bump in the road directly. 0.0875 of 0.30 m is 29%
## compression at rest, about right for a road car.
##
## Critical damping in these same mass-scaled units is 2 * sqrt(stiffness) =
## 10.58, so damping_compression 4.4 is a ratio of 0.42 and damping_relaxation
## 5.4 is 0.51 -- a little stiffer in rebound than in bump, as on a real car.
## The old 0.6 / 0.9 were 6% and 9% of critical. That was the bouncing.
##
## Each wheel's Y in the scene then places the hardpoint so that AT that static
## compression the contact patch lands at local y = -0.03, which is the ride
## height the body model was built around. Both axles share one figure; the
## rear pair used to sit 0.056 m lower, which sank the back tyres into the road
## and stood the car nose-up.

@export_group("Drivetrain")
@export var max_speed_kmh: float = 155.0
@export var reverse_speed_kmh: float = 30.0
## Peak acceleration at full throttle on tarmac, m/s^2. Top speed is whatever
## this balances against drag, so the two are tuned together.
@export var forward_acceleration: float = 9.0
@export var reverse_acceleration: float = 3.5
## Target deceleration under the brake pedal, m/s^2. About 0.9 g, which is
## roughly what a road car on dry tarmac manages.
@export var brake_deceleration: float = 9.0
## The parking brake, same units. Far harder than the pedal -- it is not for
## stopping, it is for holding.
@export var parking_brake_deceleration: float = 20.0
## Coasting losses, m/s^2. Small and constant; drag does the rest.
@export var rolling_resistance: float = 0.35

@export_group("Handling")
## Steering lock at a standstill, and at top speed, in radians of road-wheel
## angle. Speed-sensitive steering is the single biggest reason the car no
## longer swerves: full lock at 150 km/h asks for about 9 g of lateral grip, so
## any input at all used to throw it sideways.
@export var steer_limit_parked: float = 0.55
@export var steer_limit_flat_out: float = 0.07
## Radians/sec the road wheels move toward the input, and back to centre, AT
## FULL LOCK. Scaled down with whatever lock is currently on offer, so winding
## on all of what is available takes about the same time at any speed.
##
## That scaling is the point. A flat rate in radians/sec is a lie at speed: at
## 150 km/h the entire available range is 0.07 rad, and a rate meant for parking
## manoeuvres crosses all of it in two physics frames -- which is a switch, not
## a steering wheel, however gentle it feels in the car park.
@export var steer_speed: float = 0.7
@export var steer_return_speed: float = 1.2
## Seconds of softening on the steering command. Takes the edge off the start
## of an input, which a pure rate limit cannot do -- a rate limit begins moving
## at full speed the instant the key goes down. Small on purpose: this is
## rounding the corner off, not adding lag.
@export var steer_smoothing: float = 0.12
## Downforce at top speed, in g. Keeps the car planted over crests instead of
## going light and skittish. Horizontal speed only -- feeding vertical velocity
## into downforce makes every bump generate more downforce, which was the other
## half of the old bounce.
@export var downforce_g: float = 0.45
## Roll and pitch rate damping, per second of body-axis angular velocity.
## Kills the wallow that a soft-sprung heavy car develops in corners without
## touching yaw, so steering response is unaffected.
@export var roll_damping: float = 1.1
@export var pitch_damping: float = 0.8

@export_group("Surfaces")
## Peak longitudinal acceleration each surface can transmit, m/s^2. Tarmac is
## above forward_acceleration, so the road never slips; sand is well below it,
## so sand always does. Everything about traction is derived from these two.
@export var road_grip_accel: float = 11.0
@export var sand_grip_accel: float = 3.0
## Wheel friction slip per surface, which is what the solver uses for cornering
## and braking grip.
@export var road_friction_slip: float = 4.5
@export var sand_friction_slip: float = 0.9
## How hard sideways velocity is scrubbed off, per second, on each surface.
## This is a grip assist, not physics: the wheel model alone lets a 2.2 tonne
## car fishtail on a straight road. On sand it is nearly absent, so the back
## end genuinely steps out.
@export var lateral_grip_road: float = 2.5
@export var lateral_grip_sand: float = 0.4

@export_group("Wheelspin")
## Ceiling on the drawn slip ratio. 1.5 means the tyres can turn at two and a
## half times road speed before it stops looking like more.
@export var wheelspin_max: float = 1.5
## Metres/sec of extra tyre surface speed per unit of slip ratio. This is what
## makes the wheels spin from a standstill, where road speed is zero and a pure
## ratio would draw nothing.
@export var wheelspin_reference_speed: float = 7.0

@export_group("Camera")
@export var mouse_sensitivity: float = 0.0025
@export var camera_yaw_limit: float = 1.2   ## cockpit head-turn range, radians
@export var camera_pitch_limit: float = 0.7

@export_group("Engine Audio")
## Engine pitch/volume interpolate between these as speed goes from 0 to
## max_speed_kmh, standing in for idle-to-redline revs.
@export var engine_min_pitch: float = 0.75
@export var engine_max_pitch: float = 2.2
@export var engine_min_volume_db: float = -10.0
@export var engine_max_volume_db: float = 2.0

@export_group("Cabin Isolation")
## What a muffled bus is rolled off to, and how much quieter it gets. Glass and
## a steel shell take the top end off long before they take the level down, so
## the cutoff does most of the work and the volume drop stays modest -- the
## world outside should sound dulled, not switched off.
@export var muffled_cutoff_hz: float = 1200.0
@export var muffled_volume_db: float = -8.0
## Seconds for the muffle to slide in or out. Instant is audible as a click.
@export var isolation_blend_seconds: float = 0.30

@export_group("Cabin Climate")
## Degrees above outside air the sealed cabin reaches in full sun.
@export var cabin_sun_gain_c: float = 22.0
## Road speed at which airflow through the cabin fully equalises it with the
## outside. Below this it is partly sealed and partly vented.
@export var cabin_vent_speed_kmh: float = 45.0

@export_group("Getting Out")
## Fastest the car can be going and still let the driver out, km/h.
##
## You cannot step out of a moving car, and the parking brake is exactly why it
## matters here: with the brake off there is nothing holding what you stepped
## out of, and rolling resistance alone is only 0.35 m/s^2 -- a car abandoned at
## 50 km/h coasts the better part of two hundred metres before it stops. Walking
## pace is slow enough that it rolls a couple of metres and settles.
@export var exit_speed_limit_kmh: float = 8.0
## Metres the player is set down above the ground when they get out.
@export var exit_clearance: float = 0.15
## Metres from the car's CENTRELINE the player is set down. The body is about
## 1.05 m half-width and the player is a 0.4 m capsule, so 1.5 m already clears
## it -- this is deliberately well past that, because the cost of being wrong is
## the car taking a penetration impulse and leaving. The ExitPoint marker in the
## scene picks which door and how far along the car; this fixes how far out.
@export var exit_side_offset: float = 2.8
## Metres ahead of and behind the car to try if both doors are blocked.
@export var exit_end_offset: float = 4.2
## Physics frames the car is held static while the player is set down beside it.
##
## Handing control back must not itself be an event the physics reacts to. A
## collider appearing beside a dynamic body can be read as a penetration, and
## the impulse that separates the two in a single step is enormous -- which is
## a car on the horizon. A static body takes no impulses at all, so across these
## few frames there is simply nothing there to launch; the car's velocity is put
## back exactly as it was on the way out.
@export var handover_frames: int = 4
## One-frame speed increase, in km/h, that a car with nobody in it is not
## allowed to have. See _guard_runaway().
@export var runaway_speed_jump_kmh: float = 25.0

## Below this forward speed, holding "brake" reverses instead of braking.
const REVERSE_THRESHOLD_MPS := 1.0
## Seconds a cockpit hint stays up.
const HINT_SECONDS := 2.0
## Speed and settle time under which the parking brake commits to freezing.
const PARK_SPEED_MPS := 0.25
const PARK_SPIN_RADS := 0.25
const PARK_SETTLE_SECONDS := 0.35

const OUTSIDE_BUS := &"Outside"
const INSIDE_BUS := &"Inside"
## Effectively unfiltered -- above hearing range.
const OPEN_CUTOFF_HZ := 20500.0

@onready var driver_camera: Camera3D = $DriverCamera
@onready var exit_point: Marker3D = $ExitPoint
@onready var parking_brake_label: RichTextLabel = $Hud/ParkingBrakeLabel
@onready var engine_audio: AudioStreamPlayer3D = $EngineAudio
@onready var _wheels: Array[VehicleWheel3D] = [$wheel_fl, $wheel_fr, $wheel_rl, $wheel_rr]
## The pair with use_as_traction set in Car.tscn. They are also the steering
## pair, so what is under them decides both how the car pulls and how it turns.
@onready var _drive_wheels: Array[VehicleWheel3D] = [$wheel_fl, $wheel_fr]

var _driver: CharacterBody3D = null
var _cam_yaw: float = 0.0
var _cam_pitch: float = 0.0
var _chunk_manager: ChunkManager
var _weather: WeatherSystem
var _day_night: DayNightCycle

## 0 = all drive wheels on sand, 1 = all on tarmac. Everything surface-dependent
## reads this rather than testing the terrain again.
var _drive_surface: float = 1.0
## Drawn slip ratio, 0 = gripping. Read by _update_wheelspin, and available to
## whatever tyre smoke and audio get added later.
var _wheel_slip: float = 0.0
var _spin_angle: float = 0.0
var _drive_wheel_meshes: Array[Node3D] = []
var _drive_wheel_rest_basis: Array[Basis] = []

## Keeps the car from rolling away on its own. On by default, same as a real
## handbrake -- the player has to release it before driving off. Deliberately
## NOT re-engaged on exit: it is a control the player operates, so leaving the
## car in neutral on a slope has to be allowed to mean what it says.
var parking_brake_engaged: bool = true
var _park_settle: float = 0.0

## Rate-limited steering target. The wheels lag behind this by steer_smoothing,
## so the command and what the car is actually doing are two different numbers.
var _steer_command: float = 0.0

var _hint_text: String = ""
var _hint_timer: float = 0.0

## Physics frames left of the static hand-over window, and the motion to give
## the car back when it closes.
var _handover_left: int = 0
var _handover_velocity := Vector3.ZERO
var _handover_spin := Vector3.ZERO

## Last physics frame's motion, for the runaway guard.
var _last_velocity := Vector3.ZERO
var _last_spin := Vector3.ZERO
var _last_speed_kmh: float = 0.0
var _runaway_reported: bool = false
## False until the guard has one frame of history to compare against. The car is
## positioned by world.gd after _ready(), so frame one is a teleport, not motion.
var _guard_primed: bool = false

var _cabin := CabinClimate.new()
## 0 = the bus is open, 1 = fully muffled. Both slide rather than switch.
var _outside_muffle: float = 0.0
var _inside_muffle: float = 1.0


func _ready() -> void:
	_chunk_manager = get_tree().get_first_node_in_group("chunk_manager")
	_weather = get_tree().get_first_node_in_group("weather") as WeatherSystem
	_day_night = get_tree().get_first_node_in_group("day_night") as DayNightCycle

	_cabin.sun_gain_c = cabin_sun_gain_c

	# Cached at ready because VehicleBody3D overwrites each VehicleWheel3D's
	# transform every physics tick; the mesh CHILD is ours to spin, and its rest
	# basis carries the model's scale, which must survive that.
	for wheel in _drive_wheels:
		var mesh := wheel.get_node_or_null(^"Wheel") as Node3D
		if mesh:
			_drive_wheel_meshes.append(mesh)
			_drive_wheel_rest_basis.append(mesh.transform.basis)

	_update_parking_brake_label()
	_apply_bus_state(OUTSIDE_BUS, _outside_muffle)
	_apply_bus_state(INSIDE_BUS, _inside_muffle)

	engine_audio.stream = load("res://assets/vehicles/doge/engine.wav")
	# AudioStreamWAV's own loop metadata isn't reliable across arbitrary source
	# files; replaying on "finished" loops it regardless.
	engine_audio.finished.connect(engine_audio.play)


# --- entering and leaving ---------------------------------------------------

func get_interact_prompt() -> String:
	return "Press Enter to drive" if _driver == null else ""


## Toggles between entering and leaving depending on current state, so the same
## "interact" key works for both.
func interact(player: CharacterBody3D) -> void:
	if _driver == null:
		_enter(player)
	else:
		_try_exit()


## Refuses to open the door above walking pace. Both ways out of the car come
## through here so the check cannot be sidestepped by using the other one.
func _try_exit() -> void:
	if get_speed_kmh() > exit_speed_limit_kmh:
		_flash_hint("Too fast to get out")
		return
	_exit()


func _enter(player: CharacterBody3D) -> void:
	_driver = player
	player.set_driving(true, self)
	_cam_yaw = 0.0
	_cam_pitch = 0.0
	driver_camera.rotation = Vector3.ZERO
	driver_camera.current = true
	parking_brake_label.visible = true
	engine_audio.play()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _exit() -> void:
	var player := _driver
	_driver = null
	parking_brake_label.visible = false
	_hint_timer = 0.0
	engine_audio.stop()

	_begin_handover()
	_place_driver(player)
	player.set_driving(false, null)


## Goes static for a few physics frames so that putting the player down beside
## the car cannot move the car. See handover_frames.
func _begin_handover() -> void:
	if freeze:
		# Already parked and static. There is nothing to protect it from.
		return
	_handover_velocity = linear_velocity
	_handover_spin = angular_velocity
	_handover_left = maxi(handover_frames, 1)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	freeze = true


## Gives the car back its motion and lets physics have it again.
func _end_handover() -> void:
	_handover_left = 0
	freeze = false
	linear_velocity = _handover_velocity
	angular_velocity = _handover_spin
	_last_velocity = _handover_velocity
	_last_spin = _handover_spin
	_last_speed_kmh = Vector3(_handover_velocity.x, 0.0, _handover_velocity.z).length() * 3.6


## Sets the player down somewhere they actually fit.
##
## This is more careful than it looks like it needs to be, for a reason worth
## keeping: a collider that appears INSIDE a rigid body is separated by the
## solver in a single step, and the velocity that takes is enormous. Getting out
## of the car must never be able to launch the car. The driver's door is tried
## first, then the far side, then off each end.
func _place_driver(player: CharacterBody3D) -> void:
	# The marker says which side the driver's door is on and how far along the
	# car it sits. How far OUT is exit_side_offset, not the marker -- the marker
	# was set where a door is, and a door is not far enough away to be safe.
	var door := exit_point.position
	var side := -1.0 if door.x < 0.0 else 1.0
	var candidates: Array[Vector3] = [
		Vector3(side * exit_side_offset, 0.0, door.z),
		Vector3(-side * exit_side_offset, 0.0, door.z),
		Vector3(0.0, 0.0, exit_end_offset),
		Vector3(0.0, 0.0, -exit_end_offset),
	]

	var first_spot := Vector3.ZERO
	for i in candidates.size():
		var spot := _ground_at(to_global(candidates[i]))
		if i == 0:
			first_spot = spot
		if not player.has_method(&"fits_at") or bool(player.call(&"fits_at", spot)):
			player.global_position = spot
			return

	# Boxed in on every side. Use the door anyway: being nudged out of a rock is
	# recoverable, being unable to leave the car is not.
	player.global_position = first_spot


## Drops a point onto the terrain. The marker in the scene fixes where BESIDE
## the car the player steps out; only the ground knows how high that is.
func _ground_at(pos: Vector3) -> Vector3:
	if _chunk_manager and _chunk_manager.gen:
		pos.y = _chunk_manager.gen.get_height(pos.x, pos.z) + exit_clearance
	return pos


func is_occupied() -> bool:
	return _driver != null


# --- input ------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _driver == null:
		return
	if event.is_action_pressed("interact"):
		_try_exit()
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


# --- driving ----------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _handover_left > 0:
		_handover_left -= 1
		if _handover_left == 0:
			_end_handover()
		return

	_guard_runaway()
	_update_surface()

	# Propulsion is applied by hand below; make sure nothing is left on the
	# wheels from an earlier frame or from the Inspector.
	engine_force = 0.0

	if _driver != null:
		# ChunkManager streams terrain around the player node; keep it glued to
		# the car so the road ahead keeps loading while driving.
		_driver.global_position = global_position

	var demand := 0.0
	if _driver != null and not parking_brake_engaged:
		demand = _drive(delta)
	else:
		# Nobody at the controls: let go of the brake and centre the wheel. The
		# parking brake puts the brake back on below if it is engaged -- without
		# clearing it here, a car left mid-brake would stay braked forever.
		brake = 0.0
		_center_steering(delta)

	_update_parking_brake(delta)
	_update_wheelspin(delta, demand)

	if freeze:
		return

	_apply_resistance()
	_apply_stability(delta)


## Refuses to let a car with nobody in it gain a large amount of speed in a
## single physics frame.
##
## This is a backstop, not a model. Nothing here accelerates a driverless car --
## drag, rolling resistance, the grip assist and the roll damping all oppose
## whatever it is doing -- so a jump of 25 km/h in one frame is 12 g and did not
## come from the car. It came from a contact being resolved: a shape appearing
## inside another, or a trimesh triangle pushing the wrong way. Rejecting it
## keeps a bad contact from turning into a car on the horizon, and it says so in
## the log rather than swallowing it silently, because a hit here means
## something upstream is still wrong.
##
## Deliberately scoped to the unoccupied car. Nothing about driving goes through
## this, so it can never quietly eat a real collision the player caused.
func _guard_runaway() -> void:
	var speed := get_speed_kmh()
	if _guard_primed and _driver == null and not freeze \
			and speed - _last_speed_kmh > runaway_speed_jump_kmh:
		if not _runaway_reported:
			_runaway_reported = true
			push_warning(("Car: rejected a %.0f km/h jump in one physics frame "
				+ "(%.0f -> %.0f). Something is pushing the parked car.")
				% [speed - _last_speed_kmh, _last_speed_kmh, speed])
		linear_velocity = _last_velocity
		angular_velocity = _last_spin
		speed = _last_speed_kmh

	_last_speed_kmh = speed
	_last_velocity = linear_velocity
	_last_spin = angular_velocity
	_guard_primed = true


## Reads the pedals and returns the acceleration the engine is ASKING for, in
## m/s^2, signed: positive forward, negative reversing, zero coasting or
## braking. What it asks for and what the surface will give it are different
## numbers, and the gap between them is exactly the wheelspin.
func _drive(delta: float) -> float:
	var forward := -global_basis.z
	var forward_speed := linear_velocity.dot(forward)
	var demand := 0.0

	if Input.is_action_pressed("move_forward"):
		# Ease the throttle off across the last couple of m/s rather than
		# cutting it dead at the cap. A hard cut makes the car hunt on and off
		# full power at top speed, which reads as surging.
		var headroom := clampf((max_speed_kmh / 3.6 - forward_speed) * 0.5, 0.0, 1.0)
		demand = forward_acceleration * headroom
		if demand > 0.0:
			apply_central_force(forward * mass * minf(demand, _surface_grip()))
		brake = 0.0
	elif Input.is_action_pressed("move_back"):
		if forward_speed > REVERSE_THRESHOLD_MPS:
			# Still rolling forward: this is a brake press, not reverse.
			brake = _brake_impulse(brake_deceleration)
		else:
			var headroom := clampf((reverse_speed_kmh / 3.6 + forward_speed) * 0.5, 0.0, 1.0)
			demand = -reverse_acceleration * headroom
			if demand < 0.0:
				apply_central_force(-forward * mass * minf(-demand, _surface_grip()))
			brake = 0.0
	else:
		brake = 0.0

	var steer_input := Input.get_action_strength("move_left") - Input.get_action_strength("move_right")
	var limit := _steer_limit()
	var target := steer_input * limit
	# Coming back to centre is quicker than winding on lock, which is both true
	# of a real wheel under caster and what stops the car tramlining after a
	# correction.
	var rate := steer_speed if absf(target) > absf(_steer_command) else steer_return_speed
	_steer_command = move_toward(_steer_command, target, _steer_rate(rate, limit) * delta)
	# Accelerating out of a slow corner shrinks the lock under the command.
	# Clamping is a step, but the smoothing below is what the wheels actually
	# follow, so it arrives as a squeeze rather than a snap.
	_steer_command = clampf(_steer_command, -limit, limit)
	_smooth_steering(delta)

	return demand


## Rate limit for the steering command, scaled by how much lock is available
## right now. See steer_speed for why a flat rate does not work.
func _steer_rate(base: float, limit: float) -> float:
	return base * limit / maxf(steer_limit_parked, 0.001)


## The road wheels chase the rate-limited command rather than tracking it
## exactly, which is what rounds off the start and end of every input.
func _smooth_steering(delta: float) -> void:
	steering = lerpf(steering, _steer_command,
		1.0 - exp(-delta / maxf(steer_smoothing, 0.001)))


## Unwind to straight ahead. Used whenever nobody is working the wheel -- the
## parking brake is on, or there is no driver at all.
func _center_steering(delta: float) -> void:
	_steer_command = move_toward(_steer_command, 0.0,
		_steer_rate(steer_return_speed, _steer_limit()) * delta)
	_smooth_steering(delta)


## Steering lock available at the current speed. Square-rooted so the lock is
## gone quickly off the line and then tapers, rather than staying dangerously
## generous through the middle of the range.
func _steer_limit() -> float:
	var ratio := clampf(_horizontal_speed() / (max_speed_kmh / 3.6), 0.0, 1.0)
	return lerpf(steer_limit_parked, steer_limit_flat_out, sqrt(ratio))


## Drag, rolling resistance and downforce. Drag is what sets top speed: it is
## solved so that full throttle balances against it at exactly max_speed_kmh,
## which is why nothing here ever writes linear_velocity.
func _apply_resistance() -> void:
	var v := Vector3(linear_velocity.x, 0.0, linear_velocity.z)
	var speed := v.length()
	if speed < 0.05:
		return

	var top := max_speed_kmh / 3.6
	var drag_k := maxf(forward_acceleration - rolling_resistance, 0.1) / (top * top)
	var decel := drag_k * speed * speed
	if _wheels_on_ground() > 0:
		decel += rolling_resistance
	apply_central_force(-v.normalized() * mass * decel)

	var ratio := clampf(speed / top, 0.0, 1.0)
	apply_central_force(Vector3.DOWN * mass * downforce_g * 9.8 * ratio * ratio)


## Grip assist and body-motion damping. All of it is gated on having wheels
## down: applied in mid-air it would let the player steer the car through a
## jump, which is exactly the arcade feel this is trying not to have.
func _apply_stability(delta: float) -> void:
	if _wheels_on_ground() == 0:
		return

	# Scrub off sideways velocity. On tarmac this is what keeps a heavy car
	# from fishtailing on a straight; on sand it is almost absent, so it slides.
	var right := global_basis.x
	var lateral := right.dot(linear_velocity)
	var grip := lerpf(lateral_grip_sand, lateral_grip_road, _drive_surface)
	# Framerate-independent: the force is sized to remove a fixed FRACTION of
	# the sideways velocity per second, not a fixed amount per tick.
	apply_central_force(-right * lateral * mass * minf(grip, 1.0 / maxf(delta, 0.001)))

	# Damp roll and pitch, leaving yaw alone so steering response is untouched.
	var forward := -global_basis.z
	apply_torque(-forward * forward.dot(angular_velocity) * mass * roll_damping)
	apply_torque(-right * right.dot(angular_velocity) * mass * pitch_damping)


# --- parking ----------------------------------------------------------------

## The parking brake holds in two stages: wheel brakes bring the car to rest,
## and then the body is frozen outright so it cannot creep. Freezing waits for
## the car to actually be settled -- freezing it in mid-air at spawn would leave
## it hanging there.
func _update_parking_brake(delta: float) -> void:
	if not parking_brake_engaged:
		_park_settle = 0.0
		if freeze:
			freeze = false
		return

	brake = _brake_impulse(parking_brake_deceleration)
	if freeze:
		return

	if _is_settled():
		_park_settle += delta
		if _park_settle >= PARK_SETTLE_SECONDS:
			linear_velocity = Vector3.ZERO
			angular_velocity = Vector3.ZERO
			freeze = true
	else:
		_park_settle = 0.0


func _is_settled() -> bool:
	return _wheels_on_ground() >= 3 \
		and linear_velocity.length() < PARK_SPEED_MPS \
		and angular_velocity.length() < PARK_SPIN_RADS


## VehicleBody3D.brake is an impulse in N*s applied once per physics tick, and
## it is NOT scaled by the step -- so a figure that means 9 m/s^2 at 60 Hz means
## 4.5 at 120. Writing brakes as decelerations and converting here is the only
## way the numbers stay honest across tick rates.
func _brake_impulse(deceleration: float) -> float:
	var step := 1.0 / maxf(float(Engine.physics_ticks_per_second), 1.0)
	return deceleration * mass * step / float(_wheels.size())


## Set the brake from outside the cockpit -- the console, and later a save file
## restoring how the player left it.
func set_parking_brake(engaged: bool) -> void:
	parking_brake_engaged = engaged
	_update_parking_brake_label()


## Teleport the car and leave it parked. Unfreezing first matters: a frozen body
## is static to the physics server, and moving a static body is how you end up
## with it interpenetrating whatever it landed in.
func place_at(pos: Vector3, yaw: float) -> void:
	_handover_left = 0
	freeze = false
	_park_settle = 0.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_last_velocity = Vector3.ZERO
	_last_spin = Vector3.ZERO
	_last_speed_kmh = 0.0
	global_position = pos
	global_rotation = Vector3(0.0, yaw, 0.0)
	set_parking_brake(true)


## True once the parking brake has actually taken hold, as opposed to merely
## being switched on while the car is still rolling to a stop.
func is_parked() -> bool:
	return freeze


## A one-off line in the cockpit, above the parking brake readout. Shares that
## label rather than adding a second node: it is anchored bottom-right and grows
## upward, so an extra line lands exactly where a warning wants to be.
func _flash_hint(message: String) -> void:
	_hint_text = message
	_hint_timer = HINT_SECONDS
	_update_parking_brake_label()


func _update_parking_brake_label() -> void:
	var state_bbcode := "[color=green]Y[/color]" if parking_brake_engaged else "[color=red]N[/color]"
	var hint := ("[color=yellow]%s[/color]\n" % _hint_text) if _hint_timer > 0.0 else ""
	parking_brake_label.text = "%sP - Parking Brake: %s" % [hint, state_bbcode]


# --- surfaces and wheelspin -------------------------------------------------

## Sets per-wheel friction from what each one is standing on, and works out how
## much of the drive axle is on tarmac. Falls back to full road grip when there
## is no terrain to sample yet.
func _update_surface() -> void:
	if _chunk_manager == null or _chunk_manager.gen == null:
		_drive_surface = 1.0
		return

	var gen := _chunk_manager.gen
	for wheel in _wheels:
		var on_road := gen.is_paved_road(wheel.global_position.x, wheel.global_position.z)
		wheel.wheel_friction_slip = road_friction_slip if on_road else sand_friction_slip

	# Blended across the drive wheels rather than taken from one of them, so
	# dropping a wheel onto the shoulder pulls the car about instead of
	# switching the whole surface over at once.
	var on_tarmac := 0
	for wheel in _drive_wheels:
		if gen.is_paved_road(wheel.global_position.x, wheel.global_position.z):
			on_tarmac += 1
	_drive_surface = float(on_tarmac) / float(_drive_wheels.size())


## Peak acceleration the surface under the drive wheels can transmit, m/s^2.
## The one number that both caps the force actually applied and sets how hard
## the tyres are drawn spinning, so the two can never disagree: whatever the
## engine asks for above this figure does not move the car, it spins the wheels.
func _surface_grip() -> float:
	return lerpf(sand_grip_accel, road_grip_accel, _drive_surface)


## Draws the wheelspin the physics does not produce.
##
## Nothing is driving the wheels (see the header), so VehicleBody3D rolls them
## at exactly road speed and they would sit there looking gripped while the car
## bogs down in sand. The slip ratio is the honest one -- how much more force
## the engine is asking for than the surface can transmit -- so the tyres break
## loose precisely when and as hard as the car actually loses drive.
##
## The extra rotation goes on the mesh CHILD of each wheel, because
## VehicleBody3D overwrites the VehicleWheel3D node's own transform every tick
## and anything written there is gone by the next frame.
##
## That works out exactly, and the reason is worth writing down. Godot builds
## the wheel's basis as  steer * roll(angle) * F, where F's columns are
## (right, up, forward). F has determinant -1 -- forward is up.cross(right),
## which makes the frame left-handed -- so conjugating a rotation through it
## flips the sign: F * rot_x(t) * F.inverse() == rot_right(-t). Multiplying the
## child's basis by rot_x(t) is therefore identical to setting the wheel's own
## roll angle to (angle - t), i.e. it advances the SAME rotation the physics is
## already applying. Positive t rolls forward, matching this car's forward.
## Nothing has to be flipped per side, and the mesh's scale rides through
## untouched because it is uniform.
func _update_wheelspin(delta: float, demand: float) -> void:
	var slip_target := 0.0
	if absf(demand) > 0.01:
		slip_target = clampf(absf(demand) / maxf(_surface_grip(), 0.01) - 1.0,
			0.0, wheelspin_max)
	# Spin up fast, settle back slower -- tyres regain grip gradually as the car
	# catches up with them.
	var rate := 12.0 if slip_target > _wheel_slip else 4.0
	_wheel_slip = lerpf(_wheel_slip, slip_target, clampf(rate * delta, 0.0, 1.0))

	if _drive_wheel_meshes.is_empty() or _wheel_slip < 0.001:
		return

	var direction := signf(demand) if absf(demand) > 0.01 else 1.0
	var extra_speed := _wheel_slip * wheelspin_reference_speed * direction
	var radius := maxf(_drive_wheels[0].wheel_radius, 0.01)
	_spin_angle = wrapf(_spin_angle + extra_speed * delta / radius, -TAU, TAU)

	for i in _drive_wheel_meshes.size():
		_drive_wheel_meshes[i].transform.basis = \
			_drive_wheel_rest_basis[i] * Basis(Vector3.RIGHT, _spin_angle)


## How hard the drive tyres are slipping, 0 = gripping. For tyre smoke, skid
## audio and anything else that wants to know the car is struggling.
func get_wheel_slip() -> float:
	return _wheel_slip


## 0 = both drive wheels on sand, 1 = both on tarmac.
func get_drive_surface() -> float:
	return _drive_surface


func get_speed_kmh() -> float:
	return _horizontal_speed() * 3.6


func _wheels_on_ground() -> int:
	var n := 0
	for wheel in _wheels:
		if wheel.is_in_contact():
			n += 1
	return n


func _horizontal_speed() -> float:
	return Vector3(linear_velocity.x, 0.0, linear_velocity.z).length()


# --- per-frame: audio and cabin air -----------------------------------------

func _process(delta: float) -> void:
	_update_isolation(delta)
	_update_cabin_climate(delta)
	if _hint_timer > 0.0:
		_hint_timer -= delta
		if _hint_timer <= 0.0:
			_hint_text = ""
			_update_parking_brake_label()
	if _driver != null:
		_update_engine_audio()


## Slides the two buses between open and muffled. Whichever side of the glass
## the player is NOT on gets rolled off: standing outside, the radio in the car
## is the muffled one; sitting inside, the wind and the world are.
func _update_isolation(delta: float) -> void:
	var inside := _driver != null
	var outside_target := 1.0 if inside else 0.0
	var inside_target := 0.0 if inside else 1.0
	# Settled is the common case by a very long way -- the player is in or out,
	# not moving between the two. Nothing to write, so write nothing.
	if is_equal_approx(_outside_muffle, outside_target) \
			and is_equal_approx(_inside_muffle, inside_target):
		return

	var k := clampf(delta / maxf(isolation_blend_seconds, 0.001), 0.0, 1.0)
	# move_toward, not lerp: an exponential approach never actually arrives, and
	# never arriving means the early-out above never fires and this writes to the
	# AudioServer for the rest of the session.
	_outside_muffle = move_toward(_outside_muffle, outside_target, k)
	_inside_muffle = move_toward(_inside_muffle, inside_target, k)
	_apply_bus_state(OUTSIDE_BUS, _outside_muffle)
	_apply_bus_state(INSIDE_BUS, _inside_muffle)


## Writes one bus's low-pass and level for a 0..1 muffle amount. Reaches into
## AudioServer directly rather than through a node -- buses are not scene-tree
## objects, and a stored reference would just be more state to keep in sync.
##
## The cutoff is interpolated in octaves rather than in hertz. Pitch is
## logarithmic, so a linear hertz sweep spends nearly all of its travel in the
## top octave, where almost nothing is happening, and then falls off a cliff.
func _apply_bus_state(bus_name: StringName, muffle: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx == -1:
		return
	var filter := AudioServer.get_bus_effect(idx, 0) as AudioEffectLowPassFilter
	if filter:
		filter.cutoff_hz = exp(lerpf(log(OPEN_CUTOFF_HZ),
			log(maxf(muffled_cutoff_hz, 20.0)), muffle))
	AudioServer.set_bus_volume_db(idx, lerpf(0.0, muffled_volume_db, muffle))


## Revs with road speed rather than throttle -- no gearbox model here, just
## enough to make accelerating and slowing down audible.
func _update_engine_audio() -> void:
	var ratio := clampf(_horizontal_speed() / (max_speed_kmh / 3.6), 0.0, 1.0)
	engine_audio.pitch_scale = lerpf(engine_min_pitch, engine_max_pitch, ratio)
	engine_audio.volume_db = lerpf(engine_min_volume_db, engine_max_volume_db, ratio)


## Steps the cabin's own air off the weather outside. Runs whether or not
## anyone is in the car, so climbing into one that has been sitting in the sun
## all afternoon costs what it should.
func _update_cabin_climate(delta: float) -> void:
	if _weather == null or _day_night == null:
		return
	var outside := _weather.get_state()
	if outside == null:
		return

	# How much sun is landing on the roof: altitude, minus whatever the cloud
	# and dust are holding back. Same shape BiomeWeatherState uses for the sun
	# on the player's back, for the same reason.
	var solar := clampf(smoothstep(-0.12, 0.35, _day_night.sun_direction.y), 0.0, 1.0) \
		* _weather.get_light_transmission()
	var vent := clampf(_horizontal_speed() * 3.6 / maxf(cabin_vent_speed_kmh, 1.0), 0.0, 1.0)

	_cabin.step(delta * _day_night.get_hours_per_second(),
		outside.temperature_c, outside.humidity, solar, vent)


# --- shelter contract -------------------------------------------------------
#
# What WeatherSystem asks any enclosed space the player is inside of. Keeping it
# to four methods means a hut or a tent later implements the same four and needs
# no special case anywhere else.

func get_shelter_name() -> String:
	return "car cabin"


## Nothing gets through a steel roof. A driver is out of the sun completely --
## the windows let light in, but not the radiant load that makes standing in
## desert sun different from standing in the same air in shade.
func get_shelter_sun_exposure() -> float:
	return 0.0


func get_shelter_wind_exposure() -> float:
	return 0.0


func get_shelter_climate() -> CabinClimate:
	return _cabin
