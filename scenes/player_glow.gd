extends OmniLight3D

## Faint body light so a player with no lamp can still feel their way.
##
## Squared falloff against light level means it stays completely out of the way
## until the world is genuinely dark. Crucially it reads the light level
## *after* weather: inside a dust storm the sun can be high overhead and the
## world still pitch dark, and that is exactly the moment this light matters.

## Left empty, found via the "day_night" group.
@export var day_night: DayNightCycle
## Left empty, found via the "weather" group. Optional -- without it the glow
## simply falls back to sun and moon alone.
@export var weather: WeatherSystem
@export var max_energy: float = 0.7


func _ready() -> void:
	if day_night == null:
		day_night = get_tree().get_first_node_in_group("day_night") as DayNightCycle
	if weather == null:
		weather = get_tree().get_first_node_in_group("weather") as WeatherSystem


func _process(_delta: float) -> void:
	if day_night == null:
		return
	var level := weather.get_effective_light_level() if weather \
		else day_night.get_light_level()
	var dark := 1.0 - level
	light_energy = max_energy * pow(dark, 2.0)
	visible = light_energy > 0.005
