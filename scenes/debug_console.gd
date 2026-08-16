class_name DebugConsole
extends CanvasLayer

## In-game debug console for ROUTE 41.
##
## Built entirely in code, so there is nothing to wire up in the scene --
## drop this node anywhere and it finds WeatherSystem and DayNightCycle
## through their groups, same as everything else in this project.
##
## Commands are a name -> Callable(args: Array) dictionary, so adding a new
## one is a single line in _register_commands(); nothing else here needs to
## change.

## Left empty, found via the "weather" group.
@export var weather: WeatherSystem
## Left empty, found via the "day_night" group.
@export var day_night: DayNightCycle
## Left empty, found via the "player" group. Player.gd reads WASD and mouse
## look by polling Input directly in _physics_process/_unhandled_input, which
## does not care about UI focus -- without this, typing a command would also
## walk the player into a wall. Frozen for as long as the console is open.
@export var player: Node3D

const TOGGLE_KEY := KEY_QUOTELEFT   ## the backtick / tilde key

var _panel: Control
var _output: RichTextLabel
var _entry: LineEdit
var _history: Array[String] = []
var _history_index: int = 0
var _commands: Dictionary = {}
var _player_mouse_mode := Input.MOUSE_MODE_CAPTURED


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS

	if weather == null:
		weather = get_tree().get_first_node_in_group("weather") as WeatherSystem
	if day_night == null:
		day_night = get_tree().get_first_node_in_group("day_night") as DayNightCycle
	if player == null:
		player = get_tree().get_first_node_in_group("player") as Node3D

	_register_commands()
	_build_ui()
	_panel.visible = false
	_log("ROUTE 41 debug console. Type 'help' and press enter.")


## Runs before GUI input, so the toggle key works even while the entry field
## has focus -- otherwise a focused LineEdit would just consume it as a typed
## backtick instead of letting the console close.
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and (event as InputEventKey).keycode == TOGGLE_KEY:
		_toggle()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not _panel.visible:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key_event := event as InputEventKey

	if key_event.keycode == KEY_ESCAPE:
		_toggle()
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_UP:
		_history_step(-1)
		get_viewport().set_input_as_handled()
	elif key_event.keycode == KEY_DOWN:
		_history_step(1)
		get_viewport().set_input_as_handled()


# --- commands ----------------------------------------------------------

func _register_commands() -> void:
	_commands["help"] = _cmd_help
	_commands["clear"] = _cmd_clear
	_commands["clouds"] = _cmd_clouds
	_commands["time"] = _cmd_time


func _cmd_help(_args: Array) -> void:
	_log("Commands:")
	_log("  help                  this list")
	_log("  clear                 clear the log")
	_log("  clouds <hi> [lo]      force cloud coverage 0..1, e.g. 'clouds 0.8'")
	_log("  clouds off            release the override, back to natural weather")
	_log("  time <0..24>          jump to a time of day, in hours")


func _cmd_clear(_args: Array) -> void:
	_output.clear()


func _cmd_clouds(args: Array) -> void:
	if weather == null:
		_log("[color=orange]No WeatherSystem found.[/color]")
		return
	if args.is_empty():
		_log("Usage: clouds <hi 0..1> [lo 0..1]   or   clouds off")
		return
	if String(args[0]).to_lower() == "off":
		weather.debug_clear_cloud_override()
		_log("Cloud override released -- back to the natural simulation.")
		return
	var hi := clampf(String(args[0]).to_float(), 0.0, 1.0)
	var lo := clampf(String(args[1]).to_float(), 0.0, 1.0) if args.size() > 1 else hi
	weather.debug_set_cloud_coverage(hi, lo)
	_log("Cloud coverage forced: high %.0f%%, low %.0f%%" % [hi * 100.0, lo * 100.0])


func _cmd_time(args: Array) -> void:
	if day_night == null:
		_log("[color=orange]No DayNightCycle found.[/color]")
		return
	if args.is_empty():
		_log("Usage: time <0..24>")
		return
	var hours := clampf(String(args[0]).to_float(), 0.0, 24.0)
	day_night.set_time(day_night.get_day_index(), hours / 24.0)
	_log("Time set to %s" % day_night.get_clock_string())


# --- plumbing ------------------------------------------------------------

func _toggle() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible:
		_entry.grab_focus()
		if player:
			player.set_physics_process(false)
			player.set_process_unhandled_input(false)
		_player_mouse_mode = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	else:
		_entry.release_focus()
		if player:
			player.set_physics_process(true)
			player.set_process_unhandled_input(true)
		Input.mouse_mode = _player_mouse_mode


## The entry field is the only focusable control in the panel, so while the
## console is open it should never actually lose focus -- but submitting a
## command does knock it out (LineEdit internals reacting to the Enter press
## that triggered this same signal). Rather than chase that, _process() below
## grabs it straight back every frame the panel is visible.
func _on_submit(text: String) -> void:
	var trimmed := text.strip_edges()
	_entry.clear()
	if trimmed.is_empty():
		return
	_history.append(trimmed)
	_history_index = _history.size()
	_log("[color=gray]> %s[/color]" % trimmed)
	_execute(trimmed)


func _process(_delta: float) -> void:
	if _panel.visible and not _entry.has_focus():
		_entry.grab_focus()


func _execute(line: String) -> void:
	var parts := line.split(" ", false)
	var command_name := parts[0].to_lower()
	# split() returns PackedStringArray; the command callables are typed to
	# take a plain Array, so convert explicitly rather than lean on implicit
	# Variant coercion through the Callable call below.
	var args: Array = Array(parts.slice(1))
	if not _commands.has(command_name):
		_log("[color=orange]Unknown command: %s[/color] (try 'help')" % command_name)
		return
	var fn: Callable = _commands[command_name]
	fn.call(args)


func _history_step(dir: int) -> void:
	if _history.is_empty():
		return
	_history_index = clampi(_history_index + dir, 0, _history.size())
	if _history_index == _history.size():
		_entry.text = ""
	else:
		_entry.text = _history[_history_index]
	_entry.caret_column = _entry.text.length()


func _log(msg: String) -> void:
	_output.append_text(msg + "\n")


func _build_ui() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_panel.custom_minimum_size = Vector2(0.0, 260.0)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.80)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 8)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	margin.add_child(vbox)

	_output = RichTextLabel.new()
	_output.custom_minimum_size = Vector2(0.0, 220.0)
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_output.scroll_following = true
	_output.bbcode_enabled = true
	_output.add_theme_color_override("default_color", Color(0.85, 0.90, 0.85))
	vbox.add_child(_output)

	_entry = LineEdit.new()
	_entry.placeholder_text = "type 'help' and press enter"
	_entry.text_submitted.connect(_on_submit)
	vbox.add_child(_entry)
