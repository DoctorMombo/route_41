class_name CabinClimate
extends RefCounted

## The air inside an enclosed space, for anything the player can get inside of.
## One of these lives in the car; a hut or a tent would own one just the same.
##
## Simulated the way BiomeWeatherState simulates the air outside -- as something
## with thermal mass chasing a target -- rather than as a fixed offset from the
## weather. That is what makes the lag work in both directions: a car parked in
## the sun is an oven with a view, and the same mass holds the day's warmth for
## a while after the ground outside has let go of it, which is what makes
## sleeping in the car worth doing.
##
## Humidity is not simulated separately. A sealed cabin holds roughly the water
## vapour it was sealed with, and heating that same air lowers its RELATIVE
## humidity -- so a baking cabin reads DRIER than the desert outside it, which
## is both correct and the opposite of what you would guess.

## Air temperature inside, Celsius.
var temperature_c: float = 20.0
## Relative humidity inside, 0..1.
var humidity: float = 0.02

## Degrees above outside air a sealed cabin reaches in full unblocked sun.
## Glass lets short-wave light in and will not let long-wave heat back out;
## 22 C over ambient is what a closed car in desert sun actually does.
var sun_gain_c: float = 22.0
## How fast the cabin air chases its target, per in-game hour. Far quicker than
## the ground outside -- a cabin is a few cubic metres of air behind glass, not
## a landscape.
var response_per_hour: float = 3.2
## The same with air moving through it. Driving with the vents open equalises
## the cabin with the outside in minutes.
var vented_response_per_hour: float = 9.0

## True until the first step, so the cabin starts at whatever the day already
## is instead of warming up from the initialiser.
var _needs_seed: bool = true


## One tick. `dt_hours` is in-game hours, `solar` is 0..1 for how much sun is
## actually landing on the roof (altitude, cloud and dust already accounted
## for), and `ventilation` is 0..1 -- 0 sealed, 1 with air moving through.
func step(dt_hours: float, outside_temp_c: float, outside_humidity: float,
		solar: float, ventilation: float) -> void:
	var vent := clampf(ventilation, 0.0, 1.0)

	# Only the sealed fraction of the cabin gets the greenhouse gain. Open it up
	# and the target collapses back onto the outside air.
	var target := outside_temp_c + sun_gain_c * clampf(solar, 0.0, 1.0) * (1.0 - vent)

	if _needs_seed:
		_needs_seed = false
		temperature_c = target

	var rate := lerpf(response_per_hour, vented_response_per_hour, vent)
	temperature_c = lerpf(temperature_c, target, 1.0 - exp(-rate * maxf(dt_hours, 0.0)))

	# Same water vapour, different air temperature. When the cabin has
	# equalised this returns the outside humidity exactly, so there is no seam
	# between the vented and sealed cases.
	var vapour_kpa := clampf(outside_humidity, 0.0, 1.0) * _saturation_kpa(outside_temp_c)
	humidity = clampf(vapour_kpa / maxf(_saturation_kpa(temperature_c), 0.0001), 0.0, 1.0)


## Force the cabin onto a given state, discarding its history. Used by the
## console so a test does not have to wait out the thermal lag.
func seed_to(temp_c: float) -> void:
	temperature_c = temp_c
	_needs_seed = false


## Saturation vapour pressure in kPa (Magnus-Tetens). Only ever used as a
## ratio between two temperatures, so the absolute units do not matter -- but
## getting the curve right is what makes the humidity swing the correct way.
static func _saturation_kpa(t_c: float) -> float:
	return 0.61094 * exp(17.625 * t_c / (t_c + 243.04))
