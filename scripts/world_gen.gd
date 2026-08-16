class_name WorldGen
extends RefCounted

## Deterministic terrain source for the whole planet.
##
## Same seed = identical terrain on every machine, so terrain geometry never
## has to be sent over the network in co-op.
##
## Starting biome: badlands. A near-flat desert plain, cut by shallow erosion
## gullies, with fields of terraced buttes rising out of it. The plain is
## drivable; the buttes are not. That keeps the road the efficient route west
## without walling the player in.

# --- road layout (metres) ---------------------------------------------------
## Half the paved width. 5.5 gives an 11 m carriageway: two 3.7 m lanes plus
## 1.8 m of sealed shoulder either side, so vehicles pass comfortably.
const ROAD_HALF_WIDTH := 5.5
const ROAD_SHOULDER := 14.0       ## blend from road level out into wild terrain
const CENTER_LINE_INNER := 0.14   ## gap between the two yellow lines
const CENTER_LINE_OUTER := 0.38
const EDGE_LINE_INSET := 1.70     ## white line, measured in from the road edge
const EDGE_LINE_WIDTH := 0.18

## How far the centreline wanders off due west, in metres. Broad is the long
## sweep around big landforms; fine is the gentle S between them.
const MEANDER_BROAD := 210.0
const MEANDER_FINE := 38.0
## Scales how closely the road grade follows the plain. Below 1.0 the road
## cuts and fills rather than draping, which keeps the gradient down.
const ROAD_GRADE_SCALE := 0.80
## Slow independent roll, so the surface isn't perfectly welded to the terrain.
const ROAD_ROLL := 1.8

## Eastern end of the road. Sealed tarmac runs west from here forever; east of
## it the roadbed degrades to gravel and then vanishes into open scrub. The
## player spawns at x = 0, so the tarmac starts under their feet.
const ROAD_END_X := 0.0
## Metres of unpaved roadbed east of the terminus before the road is simply gone.
const ROAD_GRAVEL_RUN := 50.0
## How abruptly the roadbed lets go at its eastern end. 1.0 is a linear
## crossfade across the whole gravel run, which reads as terrain colour smeared
## over gravel. Lower values hold the bed at full strength, then end it.
const ROAD_FADE_SHARPNESS := 0.35
## How ragged the gravel edge is. 0.0 ends the bed on a clean curve; higher
## values scatter it into the scrub. Only acts inside the transition band.
const ROAD_FRAY := 0.34

# --- terrain shape ----------------------------------------------------------
const PLAIN_AMPLITUDE := 2.6      ## gentle swells across the flats
const GULLY_DEPTH := 3.2          ## erosion channels cut into the plain
const BUTTE_HEIGHT := 58.0        ## how far formations rise above the plain
const BUTTE_THRESHOLD := 0.06     ## higher = rarer butte fields
## Vertical spacing of eroded ledges. Must stay comfortably larger than the
## vertex spacing (chunk_size / chunk_resolution, currently 2 m) or the mesh
## cannot resolve the ledges and they alias into spikes.
const TERRACE_STEP := 5.5
## 0 = fully rounded ledges, 1 = knife-edge risers.
const TERRACE_SHARPNESS := 0.45
## How far the terracing relaxes back toward the raw slope. Higher = more
## eroded and rounded, lower = more freshly cut.
const WEATHERING := 0.55
## Rounds the tips off ridged noise. abs() has a corner at zero and that corner
## lands exactly on the ridge crest -- it is what reads as a spike. Larger
## values round harder; 0.0 restores knife edges.
const CREST_ROUNDING := 0.030
## Metres of graded approach either side of the road corridor. Without it the
## road cuts a slot canyon with vertical walls wherever it crosses a butte.
const BUTTE_ROAD_CLEARANCE := 75.0
const DETAIL_AMPLITUDE := 0.30    ## fine gravel roughness

# --- palette ----------------------------------------------------------------
const COLOR_ASPHALT := Color(0.208, 0.200, 0.204)
const COLOR_LINE_YELLOW := Color(0.760, 0.600, 0.150)
const COLOR_LINE_WHITE := Color(0.800, 0.790, 0.760)
const COLOR_SHOULDER := Color(0.520, 0.450, 0.340)
const COLOR_GRASS_DRY := Color(0.640, 0.560, 0.330)
const COLOR_GRASS_OLIVE := Color(0.430, 0.430, 0.250)
const COLOR_SOIL := Color(0.580, 0.480, 0.370)

## Banded sedimentary layers, bottom to top. Repeats vertically.
const STRATA_COLORS: Array[Color] = [
	Color(0.660, 0.580, 0.450),
	Color(0.780, 0.680, 0.400),
	Color(0.850, 0.800, 0.680),
	Color(0.700, 0.510, 0.420),
	Color(0.865, 0.845, 0.765),
	Color(0.740, 0.640, 0.460),
]
const STRATA_THICKNESS := 3.0

var world_seed: int = 0

var _plain_noise := FastNoiseLite.new()
var _gully_noise := FastNoiseLite.new()
var _region_noise := FastNoiseLite.new()
var _butte_noise := FastNoiseLite.new()
var _detail_noise := FastNoiseLite.new()
var _strata_warp := FastNoiseLite.new()
var _tint_noise := FastNoiseLite.new()
var _road_noise := FastNoiseLite.new()
var _center_broad := FastNoiseLite.new()
var _center_fine := FastNoiseLite.new()
var _fray_noise := FastNoiseLite.new()


func _init(p_seed: int = 0) -> void:
	world_seed = p_seed

	# Broad, very low swells across the flats.
	_plain_noise.seed = world_seed
	_plain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_plain_noise.frequency = 0.0035
	_plain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_plain_noise.fractal_octaves = 3

	# Erosion channels. Ridged so the low points form connected washes.
	_gully_noise.seed = world_seed + 11
	_gully_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_gully_noise.frequency = 0.009
	_gully_noise.fractal_octaves = 2

	# Where butte fields cluster. Low frequency: large, distinct regions.
	_region_noise.seed = world_seed + 23
	_region_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_region_noise.frequency = 0.0011
	_region_noise.fractal_octaves = 2

	# The formations themselves.
	_butte_noise.seed = world_seed + 37
	_butte_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_butte_noise.frequency = 0.0065
	_butte_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	# Three octaves, not four, and a low gain. The top octave was adding
	# metre-scale ridges that the 2 m mesh cannot resolve.
	_butte_noise.fractal_octaves = 3
	_butte_noise.fractal_gain = 0.42

	_detail_noise.seed = world_seed + 53
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.frequency = 0.07
	_detail_noise.fractal_octaves = 2

	# Bends the strata bands so they aren't perfectly level rings.
	_strata_warp.seed = world_seed + 71
	_strata_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_strata_warp.frequency = 0.004
	_strata_warp.fractal_octaves = 2

	# Patchy dry-grass variation on the flats.
	_tint_noise.seed = world_seed + 89
	_tint_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_tint_noise.frequency = 0.012
	_tint_noise.fractal_octaves = 2

	_road_noise.seed = world_seed + 101
	_road_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_road_noise.frequency = 0.0009
	_road_noise.fractal_octaves = 2

	# Centreline meander. Frequency sets the wavelength (roughly 1/frequency in
	# metres); together with the amplitude it fixes how sharply the road turns.
	# Peak lateral gradient is about 2*PI*amplitude*frequency -- keep the sum of
	# the two layers under ~0.7 or the road starts heading sideways.
	_center_broad.seed = world_seed + 113
	_center_broad.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_center_broad.frequency = 0.00030
	_center_broad.fractal_octaves = 1

	_center_fine.seed = world_seed + 127
	_center_fine.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_center_fine.frequency = 0.00110
	_center_fine.fractal_octaves = 1

	# Breaks up the eastern end of the gravel. ~12 m features: coarse enough
	# that 2 m vertex spacing can actually represent them.
	_fray_noise.seed = world_seed + 149
	_fray_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_fray_noise.frequency = 0.080
	_fray_noise.fractal_octaves = 2


## Where the road's centreline sits, in Z, at a given distance along X.
## Single-valued in X: the road meanders but never doubles back, which is what
## keeps get_height() a pure local function of (x, z).
func road_center(x: float) -> float:
	return _center_broad.get_noise_1d(x) * MEANDER_BROAD \
		+ _center_fine.get_noise_1d(x) * MEANDER_FINE


## Signed metres from the centreline. Positive is north of the road.
func road_offset(x: float, z: float) -> float:
	return z - road_center(x)


## 1.0 where the roadbed is still graded flat, falling to 0 past the eastern
## terminus. Everything about the road is gated on this: corridor flattening,
## butte clearance, and the surface itself.
func road_presence(x: float, z: float) -> float:
	# Early outs: the road is infinite westward, so almost every sample in the
	# world takes the first branch and never touches the fray noise.
	if x <= ROAD_END_X - 1.0:
		return 1.0
	if x >= ROAD_END_X + ROAD_GRAVEL_RUN + 20.0:
		return 0.0

	var t := 1.0 - smoothstep(ROAD_END_X, ROAD_END_X + ROAD_GRAVEL_RUN, x)
	# Window the fray so it only acts mid-transition. Applied unwindowed it
	# would scatter stray gravel far out east and eat into the sealed road.
	var window := clampf(t * (1.0 - t) * 4.0, 0.0, 1.0)
	t += _fray_noise.get_noise_2d(x, z) * ROAD_FRAY * window
	return smoothstep(0.0, ROAD_FADE_SHARPNESS, t)


## True on sealed tarmac -- inside the paved half-width, and not out past the
## eastern terminus where the bed has degraded to gravel. Everything else
## (shoulder, wild terrain, the unsealed run) is footing for gravel/sand SFX,
## not asphalt.
func is_paved_road(x: float, z: float) -> bool:
	if absf(road_offset(x, z)) > ROAD_HALF_WIDTH:
		return false
	return road_presence(x, z) >= 0.5


## 0.0 = dead centre of the road, 1.0 = fully wild terrain.
func road_blend(x: float, z: float) -> float:
	var lateral := smoothstep(ROAD_HALF_WIDTH, ROAD_HALF_WIDTH + ROAD_SHOULDER,
		absf(road_offset(x, z)))
	# East of the terminus the corridor stops being graded and the land closes
	# back over it. lerp toward 1.0 = toward fully wild.
	return lerpf(1.0, lateral, road_presence(x, z))


## Height of the road surface, following the broad swells of the plain but
## ignoring gullies and buttes -- which is what cut-and-fill actually does.
## The plain noise is low frequency, so the grade is gentle by construction and
## needs no integration pass to keep it sane.
func road_height(x: float) -> float:
	var cz := road_center(x)
	var h := _plain_noise.get_noise_2d(x, cz) * PLAIN_AMPLITUDE * ROAD_GRADE_SCALE
	return h + _road_noise.get_noise_1d(x) * ROAD_ROLL


## Flat treads with steep risers -- the stratified erosion profile that makes
## badlands read as badlands rather than as generic hills.
func _terrace(h: float) -> float:
	var band := h / TERRACE_STEP
	var index := floorf(band)
	var frac := band - index
	var lo := 0.5 - TERRACE_SHARPNESS * 0.5
	var hi := 0.5 + TERRACE_SHARPNESS * 0.5
	var stepped := (index + smoothstep(lo, hi, frac)) * TERRACE_STEP
	# Relax back toward the unstepped height. This is what turns a cut
	# staircase into a weathered slope with the ledges still legible in it.
	return lerpf(stepped, h, WEATHERING)


## How exposed the bedrock is here, 0..1. Drives both shape and colour.
func butte_mask(x: float, z: float) -> float:
	var region := _region_noise.get_noise_2d(x, z)
	var m := smoothstep(BUTTE_THRESHOLD, BUTTE_THRESHOLD + 0.30, region)
	# Grade formations down as they approach the road, so the highway runs
	# through a valley rather than a slot cut with vertical walls.
	var edge := ROAD_HALF_WIDTH + ROAD_SHOULDER
	var clearance := smoothstep(edge, edge + BUTTE_ROAD_CLEARANCE,
		absf(road_offset(x, z)))
	# Past the terminus there is nothing to keep clear, so formations close in.
	return m * lerpf(1.0, clearance, road_presence(x, z))


func wild_height(x: float, z: float) -> float:
	var h := _plain_noise.get_noise_2d(x, z) * PLAIN_AMPLITUDE

	# Gullies: ridged noise inverted, so channels cut down into the flats.
	var ridge := 1.0 - absf(_gully_noise.get_noise_2d(x, z))
	h -= pow(ridge, 3.0) * GULLY_DEPTH

	var mask := butte_mask(x, z)
	if mask > 0.001:
		# Ridged noise with a *smoothed* absolute value. Plain absf() has a
		# corner at zero, and that corner is the ridge crest -- sqrt(n*n + e)
		# rounds it into a weathered summit instead of a needle.
		var n := _butte_noise.get_noise_2d(x, z)
		var peak := 1.0 - sqrt(n * n + CREST_ROUNDING)
		peak = maxf(peak, 0.0) / (1.0 - sqrt(CREST_ROUNDING))
		peak = pow(peak, 1.8)   # broad eroded forms, not spires
		h += _terrace(peak * BUTTE_HEIGHT) * mask

	h += _detail_noise.get_noise_2d(x, z) * DETAIL_AMPLITUDE
	return h


## THE height function. Everything in the game asks this one.
func get_height(x: float, z: float) -> float:
	var t := road_blend(x, z)
	# Early out before touching road_height(). Most of the world is nowhere near
	# the road, and road_height() is the expensive branch now.
	if t >= 1.0:
		return wild_height(x, z)
	var road := road_height(x)
	if t <= 0.0:
		return road
	return lerpf(road, wild_height(x, z), t)


## Smooth normal from central differences. Because it samples the global height
## function, normals match perfectly across chunk borders (no seams).
func get_normal(x: float, z: float) -> Vector3:
	const E := 0.75
	var hl := get_height(x - E, z)
	var hr := get_height(x + E, z)
	var hd := get_height(x, z - E)
	var hu := get_height(x, z + E)
	return Vector3(hl - hr, 2.0 * E, hd - hu).normalized()


## Banded sedimentary rock, coloured by elevation.
func strata_color(x: float, z: float, y: float) -> Color:
	var warp := _strata_warp.get_noise_2d(x, z) * 2.4
	var band := (y + warp) / STRATA_THICKNESS
	var count := STRATA_COLORS.size()
	var index := int(fposmod(floorf(band), float(count)))
	var next_index := (index + 1) % count
	# Narrow blend only: bands should read as bands, not as a gradient.
	var frac := smoothstep(0.80, 1.0, band - floorf(band))
	return STRATA_COLORS[index].lerp(STRATA_COLORS[next_index], frac)


## Dry scrubland covering the flats.
func ground_color(x: float, z: float) -> Color:
	var t := _tint_noise.get_noise_2d(x, z) * 0.5 + 0.5
	var c := COLOR_GRASS_DRY.lerp(COLOR_GRASS_OLIVE, smoothstep(0.55, 0.95, t))
	return c.lerp(COLOR_SOIL, smoothstep(0.45, 0.05, t))


## Road surface including painted markings.
func _road_surface_color(x: float, z: float) -> Color:
	var d := absf(road_offset(x, z))
	var c := COLOR_ASPHALT

	# Weathering, so the tarmac isn't a flat swatch.
	var wear := _detail_noise.get_noise_2d(x * 2.0, z * 2.0) * 0.035
	c = Color(c.r + wear, c.g + wear, c.b + wear)

	# Double yellow centre line.
	if d > CENTER_LINE_INNER and d < CENTER_LINE_OUTER:
		return COLOR_LINE_YELLOW

	# White edge lines.
	var edge := ROAD_HALF_WIDTH - EDGE_LINE_INSET
	if d > edge - EDGE_LINE_WIDTH and d < edge + EDGE_LINE_WIDTH:
		return COLOR_LINE_WHITE

	return c


## Vertex colour. Takes the height and normal so callers that already computed
## them don't pay for them twice -- this runs once per terrain vertex.
func get_color(x: float, z: float, y: float, normal: Vector3) -> Color:
	var t := road_blend(x, z)
	var c: Color

	if t <= 0.0:
		c = _road_surface_color(x, z)
	else:
		# Steep faces expose banded bedrock; flats carry dry scrub. This one
		# rule produces most of the badlands look.
		var steepness := 1.0 - clampf(normal.y, 0.0, 1.0)
		var rock := smoothstep(0.10, 0.38, steepness)
		# Butte regions show rock even on their flat tops.
		rock = maxf(rock, butte_mask(x, z) * 0.55)

		var wild := ground_color(x, z).lerp(strata_color(x, z, y), rock)

		if t >= 1.0:
			c = wild
		else:
			# Shoulder: gravel verge blending out of the tarmac.
			var shoulder := _road_surface_color(x, z).lerp(COLOR_SHOULDER,
				smoothstep(0.0, 0.45, t))
			c = shoulder.lerp(wild, smoothstep(0.35, 1.0, t))

	# Alpha carries road presence to the shader. Geometry, terrain colour and
	# road surface then all fade on one shared value, computed once here --
	# nothing to keep in step across two languages.
	c.a = road_presence(x, z)
	return c
