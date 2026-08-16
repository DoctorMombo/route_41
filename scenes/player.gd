extends CharacterBody3D

## First-person walker. Deliberately plain — this gets replaced by the real
## survival-aware controller once hunger/stress/temperature exist.

@export var walk_speed: float = 5.0
@export var sprint_speed: float = 9.0
@export var jump_velocity: float = 6.0
@export var gravity: float = 22.0
@export var acceleration: float = 12.0
@export var mouse_sensitivity: float = 0.0025

@onready var camera: Camera3D = $Camera3D

var _pitch: float = 0.0


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity, -1.45, 1.45)
		camera.rotation.x = _pitch
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
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
