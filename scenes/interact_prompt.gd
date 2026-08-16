extends Label

## Shows the current interactable's prompt (e.g. "Press Enter to drive")
## whenever the player is looking at one.

@export var player: Node


func _process(_delta: float) -> void:
	var target: Node = player.interact_target if player else null
	if target and target.has_method("get_interact_prompt"):
		var prompt: String = target.get_interact_prompt()
		text = prompt
		visible = prompt != ""
	else:
		visible = false
