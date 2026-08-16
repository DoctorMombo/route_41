class_name ChunkManager
extends Node3D

## Minecraft-style chunk streaming. Builds terrain chunks around a target
## node and frees them when they fall out of range.

## Chunks are only freed beyond view_distance + this margin. Without the gap,
## standing on a chunk boundary destroys and rebuilds the same chunks forever.
@export var keep_distance_margin: int = 2

@export var world_seed: int = 0
@export var chunk_size: float = 64.0        ## metres per chunk edge
@export var chunk_resolution: int = 32      ## quads per edge (32 = 2m per vertex)
@export var view_distance_chunks: int = 8   ## radius in chunks (5 = ~320m)
@export var chunks_per_frame: int = 2       ## build budget, keeps frame time flat
@export var streaming_target: Node3D        ## drag the Player here in the Inspector

var gen: WorldGen

var _chunks: Dictionary = {}
var _build_queue: Array[Vector2i] = []
var _last_center := Vector2i(2147483647, 2147483647)
var _terrain_material: ShaderMaterial


func _ready() -> void:
	gen = WorldGen.new(world_seed)

	_terrain_material = ShaderMaterial.new()
	_terrain_material.shader = load("res://shaders/terrain.gdshader")
	_terrain_material.set_shader_parameter("detail_map",
		load("res://assets/terrain_detail.png"))
	_terrain_material.set_shader_parameter("cliff_normal",
		load("res://assets/cliff_normal.png"))
	_terrain_material.set_shader_parameter("road_albedo",
		load("res://assets/road_albedo.png"))
	_terrain_material.set_shader_parameter("road_normal",
		load("res://assets/asphalt_normal.png"))
	_terrain_material.set_shader_parameter("road_patch_albedo",
		load("res://assets/road_patch_albedo.png"))
	_terrain_material.set_shader_parameter("road_patch_normal",
		load("res://assets/road_patch_normal.png"))
	_terrain_material.set_shader_parameter("gravel_albedo",
		load("res://assets/gravel_albedo.png"))
	_terrain_material.set_shader_parameter("gravel_normal",
		load("res://assets/gravel_normal.png"))
	# Keep the shader's corridor width in step with the generator.
	_terrain_material.set_shader_parameter("road_half_width", WorldGen.ROAD_HALF_WIDTH)
	_terrain_material.set_shader_parameter("road_half_width", WorldGen.ROAD_HALF_WIDTH)
	_terrain_material.set_shader_parameter("road_end_x", WorldGen.ROAD_END_X)
	_terrain_material.set_shader_parameter("road_gravel_run", WorldGen.ROAD_GRAVEL_RUN)
	_terrain_material.set_shader_parameter("road_fade_sharpness", WorldGen.ROAD_FADE_SHARPNESS)


func _process(_delta: float) -> void:
	if streaming_target == null:
		return

	var center := chunk_coord_for(streaming_target.global_position)
	if center != _last_center:
		print("chunk centre -> ", center, "   chunks: ", _chunks.size(), "  queued: ", _build_queue.size())
		_last_center = center
		_refresh_queue(center)

	var built := 0
	while built < chunks_per_frame and not _build_queue.is_empty():
		var coord: Vector2i = _build_queue.pop_front()
		if _chunks.has(coord):
			continue
		_create_chunk(coord)
		built += 1


func chunk_coord_for(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / chunk_size), floori(pos.z / chunk_size))


## Force a chunk to exist right now (used so the player has ground to spawn on).
func ensure_chunk_at(pos: Vector3) -> void:
	var coord := chunk_coord_for(pos)
	if not _chunks.has(coord):
		_create_chunk(coord)


## A safe spawn point standing on the terrain at the given X/Z.
func spawn_position(x: float, z: float, clearance: float = 1.0) -> Vector3:
	preload_chunks_around(Vector3(x, 0.0, z), 1)
	return Vector3(x, gen.get_height(x, z) + clearance, z)


func _refresh_queue(center: Vector2i) -> void:
	var r := view_distance_chunks
	var keep := float(r + keep_distance_margin)

	_build_queue.clear()
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			if Vector2(dx, dz).length() > float(r) + 0.5:
				continue
			var coord := center + Vector2i(dx, dz)
			if not _chunks.has(coord):
				_build_queue.append(coord)

	# Free only what is well outside the view radius. The margin means a
	# one-chunk wobble at a boundary costs nothing instead of thrashing.
	for coord: Vector2i in _chunks.keys():
		if Vector2(coord - center).length() > keep + 0.5:
			_chunks[coord].queue_free()
			_chunks.erase(coord)

	# Nearest first, so ground under your feet appears before the horizon.
	_build_queue.sort_custom(
		func(a: Vector2i, b: Vector2i) -> bool:
			return Vector2(a - center).length_squared() < Vector2(b - center).length_squared()
	)


func _create_chunk(coord: Vector2i) -> void:
	var origin := Vector3(coord.x * chunk_size, 0.0, coord.y * chunk_size)
	var mesh := _build_chunk_mesh(origin)

	var body := StaticBody3D.new()
	body.name = "Chunk_%d_%d" % [coord.x, coord.y]
	body.position = origin

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _terrain_material
	body.add_child(mi)

	var col := CollisionShape3D.new()
	var tri_shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	# Solid from both sides. Costs nothing measurable and means a future
	# winding mistake can never silently drop a player or vehicle into the void.
	tri_shape.backface_collision = true
	col.shape = tri_shape
	body.add_child(col)

	add_child(body)
	_chunks[coord] = body


func _build_chunk_mesh(origin: Vector3) -> ArrayMesh:
	var res := chunk_resolution
	var step := chunk_size / float(res)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	for zi in range(res + 1):
		for xi in range(res + 1):
			var lx := xi * step
			var lz := zi * step
			var wx := origin.x + lx
			var wz := origin.z + lz

			# Vertices are stored LOCAL to the chunk; the node carries the offset.
			# Sample once, reuse. get_color() needs both and would otherwise
			# recompute the normal, which costs four more height evaluations.
			var y := gen.get_height(wx, wz)
			var n := gen.get_normal(wx, wz)
			verts.append(Vector3(lx, y, lz))
			normals.append(n)
			uvs.append(Vector2(wx, wz) * 0.1)
			# Road-local coordinates for the shader: lateral offset from the
			# centreline, and distance along the road. The shader needs these
			# because road_center() is GDScript noise it can't evaluate itself.
			uv2s.append(Vector2(gen.road_offset(wx, wz), wx))
			colors.append(gen.get_color(wx, wz, y, n))

	var row := res + 1
	for zi in range(res):
		for xi in range(res):
			var i := zi * row + xi
			# Godot front faces are CLOCKWISE. This order makes both triangles
			# face +Y (up), which matters twice over: backface culling makes the
			# terrain visible from above, and one-sided trimesh collision makes
			# it solid from above.
			indices.append(i)
			indices.append(i + 1)
			indices.append(i + row)
			indices.append(i + 1)
			indices.append(i + row + 1)
			indices.append(i + row)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## Build every chunk within `radius` chunks of a position, immediately and
## synchronously. Used at spawn so the player never lands on a chunk edge
## with nothing beyond it. radius 1 = a 3x3 block = 192m of solid ground.
func preload_chunks_around(pos: Vector3, radius: int = 1) -> void:
	var center := chunk_coord_for(pos)
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var coord := center + Vector2i(dx, dz)
			if not _chunks.has(coord):
				_create_chunk(coord)
