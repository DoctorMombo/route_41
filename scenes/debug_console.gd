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
	_commands["weather"] = _cmd_weather
	_commands["timescale"] = _cmd_timescale
	_commands["daylength"] = _cmd_daylength
	_commands["pause"] = _cmd_pause
	_commands["car"] = _cmd_car


func _cmd_help(_args: Array) -> void:
	_log("Commands:")
	_log("  help                  this list")
	_log("  clear                 clear the log")
	_log("")
	_log("[color=aqua]Weather[/color]")
	_log("  weather               current conditions")
	_log("  weather <event>       start one: %s" % ", ".join(WeatherEvent.id_list()))
	_log("  weather random        roll one the way the timer would")
	_log("  weather stop          end the running event, reset the timer")
	_log("  weather timer <h>     set hours until the next event")
	_log("  clouds <cirrus> [deck]  force cloud coverage 0..1")
	_log("  clouds off            release the override")
	_log("")
	_log("[color=aqua]Time[/color]")
	_log("  time <0..24>          jump to a time of day, in hours")
	_log("  time +<h> / -<h>      skip forward or back, weather follows")
	_log("  timescale [x]         multiplier on the passage of time")
	_log("  daylength [seconds]   real seconds per in-game day")
	_log("  pause                 freeze or unfreeze the clock")
	_log("")
	_log("[color=aqua]Car[/color]")
	_log("  car                   speed, surface, brake and cabin readout")
	_log("  car brake             toggle the parking brake")
	_log("  car here              bring the car to the player, parked")
	_log("  car flip              set it back on its wheels where it is")


func _cmd_clear(_args: Array) -> void:
	_output.clear()


func _cmd_clouds(args: Array) -> void:
	if weather == null:
		_log("[color=orange]No WeatherSystem found.[/color]")
		return
	if args.is_empty():
		_log("Usage: clouds <cirrus 0..1> [deck 0..1]   or   clouds off")
		return
	if String(args[0]).to_lower() == "off":
		weather.debug_clear_cloud_override()
		_log("Cloud override released -- back to the natural simulation.")
		return
	var cirrus := clampf(String(args[0]).to_float(), 0.0, 1.0)
	var deck := clampf(String(args[1]).to_float(), 0.0, 1.0) if args.size() > 1 else 0.0
	weather.debug_set_cloud_coverage(cirrus, deck)
	_log("Cloud coverage forced: cirrus %.0f%%, deck %.0f%%"
		% [cirrus * 100.0, deck * 100.0])


# --- weather ----------------------------------------------------------------

func _cmd_weather(args: Array) -> void:
	if weather == null:
		_log("[color=orange]No WeatherSystem found.[/color]")
		return
	if args.is_empty():
		_report_weather()
		return

	var token := String(args[0]).to_lower()
	match token:
		"random":
			var busy := weather.get_state().event
			var e := weather.trigger_random_event()
			if busy != null:
				_log("Rolled [color=aqua]%s[/color] — queued behind %s."
					% [e.display_name, busy.display_name])
			else:
				_log("Rolled [color=aqua]%s[/color]." % e.display_name)
		"stop", "off", "end":
			var s := weather.get_state()
			if s.event == null:
				_log("No weather event running.")
			else:
				var ending := s.event.display_name
				weather.clear_event()
				_log("Ended %s. Next event in %.1f h." % [ending, s.hours_to_event])
		"timer":
			if args.size() < 2:
				_log("Usage: weather timer <hours>")
				return
			var h := maxf(0.0, String(args[1]).to_float())
			weather.get_state().hours_to_event = h
			_log("Next weather event in %.1f in-game hours." % h)
		_:
			var wanted := WeatherEvent.by_id(StringName(token))
			if wanted == null:
				_log("[color=orange]Unknown event: %s[/color]  (try: %s)"
					% [token, ", ".join(WeatherEvent.id_list())])
				return
			var running := weather.get_state().event
			# Deliberately the same path the timer uses: the event blends in
			# over its own onset rather than snapping, and the timer resets
			# when it ends, exactly as if the timer had fired it.
			weather.trigger_event(StringName(token))
			if running != null:
				_log("%s is already running — [color=aqua]%s[/color] is queued "
					% [running.display_name, wanted.display_name]
					+ "behind it.")
			else:
				_log("Triggered [color=aqua]%s[/color]. It builds in over the "
					% wanted.display_name + "next in-game hour or two.")


func _report_weather() -> void:
	var s := weather.get_state()
	_log("[color=aqua]%s[/color] — %s" % [s.profile.biome_name, s.condition_name()])
	_log("  temperature  %.1f C   (feels %.1f C)"
		% [s.temperature_c, s.felt_temperature_c])
	_log("  humidity     %.1f %%" % [s.humidity * 100.0])
	_log("  wind         %.1f km/h from %s"
		% [s.wind_speed_kmh, weather.get_wind_compass()])
	_log("  cloud cover  %.1f %%   (cirrus %.0f%%, deck %.0f%%)"
		% [s.cloud_cover * 100.0, s.cirrus_cover * 100.0, s.deck_cover * 100.0])
	_log("  dust haze    %.1f %%" % [s.dust_haze * 100.0])
	_log("  exposure     sun %.2f, wind %.2f  (%s)"
		% [weather.sun_exposure, weather.wind_exposure,
			weather.get_shelter_name() if weather.is_indoors() else "outdoors"])
	if weather.is_indoors():
		_log("  you feel     %.1f C, %.1f %% humidity"
			% [weather.get_ambient_temperature_c(), weather.get_ambient_humidity() * 100.0])
	if s.event != null:
		_log("  event        %s, %s (blend %.2f)"
			% [s.event.display_name, s.phase_name(), s.event_blend])
	else:
		_log("  next event   in %.1f in-game hours" % s.hours_to_event)


# --- car --------------------------------------------------------------------

func _cmd_car(args: Array) -> void:
	var car := get_tree().get_first_node_in_group("vehicle") as Car
	if car == null:
		_log("[color=orange]No car in group 'vehicle'.[/color]")
		return

	var token := String(args[0]).to_lower() if not args.is_empty() else ""
	match token:
		"":
			_report_car(car)
		"brake", "handbrake", "park":
			car.set_parking_brake(not car.parking_brake_engaged)
			_log("Parking brake %s." % ("ON" if car.parking_brake_engaged else "OFF"))
		"here", "come":
			if player == null:
				_log("[color=orange]No player found.[/color]")
				return
			# Two metres to the player's left, facing the way they are facing --
			# beside them rather than on top of them.
			var spot := player.global_position - player.global_transform.basis.x * 2.5
			car.place_at(spot + Vector3.UP * 0.3, player.rotation.y)
			_log("Car brought to %v, parked." % car.global_position)
		"flip", "right":
			car.place_at(car.global_position + Vector3.UP * 0.8, car.rotation.y)
			_log("Car set back on its wheels.")
		_:
			_log("[color=orange]Unknown: car %s[/color]  (try: brake, here, flip)" % token)


func _report_car(car: Car) -> void:
	var surface := car.get_drive_surface()
	var footing := "tarmac" if surface >= 0.99 else ("sand" if surface <= 0.01 else "straddling the edge")
	_log("[color=aqua]Car[/color] — %.0f km/h on %s" % [car.get_speed_kmh(), footing])
	_log("  parking brake  %s" % ("ON, holding" if car.is_parked()
		else ("ON, still settling" if car.parking_brake_engaged else "OFF")))
	_log("  occupied       %s" % ("yes" if car.is_occupied() else "no"))
	_log("  wheel slip     %.2f" % car.get_wheel_slip())
	var cabin := car.get_shelter_climate()
	_log("  cabin air      %.1f C, %.1f %% humidity"
		% [cabin.temperature_c, cabin.humidity * 100.0])


# --- time -------------------------------------------------------------------

func _cmd_time(args: Array) -> void:
	if day_night == null:
		_log("[color=orange]No DayNightCycle found.[/color]")
		return
	if args.is_empty():
		_log("Now %s on day %d." % [day_night.get_clock_string(), day_night.get_day_index()])
		return

	var raw := String(args[0])
	if raw.begins_with("+") or raw.begins_with("-"):
		var sign_ := -1.0 if raw.begins_with("-") else 1.0
		var delta_h := sign_ * absf(raw.substr(1).to_float())
		day_night.days_elapsed += delta_h / 24.0
		day_night.set_time(day_night.get_day_index(),
			fposmod(day_night.days_elapsed, 1.0))
		# Weather integrates; jumping the clock without also running the
		# simulation forward would leave it standing at the temperature and
		# the event schedule of the moment before the jump.
		if weather and delta_h > 0.0:
			weather.fast_forward(delta_h)
		_log("Skipped %+.2f h — now %s on day %d."
			% [delta_h, day_night.get_clock_string(), day_night.get_day_index()])
		return

	var hours := clampf(raw.to_float(), 0.0, 24.0)
	var now := day_night.time_of_day * 24.0
	var forward := hours - now if hours >= now else hours - now + 24.0
	day_night.set_time(day_night.get_day_index(), hours / 24.0)
	if weather:
		weather.fast_forward(forward)
	_log("Time set to %s (weather advanced %.1f h)."
		% [day_night.get_clock_string(), forward])


func _cmd_timescale(args: Array) -> void:
	if day_night == null:
		_log("[color=orange]No DayNightCycle found.[/color]")
		return
	if args.is_empty():
		_log("Time scale is x%.2f — one in-game hour every %.1f real seconds."
			% [day_night.time_scale, _real_seconds_per_hour()])
		return
	var x := clampf(String(args[0]).to_float(), 0.0, 20000.0)
	day_night.time_scale = x
	_log("Time scale x%.2f — one in-game hour every %.2f real seconds."
		% [x, _real_seconds_per_hour()])


func _cmd_daylength(args: Array) -> void:
	if day_night == null:
		_log("[color=orange]No DayNightCycle found.[/color]")
		return
	if args.is_empty():
		_log("A full day takes %.0f real seconds at time scale x%.2f."
			% [day_night.solar_day_seconds / maxf(day_night.time_scale, 0.0001),
				day_night.time_scale])
		return
	var s := maxf(1.0, String(args[0]).to_float())
	day_night.solar_day_seconds = s
	_log("Solar day set to %.0f real seconds (at time scale x%.2f)."
		% [s, day_night.time_scale])


func _cmd_pause(_args: Array) -> void:
	if day_night == null:
		_log("[color=orange]No DayNightCycle found.[/color]")
		return
	day_night.paused = not day_night.paused
	_log("Clock %s." % ("paused — weather is frozen too" if day_night.paused else "running"))


func _real_seconds_per_hour() -> float:
	var hps := day_night.get_hours_per_second()
	return INF if hps <= 0.0 else 1.0 / hps


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
