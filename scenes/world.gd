extends Node3D

## Session bootstrap. On a real run this seed comes from the host and is
## replicated to every client — same seed, same planet, no terrain sync.

@export var use_random_seed: bool = false
@export var fixed_seed: int = 12345

## Where the player starts. x = 0 is the eastern end of the westward road.
@export var spawn_x: float = 0.0
@export var spawn_z: float = 0.0

## How far down the road (west of spawn) the test car is parked, and how far
## off the centreline -- kept on the shoulder so it doesn't block the spawn.
const CAR_OFFSET_X := -8.0
const CAR_OFFSET_Z := 3.0

@onready var chunks: ChunkManager = $ChunkManager
@onready var player: CharacterBody3D = $Player
@onready var car: VehicleBody3D = $Car


func _ready() -> void:
	var world_seed := randi() if use_random_seed else fixed_seed
	chunks.world_seed = world_seed
	chunks.gen = WorldGen.new(world_seed)

	# Weather is seeded from here too, not from its own Inspector field.
	# Children are readied before their parent, so it has already come up on
	# whatever seed it had; this is what puts it on the session's.
	var weather := get_tree().get_first_node_in_group("weather") as WeatherSystem
	if weather:
		weather.set_world_seed(world_seed)

	# Build the ground under the spawn point BEFORE placing the player,
	# otherwise they fall through the world on frame one.
	# The centreline meanders, so spawn_z is an offset from the road, not from
	# world Z zero.
	var road_z := chunks.gen.road_center(spawn_x) + spawn_z
	player.global_position = chunks.spawn_position(spawn_x, road_z, 1.2)
	print("ROUTE 41 — seed %d, spawned at %v" % [world_seed, player.global_position])

	var car_x := spawn_x + CAR_OFFSET_X
	var car_road_z := chunks.gen.road_center(car_x) + spawn_z + CAR_OFFSET_Z
	# Just enough clearance to land on the road rather than in it. The car's
	# origin sits about 0.03 m above its contact patches, and the tessellated
	# mesh runs slightly below the true height function between vertices, so
	# this drops it a couple of centimetres onto its wheels. Any more and it
	# arrives with a bang; the parking brake then holds it where it lands.
	car.global_position = chunks.spawn_position(car_x, car_road_z, 0.25)
	# Road runs along X; face the car west (-X), the direction of travel.
	car.rotation.y = PI / 2.0
