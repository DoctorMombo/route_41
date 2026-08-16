extends OmniLight3D

## Faint body light so a player with no lamp can still feel their way at night.
## Squared falloff against light level means it stays completely out of the way
## until the world is genuinely dark.

@export var day_night: DayNightCycle
@export var max_energy: float = 0.7


func _process(_delta: float) -> void:
	if day_night == null:
		return
	var dark := 1.0 - day_night.get_light_level()
	light_energy = max_energy * pow(dark, 2.0)
	visible = light_energy > 0.005
