extends Area3D

## Interact trigger placed at the driver's door. Forwards to the parent Car
## so Player's generic "look at an interactable, press Enter" flow doesn't
## need to know anything about vehicles specifically.

@onready var car: Car = get_parent()


func get_interact_prompt() -> String:
	return car.get_interact_prompt()


func interact(player: CharacterBody3D) -> void:
	car.interact(player)
