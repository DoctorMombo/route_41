class_name DayNightCycle
extends Node3D

## Celestial clock for ROUTE 41.
##
## Drives the sun, an independently orbiting moon with real phases and
## eclipses, a rotating starfield, and the sky shader that draws all of it.
##
## In co-op this is server-authoritative: the host replicates `days_elapsed`
## and every client reproduces identical skies from it. Nothing else about the
## sky needs to cross the wire.

signal day_started(day_index: int)

@export_group("Time")
## Real seconds per in-game solar day.
@export var solar_day_seconds: float = 1200.0
@export_range(0.0, 1.0) var start_time_of_day: float = 0.28
@export var start_day: int = 0
@export var paused: bool = false

@export_group("Sky Geometry")
## Leans the sun's arc to one side so it doesn't pass through the zenith.
@export_range(-60.0, 60.0) var solar_path_tilt_degrees: float = 24.0
## Height of the celestial pole -- effectively the planet's latitude. Controls
## the axis the stars wheel around.
@export_range(0.0, 89.0) var celestial_pole_altitude_degrees: float = 42.0
## A stellar day is slightly shorter than a solar day, so constellations drift
## a little earlier each night. 1.0 disables the drift.
@export var stellar_day_ratio: float = 0.99727

@export_group("Moon Orbit")
## Days for one full phase cycle, new moon to new moon.
@export var synodic_month_days: float = 29.5
## Tilt of the moon's orbit away from the sun's path. Set to 0.0 to get an
## eclipse at every new moon -- useful for testing, wrong for play.
@export_range(0.0, 30.0) var moon_inclination_degrees: float = 5.1
## How long the orbit's tilt takes to swing right round, which is what makes
## eclipses cluster into seasons instead of never happening.
@export var node_precession_days: float = 173.0
## 0.0 = new moon at start, 0.5 = full moon at start.
@export_range(0.0, 1.0) var moon_phase_at_start: float = 0.5

@export_group("Sun")
@export var sun_energy: float = 1.35
@export var sun_angular_radius: float = 0.0075
## Light colour by sun altitude. Left to itself, a warm red-through-white ramp
## is built at startup.
@export var sun_color_gradient: Gradient

@export_group("Moon")
@export var moon_light_energy: float = 0.22
@export var moon_angular_radius: float = 0.0082
## Above 1.0 the moon dims faster than its lit fraction shrinks, which matches
## how a half moon looks far dimmer than half as bright as a full one.
@export var moon_brightness_curve: float = 1.5
@export var moon_light_color: Color = Color(0.62, 0.72, 1.0)

@export_group("Clouds")
## How brightly the sun lights the cloud layer. Separate from sun_energy: cloud
## bases keep catching light after the sun has set, which is the whole reason a
## twilight sky reads as dramatic rather than merely dark.
@export var cloud_sun_energy: float = 1.15
## How brightly the moon lights the cloud layer. Small: this should read as a
## faint blue-grey glow on the undersides of cloud near a bright moon, not a
## second sun.
@export var cloud_moon_energy: float = 0.5

@export_group("Stars")
@export var star_brightness: float = 1.0
## How much a bright moon washes the stars out.
@export_range(0.0, 1.0) var star_moon_washout: float = 0.55

@export_group("Ambient")
@export var ambient_day_color: Color = Color(0.42, 0.55, 0.78)
@export var ambient_twilight_color: Color = Color(0.55, 0.34, 0.28)
@export var ambient_night_color: Color = Color(0.05, 0.07, 0.14)
@export var ambient_day_energy: float = 1.0
@export var ambient_night_energy: float = 0.30
@export var ambient_moon_boost: float = 0.45

@export_group("Fog")
@export var fog_day_color: Color = Color(0.62, 0.75, 0.92)
@export var fog_twilight_color: Color = Color(0.72, 0.36, 0.20)
@export var fog_night_color: Color = Color(0.03, 0.04, 0.09)

@export_group("Nodes")
@export var sun: DirectionalLight3D
@export var moon: DirectionalLight3D
@export var world_environment: WorldEnvironment

## Master clock. Whole part is the day index, fraction is the time of day.
var days_elapsed: float = 0.0

# Read-only outputs other systems can poll.
var time_of_day: float = 0.0
var sun_direction: Vector3 = Vector3.UP
var moon_direction: Vector3 = Vector3.DOWN
## 0.0 at new moon, 1.0 at full moon.
var moon_illumination: float = 0.0
## 0.0 = no eclipse, 1.0 = totality.
var eclipse_coverage: float = 0.0

var _sky_material: ShaderMaterial
var _env: Environment
var _last_day: int = -1


func _ready() -> void:
	if sun_color_gradient == null:
		sun_color_gradient = _build_default_sun_gradient()

	if world_environment and world_environment.environment:
		_env = world_environment.environment
		# Ambient comes from _update_environment(), not the radiance cubemap.
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		_env.ambient_light_sky_contribution = 0.0
		if _env.sky and _env.sky.sky_material is ShaderMaterial:
			_sky_material = _env.sky.sky_material
		else:
			push_warning("DayNightCycle: sky material is not a ShaderMaterial. "
				+ "Assign sky.gdshader to the Environment's Sky.")

	days_elapsed = float(start_day) + start_time_of_day
	_apply()


func _process(delta: float) -> void:
	if not paused:
		days_elapsed += delta / maxf(solar_day_seconds, 0.001)
	_apply()


# --- public helpers ---------------------------------------------------------

func get_clock_string() -> String:
	var hours := floori(time_of_day * 24.0)
	var minutes := floori(fposmod(time_of_day * 24.0, 1.0) * 60.0)
	return "%02d:%02d" % [hours, minutes]


func get_day_index() -> int:
	return int(floor(days_elapsed))

## Sun altitude (the sine of its elevation) at an arbitrary time of day,
## without disturbing the clock. Weather uses this for thermal lag; anything
## else that needs "where was the sun N hours ago" can too.
func sun_altitude_at(tod: float) -> float:
	var theta := (fposmod(tod, 1.0) - 0.25) * TAU
	return Vector3(cos(theta), sin(theta), 0.0) \
		.rotated(Vector3.RIGHT, deg_to_rad(solar_path_tilt_degrees)).y

## Rough 0..1 estimate of how lit the world is. Moonlight is weighted well
## below sunlight because a full moon is nowhere near a quarter as bright --
## the number is for gameplay, not photometry. Sleep, spawns, stress and
## temperature will all want this later.
func get_light_level() -> float:
	var day_amount := smoothstep(-0.14, 0.22, sun_direction.y)
	var moon_amount := moon_illumination * smoothstep(-0.10, 0.14, moon_direction.y) * 0.25
	return clampf(maxf(day_amount, moon_amount), 0.0, 1.0)


## Jump the clock. `tod` is 0..1 across the day.
func set_time(day: int, tod: float) -> void:
	days_elapsed = float(day) + clampf(tod, 0.0, 1.0)
	_apply()

## The sky's ShaderMaterial. Lets other systems push their own uniforms without
## each needing its own route to the Environment.
func get_sky_material() -> ShaderMaterial:
	return _sky_material

func get_phase_name() -> String:
	# Signed elongation tells waxing from waning; the magnitude alone cannot.
	var waxing := sin(TAU * (moon_phase_at_start + days_elapsed / maxf(synodic_month_days, 0.01))) > 0.0
	var k := moon_illumination
	if k < 0.04:
		return "New Moon"
	if k > 0.96:
		return "Full Moon"
	if absf(k - 0.5) < 0.06:
		return "First Quarter" if waxing else "Last Quarter"
	if k < 0.5:
		return "Waxing Crescent" if waxing else "Waning Crescent"
	return "Waxing Gibbous" if waxing else "Waning Gibbous"


# --- internals --------------------------------------------------------------

func _apply() -> void:
	time_of_day = fposmod(days_elapsed, 1.0)

	var day_index := get_day_index()
	if day_index != _last_day:
		_last_day = day_index
		day_started.emit(day_index)

	var tilt := deg_to_rad(solar_path_tilt_degrees)

	# Sun: rises due east (+X), sets due west (-X), arc leaned by the tilt.
	var theta := (time_of_day - 0.25) * TAU
	sun_direction = Vector3(cos(theta), sin(theta), 0.0).rotated(Vector3.RIGHT, tilt)

	# Moon: same circle, but running behind the sun by the synodic elongation.
	# That single subtraction is what makes it rise about 50 minutes later each
	# day and cycle through its phases once per synodic month.
	var elongation_angle := TAU * (moon_phase_at_start
		+ days_elapsed / maxf(synodic_month_days, 0.01))
	var moon_theta := theta - elongation_angle

	# Tilt the orbital plane about a line of nodes that slowly precesses, so
	# new moons usually miss the sun and eclipses arrive in seasons.
	var node := TAU * days_elapsed / maxf(node_precession_days, 0.01)
	var node_axis := Vector3(cos(node), sin(node), 0.0)
	var m := Vector3(cos(moon_theta), sin(moon_theta), 0.0)
	m = m.rotated(node_axis, deg_to_rad(moon_inclination_degrees))
	moon_direction = m.rotated(Vector3.RIGHT, tilt)

	# True 3D separation, so orbital tilt actually affects the phase.
	var elongation := sun_direction.angle_to(moon_direction)
	moon_illumination = clampf((1.0 - cos(elongation)) * 0.5, 0.0, 1.0)

	_update_eclipse(elongation)

	var sun_alt := sun_direction.y
	var moon_alt := moon_direction.y
	var daylight := smoothstep(-0.14, 0.22, sun_alt)
	var moon_up_amount := smoothstep(-0.10, 0.14, moon_alt)

	_update_sun(sun_alt)
	_update_moon(moon_up_amount)
	_update_sky(daylight, moon_up_amount)
	_update_environment(daylight, moon_up_amount, sun_alt)


func _update_eclipse(separation: float) -> void:
	eclipse_coverage = 0.0
	var rs := sun_angular_radius
	var rm := moon_angular_radius
	if separation >= rs + rm:
		return
	var overlap := clampf((rs + rm - separation) / (2.0 * minf(rs, rm)), 0.0, 1.0)
	# A moon smaller than the sun can never reach totality -- it goes annular.
	eclipse_coverage = overlap * minf(1.0, (rm * rm) / (rs * rs))


func _update_sun(sun_alt: float) -> void:
	if sun == null:
		return
	_aim(sun, sun_direction)
	var t := clampf(inverse_lerp(-0.08, 0.35, sun_alt), 0.0, 1.0)
	sun.light_color = sun_color_gradient.sample(t)
	sun.light_energy = sun_energy \
		* smoothstep(-0.06, 0.22, sun_alt) \
		* (1.0 - eclipse_coverage * 0.97)
	sun.visible = sun.light_energy > 0.001


func _update_moon(moon_up_amount: float) -> void:
	if moon == null:
		return
	_aim(moon, moon_direction)
	moon.light_color = moon_light_color
	moon.light_energy = moon_light_energy \
		* pow(moon_illumination, moon_brightness_curve) \
		* moon_up_amount
	moon.visible = moon.light_energy > 0.0005


func _update_sky(daylight: float, moon_up_amount: float) -> void:
	if _sky_material == null:
		return

	_sky_material.set_shader_parameter("sun_direction", sun_direction)
	_sky_material.set_shader_parameter("sun_angular_radius", sun_angular_radius)
	if sun:
		_sky_material.set_shader_parameter("sun_disk_color", sun.light_color)

	# A stable frame perpendicular to the moon, used for both the disk
	# projection and the moon's own texture mapping.
	var reference := Vector3.UP
	if absf(moon_direction.dot(reference)) > 0.99:
		reference = Vector3.FORWARD
	var m_right := reference.cross(moon_direction).normalized()
	var m_up := moon_direction.cross(m_right).normalized()

	_sky_material.set_shader_parameter("moon_direction", moon_direction)
	_sky_material.set_shader_parameter("moon_right", m_right)
	_sky_material.set_shader_parameter("moon_up", m_up)
	_sky_material.set_shader_parameter("moon_angular_radius", moon_angular_radius)
	# An eclipse darkens the sky, so the washout has to lift or the moon would
	# stay pale and invisible exactly when it should read as a black disk.
	_sky_material.set_shader_parameter("moon_washout", daylight * (1.0 - eclipse_coverage))

	var pole_alt := deg_to_rad(celestial_pole_altitude_degrees)
	# North is -Z. Flip the sign on star_angle if the stars wheel backwards.
	var pole := Vector3(0.0, sin(pole_alt), -cos(pole_alt))
	var angle := -TAU * days_elapsed / maxf(stellar_day_ratio, 0.001)
	_sky_material.set_shader_parameter("star_pole", pole)
	_sky_material.set_shader_parameter("star_angle", angle)
	
	# Clouds are lit until the sun is about 11 degrees down, well past the point
	# where the directional light itself has gone to zero.
	if sun:
		_sky_material.set_shader_parameter("cloud_sun_color", sun.light_color)
	_sky_material.set_shader_parameter("cloud_sun_energy",
		cloud_sun_energy * smoothstep(-0.20, 0.10, sun_direction.y))

	# Same idea for the moon: bright and high in the sky lights the cloud
	# bases; new moon or below the horizon leaves them dark.
	if moon:
		_sky_material.set_shader_parameter("cloud_moon_color", moon.light_color)
	_sky_material.set_shader_parameter("cloud_moon_energy",
		cloud_moon_energy * moon_illumination * moon_up_amount)

	var moon_wash := moon_illumination * moon_up_amount
	_sky_material.set_shader_parameter("star_energy",
		star_brightness * (1.0 - star_moon_washout * moon_wash))


func _update_environment(daylight: float, moon_up_amount: float, sun_alt: float) -> void:
	if _env == null:
		return

	var twilight := clampf(exp(-pow((sun_alt - 0.02) / 0.18, 2.0)), 0.0, 1.0)

	# Computed here rather than sampled from the sky's radiance cubemap. Same
	# look, but deterministic frame to frame -- and identical on every client
	# in co-op, which a GPU-side radiance map is not.
	var amb := ambient_night_color.lerp(ambient_day_color, daylight)
	amb = amb.lerp(ambient_twilight_color, twilight * 0.7)
	_env.ambient_light_color = amb

	var moon_ambient := moon_illumination * moon_up_amount
	_env.ambient_light_energy = lerpf(
		ambient_night_energy + ambient_moon_boost * moon_ambient,
		ambient_day_energy, daylight) * (1.0 - eclipse_coverage * 0.9)

	var fog := fog_night_color.lerp(fog_day_color, daylight)
	fog = fog.lerp(fog_twilight_color, twilight * 0.85)
	_env.fog_light_color = fog


## Points a DirectionalLight3D so its light arrives from `dir`.
func _aim(light: DirectionalLight3D, dir: Vector3) -> void:
	# A DirectionalLight3D emits along its local -Z, so -Z must equal -dir.
	# Building the basis by hand avoids look_at()'s failure at the poles.
	var z := dir.normalized()
	var up := Vector3.UP if absf(z.y) < 0.999 else Vector3.FORWARD
	var x := up.cross(z).normalized()
	var y := z.cross(x)
	light.global_transform = Transform3D(Basis(x, y, z), Vector3.ZERO)


func _build_default_sun_gradient() -> Gradient:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.12, 0.30, 0.62, 1.0])
	g.colors = PackedColorArray([
		Color(1.00, 0.24, 0.06),  # sun on the horizon
		Color(1.00, 0.40, 0.12),
		Color(1.00, 0.62, 0.30),
		Color(1.00, 0.86, 0.68),
		Color(1.00, 0.97, 0.92),  # midday
	])
	return g
