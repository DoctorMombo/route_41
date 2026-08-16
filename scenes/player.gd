extends CharacterBody3D

## First-person walker. Deliberately plain — this gets replaced by the real
## survival-aware controller once hunger/stress/temperature exist.

@export var walk_speed: float = 5.0
@export var sprint_speed: float = 9.0
@export var jump_velocity: float = 6.0
@export var gravity: float = 22.0
@export var acceleration: float = 12.0
@export var mouse_sensitivity: float = 0.0025
@export var interact_distance: float = 3.5

@onready var camera: Camera3D = $Camera3D
@onready var _collision: CollisionShape3D = $CollisionShape3D

var _pitch: float = 0.0
var _driving: bool = false

## Whatever "interactable" (see driver_seat.gd) the player is currently
## looking at, or null. Read by the HUD prompt and acted on by _unhandled_input.
var interact_target: Node = null


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Whether the player is currently in a vehicle. WeatherSystem asks, because
## a driver is out of the wind entirely and mostly out of the sun -- and no
## raycast can tell it that, since the camera sits inside the car's own
## collision shape.
func is_driving() -> bool:
	return _driving


## Called by a vehicle when the player enters/exits it. Physics, the
## first-person camera and look input all hand off to the vehicle while
## driving; the player node itself just goes dormant.
func set_driving(driving: bool) -> void:
	_driving = driving
	set_physics_process(not driving)
	camera.current = not driving
	_collision.disabled = driving
	visible = not driving
	interact_target = null


func _unhandled_input(event: InputEvent) -> void:
	if _driving:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.45, 1.45)
		camera.rotation.x = _pitch
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("interact") and interact_target:
		interact_target.interact(self)


func _physics_process(delta: float) -> void:
	_update_interact_target()

	if not is_on_floor():
		velocity.y -= gravity * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var direction := (transform.basis * Vector3(input_dir.x, 0.0, input_dir.y)).normalized()
	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	var target := direction * speed

	var t := clampf(acceleration * delta, 0.0, 1.0)
	velocity.x = lerpf(velocity.x, target.x, t)
	velocity.z = lerpf(velocity.z, target.z, t)

	move_and_slide()


## Raycasts from the camera to find an interactable the player is looking at,
## used to drive the "Press Enter" prompt.
func _update_interact_target() -> void:
	var from := camera.global_position
	var to := from - camera.global_transform.basis.z * interact_distance
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := get_world_3d().direct_space_state.intersect_ray(query)
	if result and result.collider.is_in_group("interactable"):
		interact_target = result.collider
	else:
		interact_target = null
