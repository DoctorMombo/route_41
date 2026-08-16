extends SceneTree

## Headless probe: steps BiomeWeatherState on a synthetic clock and checks the
## result against the numbers the design asks for. Run with:
##
##   godot --headless --path <project> --script res://tools/weather_probe.gd

const STEP_H := 1.0 / 60.0   # one in-game minute


func _initialize() -> void:
	var profile := BiomeWeather.new()
	var clock := DayNightCycle.new()

	_baseline(profile, clock)
	_events(profile, clock)
	_dust_decay(profile, clock)

	clock.free()
	quit()


func _fresh(profile: BiomeWeather, seed_value: int) -> BiomeWeatherState:
	var s := BiomeWeatherState.new()
	s.setup(&"desert", profile, seed_value)
	# Park the timer far out so the baseline is not interrupted by a real event.
	s.hours_to_event = 1.0e9
	return s


func _clock_str(days: float) -> String:
	var tod := fposmod(days, 1.0) * 24.0
	return "%02d:%02d" % [int(tod), int(fposmod(tod, 1.0) * 60.0)]


# --- 1. an ordinary day, no events -----------------------------------------

func _baseline(profile: BiomeWeather, clock: DayNightCycle) -> void:
	print("=== BASELINE (no events, 4 days, seed 12345) ===")
	var s := _fresh(profile, 12345)
	var days := 0.0

	# Settle a day first so the integrator is not reporting its start value.
	for i in int(24.0 / STEP_H):
		days += STEP_H / 24.0
		s.step(STEP_H, days, clock.sun_altitude_at(days))

	for day in 3:
		var hi := -1e9
		var lo := 1e9
		var hi_at := 0.0
		var lo_at := 0.0
		var hum_at_lo := 0.0
		var hum_hi := 0.0
		var wind_lo := 1e9
		var wind_hi := -1e9
		var cloud_hi := -1e9

		for i in int(24.0 / STEP_H):
			days += STEP_H / 24.0
			s.step(STEP_H, days, clock.sun_altitude_at(days))
			if s.temperature_c > hi:
				hi = s.temperature_c
				hi_at = days
			if s.temperature_c < lo:
				lo = s.temperature_c
				lo_at = days
				hum_at_lo = s.humidity
			hum_hi = maxf(hum_hi, s.humidity)
			wind_lo = minf(wind_lo, s.wind_speed_kmh)
			wind_hi = maxf(wind_hi, s.wind_speed_kmh)
			cloud_hi = maxf(cloud_hi, s.cloud_cover)

		print("  day %d  high %5.1f C at %s   low %6.1f C at %s"
			% [day, hi, _clock_str(hi_at), lo, _clock_str(lo_at)])
		print("          humidity at the low %.1f%%  (peak %.1f%%)"
			% [hum_at_lo * 100.0, hum_hi * 100.0])
		print("          wind %.1f-%.1f km/h    cloud peak %.1f%%"
			% [wind_lo, wind_hi, cloud_hi * 100.0])

	print("  SPEC  high ~40 C | low -24..-18 C just before sunrise (~06:00)")
	print("        humidity at the low 5-8%% | wind 0-15 km/h | cloud 0-5%%")
	print("")


# --- 2. each event, at full strength ----------------------------------------

func _events(profile: BiomeWeather, clock: DayNightCycle) -> void:
	print("=== EVENTS (measured over each event's full-strength window) ===")
	for ev in WeatherEvent.library():
		var s := _fresh(profile, 4242)
		var days := 0.5    # start at midday so the sun is up
		# Settle, then trigger.
		for i in int(6.0 / STEP_H):
			days += STEP_H / 24.0
			s.step(STEP_H, days, clock.sun_altitude_at(days))
		s.trigger(ev)

		var wind_lo := 1e9
		var wind_hi := -1e9
		var cloud_hi := -1e9
		var dust_hi := -1e9
		var full_hours := 0.0
		var total_hours := 0.0
		while s.event != null and total_hours < 200.0:
			days += STEP_H / 24.0
			total_hours += STEP_H
			s.step(STEP_H, days, clock.sun_altitude_at(days))
			if s.phase == BiomeWeatherState.Phase.FULL:
				full_hours += STEP_H
				wind_lo = minf(wind_lo, s.wind_speed_kmh)
				wind_hi = maxf(wind_hi, s.wind_speed_kmh)
				cloud_hi = maxf(cloud_hi, s.cloud_cover)
				dust_hi = maxf(dust_hi, s.dust_haze)

		print("  %-14s ran %5.1f h (%.1f h at full)  wind %4.1f-%4.1f km/h  "
			% [ev.display_name, total_hours, full_hours, wind_lo, wind_hi]
			+ "cloud %5.1f%%  dust %5.1f%%  strikes %s"
			% [cloud_hi * 100.0, dust_hi * 100.0,
				"none" if ev.ground_strike_seconds == Vector2.ZERO
				else "%.0f-%.0f s" % [ev.ground_strike_seconds.x, ev.ground_strike_seconds.y]])
		print("      timer reset to %.1f h  (spec: 12-96)" % s.hours_to_event)
	print("  SPEC  windy 15-40 | calm 0 | dust 30-45 km/h + strikes every 3-7 s")
	print("        overcast/storm/dust: total cloud cover")
	print("")


# --- 3. the haze that outlives the storm ------------------------------------

func _dust_decay(profile: BiomeWeather, clock: DayNightCycle) -> void:
	print("=== DUST HAZE PERSISTENCE ===")
	for run in 3:
		var s := _fresh(profile, 900 + run * 31)
		var days := 0.5
		s.trigger(WeatherEvent.by_id(&"dust"))

		var storm_end := -1.0
		var haze_at_end := 0.0
		var elapsed := 0.0
		while elapsed < 400.0:
			days += STEP_H / 24.0
			elapsed += STEP_H
			s.step(STEP_H, days, clock.sun_altitude_at(days))
			if storm_end < 0.0 and s.event == null:
				storm_end = elapsed
				haze_at_end = s.dust_haze
			if storm_end >= 0.0 and s.dust_haze <= 0.001:
				break

		print("  run %d: storm lasted %.1f h; haze %.0f%% when the wind dropped; "
			% [run, storm_end, haze_at_end * 100.0]
			+ "cleared %.1f h later" % (elapsed - storm_end))
	print("  SPEC  visibility stays zero when the storm dies; haze thins over 12-20 h")
	print("")

	_timer_spread(profile)
	_cloudless(profile, clock)


## The event timer is the one number the player waits on, so check it really
## does span the range rather than clustering.
func _timer_spread(profile: BiomeWeather) -> void:
	print("=== EVENT TIMER (200 rolls) ===")
	var lo := 1e9
	var hi := -1e9
	var sum := 0.0
	var counts := [0, 0, 0, 0]
	for i in 200:
		var s := _fresh(profile, 7000 + i * 13)
		s._roll_event_timer()
		var h := s.hours_to_event
		lo = minf(lo, h)
		hi = maxf(hi, h)
		sum += h
		counts[clampi(int((h - 12.0) / 21.0), 0, 3)] += 1
	print("  range %.1f-%.1f h, mean %.1f h" % [lo, hi, sum / 200.0])
	print("  quartiles of 12-96: %s" % [counts])
	print("  SPEC  12-96 h" )
	print("")


## The spec pins the daily high to a sky with NO cloud, which the desert never
## quite has -- so force it and check the number lands where it should.
func _cloudless(profile: BiomeWeather, clock: DayNightCycle) -> void:
	print("=== CLEAR-SKY PEAK (cloud forced to zero) ===")
	var s := _fresh(profile, 12345)
	s.set_forced_clouds(0.0, 0.0)
	var days := 0.0
	for i in int(24.0 / STEP_H):
		days += STEP_H / 24.0
		s.step(STEP_H, days, clock.sun_altitude_at(days))
	var hi := -1e9
	var hi_at := 0.0
	var lo := 1e9
	var lo_at := 0.0
	for i in int(24.0 / STEP_H):
		days += STEP_H / 24.0
		s.step(STEP_H, days, clock.sun_altitude_at(days))
		if s.temperature_c > hi:
			hi = s.temperature_c
			hi_at = days
		if s.temperature_c < lo:
			lo = s.temperature_c
			lo_at = days
	print("  high %.1f C at %s   low %.1f C at %s"
		% [hi, _clock_str(hi_at), lo, _clock_str(lo_at)])
	print("  SPEC  40 C on a day with no cloud cover")
	print("")
	_midday_events(profile, clock)


## What a weather event does to the temperature at noon. The point of the
## exercise is that cloud and dust should cost a real but survivable amount of
## heat, not drop a midday desert to night-time temperatures.
func _midday_events(profile: BiomeWeather, clock: DayNightCycle) -> void:
	print("=== MIDDAY TEMPERATURE UNDER EACH EVENT ===")
	for token in [&"", &"overcast", &"storm", &"dust"]:
		var s := _fresh(profile, 12345)
		var days := 0.0
		# Run to just before noon on a clear day first, so every case starts
		# from the same hot afternoon rather than from its own history.
		while fposmod(days, 1.0) < 0.42 or days < 1.0:
			days += STEP_H / 24.0
			s.step(STEP_H, days, clock.sun_altitude_at(days))
		var before := s.temperature_c
		if token != &"":
			s.trigger(WeatherEvent.by_id(token))
		# Four hours of it, which is about a full-strength window.
		for i in int(4.0 / STEP_H):
			days += STEP_H / 24.0
			s.step(STEP_H, days, clock.sun_altitude_at(days))
		print("  %-10s noon %.1f C -> %.1f C after 4 h   (felt %.1f C, light %.0f%%)"
			% ["clear" if token == &"" else token, before, s.temperature_c,
				s.felt_temperature_c,
				(1.0 - maxf(s.cloud_cover * profile.cloud_light_block,
					s.dust_haze * profile.dust_light_block)) * 100.0])
	print("  SPEC  clouds inhibit the sun's heating; dust blocks sun/star/moonlight")
