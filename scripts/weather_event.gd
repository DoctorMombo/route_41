class_name WeatherEvent
extends RefCounted

## One kind of weather event, as data.
##
## An event never sets the weather directly. It publishes *targets* -- a wind
## band, a cloud deck, a temperature offset -- and BiomeWeatherState blends
## from the biome's ordinary conditions toward them across `onset_hours`, holds
## for `sustain_hours`, then blends back across `fade_hours`. That is what
## makes weather arrive and leave instead of snapping.
##
## Values of -1.0 mean "leave this alone, keep the ordinary simulation".
##
## Ranges are Vector2(min, max) and are rolled once, at the moment the event
## triggers, so no two storms are the same length or the same strength.

enum Kind {
	CLEAR,       ## not an event -- the absence of one
	OVERCAST,
	WINDY,
	STORM,
	CALM,
	DUST_STORM,
}

var kind: Kind = Kind.CLEAR
## Lowercase token used by the debug console and by in-game items.
var id: StringName = &"clear"
var display_name: String = "Clear"

# --- shape in time ----------------------------------------------------------

## In-game hours to blend from ordinary conditions up to full strength.
var onset_hours := Vector2(1.0, 2.0)
## In-game hours held at full strength.
var sustain_hours := Vector2(4.0, 8.0)
## In-game hours to blend back down to ordinary conditions.
var fade_hours := Vector2(1.5, 3.0)

# --- targets ----------------------------------------------------------------

## Wind band in km/h while the event is at full strength. (-1, -1) = ordinary.
var wind_kmh := Vector2(-1.0, -1.0)
## Coverage 0..1 of the low, solid deck at full strength. -1 = ordinary (none).
var deck_cover: float = -1.0
## Coverage 0..1 of the high cirrus at full strength. -1 = ordinary.
var cirrus_cover: float = -1.0
## Added to relative humidity at full strength (absolute, not a multiplier).
var humidity_bonus: float = 0.0
## Added to the temperature target in Celsius at full strength.
var temp_offset_c: float = 0.0

# --- lightning --------------------------------------------------------------

## Seconds between flashes inside the cloud deck. (0,0) = no in-cloud lightning.
var cloud_flash_seconds := Vector2(0.0, 0.0)
## Seconds between bolts that reach the ground. (0,0) = no ground strikes.
var ground_strike_seconds := Vector2(0.0, 0.0)

# --- dust -------------------------------------------------------------------

## Airborne dust 0..1 at full strength. Unlike everything else this does NOT
## fade with the event -- once the air is full of dust it stays full and thins
## out on its own clock (see dust_clear_hours).
var dust: float = 0.0
## In-game hours for the haze to thin from full to clear once the wind drops.
var dust_clear_hours := Vector2(12.0, 20.0)

# --- selection --------------------------------------------------------------

## Relative odds of this event being the one the timer picks.
var weight: float = 1.0


## Every event the weather timer can roll, in the order they should be listed.
static func library() -> Array[WeatherEvent]:
	var out: Array[WeatherEvent] = []

	# --- Overcast: the sky closes over. Warm night, cool day. --------------
	var overcast := WeatherEvent.new()
	overcast.kind = Kind.OVERCAST
	overcast.id = &"overcast"
	overcast.display_name = "Overcast"
	overcast.onset_hours = Vector2(1.5, 3.0)
	overcast.sustain_hours = Vector2(5.0, 14.0)
	overcast.fade_hours = Vector2(2.0, 4.0)
	overcast.deck_cover = 1.0
	overcast.cirrus_cover = 0.35
	overcast.humidity_bonus = 0.015
	overcast.weight = 1.4
	out.append(overcast)

	# --- Windy: 15 to 40 km/h, per the design. -----------------------------
	var windy := WeatherEvent.new()
	windy.kind = Kind.WINDY
	windy.id = &"windy"
	windy.display_name = "Windy"
	windy.onset_hours = Vector2(0.75, 2.0)
	windy.sustain_hours = Vector2(4.0, 12.0)
	windy.fade_hours = Vector2(1.0, 3.0)
	windy.wind_kmh = Vector2(15.0, 40.0)
	windy.cirrus_cover = 0.18
	windy.weight = 1.6
	out.append(windy)

	# --- Storm: closed sky, thunder, strikes on the ground. ----------------
	var storm := WeatherEvent.new()
	storm.kind = Kind.STORM
	storm.id = &"storm"
	storm.display_name = "Thunderstorm"
	storm.onset_hours = Vector2(1.0, 2.0)
	storm.sustain_hours = Vector2(2.0, 6.0)
	storm.fade_hours = Vector2(1.5, 3.0)
	storm.wind_kmh = Vector2(12.0, 38.0)
	storm.deck_cover = 1.0
	storm.cirrus_cover = 0.6
	storm.humidity_bonus = 0.05
	storm.temp_offset_c = -6.0
	storm.cloud_flash_seconds = Vector2(2.0, 9.0)
	storm.ground_strike_seconds = Vector2(14.0, 45.0)
	storm.weight = 1.0
	out.append(storm)

	# --- Calm: dead air. Sounds harmless. Is not, at 40 C. -----------------
	var calm := WeatherEvent.new()
	calm.kind = Kind.CALM
	calm.id = &"calm"
	calm.display_name = "Calm"
	calm.onset_hours = Vector2(1.0, 2.5)
	calm.sustain_hours = Vector2(4.0, 14.0)
	calm.fade_hours = Vector2(1.0, 2.5)
	calm.wind_kmh = Vector2(0.0, 0.0)
	calm.weight = 1.2
	out.append(calm)

	# --- Dust storm: the dangerous one. ------------------------------------
	# Zero visibility, constant lightning, and a haze that outlives the wind
	# by most of a day.
	var dust_storm := WeatherEvent.new()
	dust_storm.kind = Kind.DUST_STORM
	dust_storm.id = &"dust"
	dust_storm.display_name = "Dust Storm"
	dust_storm.onset_hours = Vector2(0.4, 1.0)
	dust_storm.sustain_hours = Vector2(1.5, 5.0)
	dust_storm.fade_hours = Vector2(1.0, 2.5)
	dust_storm.wind_kmh = Vector2(30.0, 45.0)
	dust_storm.deck_cover = 0.85
	dust_storm.cirrus_cover = 0.0
	dust_storm.temp_offset_c = -3.0
	dust_storm.ground_strike_seconds = Vector2(3.0, 7.0)
	dust_storm.cloud_flash_seconds = Vector2(2.0, 5.0)
	dust_storm.dust = 1.0
	dust_storm.dust_clear_hours = Vector2(12.0, 20.0)
	dust_storm.weight = 0.8
	out.append(dust_storm)

	return out


static func by_id(token: StringName) -> WeatherEvent:
	for e in library():
		if e.id == token:
			return e
	return null


static func id_list() -> PackedStringArray:
	var out := PackedStringArray()
	for e in library():
		out.append(String(e.id))
	return out
