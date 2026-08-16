extends Label

## Debug readout for ROUTE 41.
##
## Shows the six tracked weather stats for the biome the player is standing in,
## the current condition, and how long until the next weather event. This is a
## development readout, not the shipping HUD -- it is deliberately dense.

@export var player: Node3D
@export var day_night: DayNightCycle
@export var weather: WeatherSystem

## Felt temperature this far from the air temperature counts as worth
## colouring, so a dangerous night is visible at a glance rather than read.
@export var felt_warning_delta: float = 8.0


func _process(_delta: float) -> void:
	if player == null or weather == null:
		return

	var s := weather.get_state()
	if s == null:
		return

	var km_west := maxf(0.0, -player.global_position.x) / 1000.0
	var clock := day_night.get_clock_string() if day_night else "--:--"
	var day := day_night.get_day_index() if day_night else 0

	var lines := PackedStringArray()
	lines.append("%.3f km west   Day %d  %s%s" % [
		km_west, day, clock, _rate_suffix()])
	lines.append("%s — %s%s" % [
		s.profile.biome_name.to_upper(), s.condition_name(), _phase_suffix(s)])
	lines.append("")
	lines.append("Temperature   %6.1f °C      feels %6.1f °C%s" % [
		s.temperature_c, s.felt_temperature_c, _felt_note(s)])
	lines.append("Humidity      %6.1f %%" % [s.humidity * 100.0])
	lines.append("Wind          %6.1f km/h   from %-3s  (%s)" % [
		s.wind_speed_kmh, weather.get_wind_compass(), weather.get_wind_label()])
	lines.append("Cloud cover   %6.1f %%      cirrus %.0f%% / deck %.0f%%" % [
		s.cloud_cover * 100.0, s.cirrus_cover * 100.0, s.deck_cover * 100.0])
	if s.dust_haze > 0.005:
		lines.append("Dust haze     %6.1f %%" % [s.dust_haze * 100.0])
	lines.append("")
	lines.append(_event_line(s))

	text = "\n".join(lines)


## Only shown when time is not running at its ordinary rate, so the readout
## does not carry a line that always says the same thing.
func _rate_suffix() -> String:
	if day_night == null:
		return ""
	if day_night.paused:
		return "   [PAUSED]"
	if not is_equal_approx(day_night.time_scale, 1.0):
		return "   [time x%.2f]" % day_night.time_scale
	return ""


func _phase_suffix(s: BiomeWeatherState) -> String:
	var p := s.phase_name()
	return "  (%s)" % p if p != "" else ""


## Names what is moving felt temperature away from air temperature, but only
## once the gap is big enough to matter -- a permanent annotation would just be
## noise on the line.
func _felt_note(s: BiomeWeatherState) -> String:
	var delta := s.felt_temperature_c - s.temperature_c
	if absf(delta) < felt_warning_delta:
		return ""
	if delta > 0.0:
		return "   (+%.0f direct sun)" % delta
	return "   (%.0f wind chill)" % delta


func _event_line(s: BiomeWeatherState) -> String:
	if s.event != null:
		return "Weather event: %s, %s" % [s.event.display_name, s.phase_name()]
	var h := s.hours_to_event
	if h >= 1.0:
		return "Next weather event in %.1f h" % h
	return "Next weather event in %.0f min" % (h * 60.0)
