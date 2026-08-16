class_name FootstepAudio
extends AudioStreamPlayer

## Footstep SFX for the player. Surface -- asphalt vs gravel/sand -- is read
## from WorldGen at the player's current position, so this works anywhere
## ChunkManager has terrain built without needing per-scene wiring.
##
## Cadence and volume follow actual horizontal velocity rather than the
## sprint input directly, so a sprint stalled against a slope doesn't keep
## playing running footsteps.

## Left empty, found via the "chunk_manager" group.
@export var chunk_manager: ChunkManager

@export_group("Cadence")
@export var walk_step_interval: float = 0.50
@export var run_step_interval: float = 0.36
## Horizontal speed (m/s) above which a step counts as "running". Halfway
## between Player's walk_speed (5) and sprint_speed (9).
@export var run_speed_threshold: float = 7.0
@export var min_move_speed: float = 0.3

@export_group("Volume")
@export_range(-24.0, 12.0) var walk_volume_db: float = -4.0
@export_range(-24.0, 12.0) var run_volume_db: float = 0.0
@export_range(-24.0, 12.0) var land_volume_db: float = -2.0

@export_group("Variation")
@export var pitch_variation: float = 0.08

@onready var _player: CharacterBody3D = get_parent()

var _asphalt_steps: Array[AudioStream] = []
var _gravel_steps: Array[AudioStream] = []
var _step_timer: float = 0.0
var _was_on_floor: bool = true


func _ready() -> void:
	for i in range(1, 7):
		_asphalt_steps.append(load("res://assets/step_asphalt_%02d.ogg" % i))
		_gravel_steps.append(load("res://assets/step_gravel_%02d.ogg" % i))

	if chunk_manager == null:
		chunk_manager = get_tree().get_first_node_in_group("chunk_manager") as ChunkManager
	if chunk_manager == null:
		push_warning("FootstepAudio: no ChunkManager in group 'chunk_manager'. Footsteps muted.")
		set_physics_process(false)


func _physics_process(delta: float) -> void:
	# _player's own physics processing is frozen while driving or while the
	# debug console is open (see Player.set_driving / DebugConsole._toggle),
	# but that doesn't touch this node -- without this check, velocity and
	# is_on_floor() stay frozen at their last live values and we'd keep
	# stepping to a walk that stopped.
	if not _player.is_physics_processing():
		_step_timer = 0.0
		return

	var grounded := _player.is_on_floor()
	var speed := Vector2(_player.velocity.x, _player.velocity.z).length()
	var running := speed > run_speed_threshold

	if grounded and not _was_on_floor:
		_play_step(land_volume_db)
		_step_timer = run_step_interval if running else walk_step_interval
	_was_on_floor = grounded

	if not grounded or speed < min_move_speed:
		_step_timer = 0.0
		return

	_step_timer -= delta
	if _step_timer <= 0.0:
		_play_step(run_volume_db if running else walk_volume_db)
		_step_timer += run_step_interval if running else walk_step_interval


func _play_step(base_db: float) -> void:
	if chunk_manager.gen == null:
		return
	var pos := _player.global_position
	var pool := _asphalt_steps if chunk_manager.gen.is_paved_road(pos.x, pos.z) else _gravel_steps
	stream = pool[randi() % pool.size()]
	volume_db = base_db + randf_range(-1.5, 1.5)
	pitch_scale = 1.0 + randf_range(-pitch_variation, pitch_variation)
	play()
