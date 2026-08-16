extends Label

@export var player: Node3D
@export var day_night: DayNightCycle
@export var weather: WeatherSystem


func _process(_delta: float) -> void:
	if player == null:
		return
	var km_west := maxf(0.0, -player.global_position.x) / 1000.0
	var clock := day_night.get_clock_string() if day_night else "--:--"
	text = "%.3f km west | %s | %.0f°C felt %.0f°C | %s %.1f m/s from %s | humidity %.0f%%" % [
		km_west, clock,
		weather.temperature_c, weather.felt_temperature_c,
		weather.get_wind_label(), weather.wind_speed, weather.get_wind_compass(),
		weather.humidity * 100.0
	]
	
