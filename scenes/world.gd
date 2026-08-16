extends Node3D

## Session bootstrap. On a real run this seed comes from the host and is
## replicated to every client — same seed, same planet, no terrain sync.

@export var use_random_seed: bool = false
@export var fixed_seed: int = 12345

## Where the player starts. x = 0 is the eastern end of the westward road.
@export var spawn_x: float = 0.0
@export var spawn_z: float = 0.0

@onready var chunks: ChunkManager = $ChunkManager
@onready var player: CharacterBody3D = $Player


func _ready() -> void:
	var world_seed := randi() if use_random_seed else fixed_seed
	chunks.world_seed = world_seed
	chunks.gen = WorldGen.new(world_seed)

	# Build the ground under the spawn point BEFORE placing the player,
	# otherwise they fall through the world on frame one.
	# The centreline meanders, so spawn_z is an offset from the road, not from
	# world Z zero.
	var road_z := chunks.gen.road_center(spawn_x) + spawn_z
	player.global_position = chunks.spawn_position(spawn_x, road_z, 1.2)
	print("ROUTE 41 — seed %d, spawned at %v" % [world_seed, player.global_position])
