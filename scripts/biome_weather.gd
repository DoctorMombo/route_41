class_name BiomeWeather
extends Resource

## The weather envelope for one biome, expressed as sliders.
##
## Temperature, wind speed, wind direction and humidity drive survival; cloud
## cover rides alongside them as its own pair of dials. A new biome is a new
## resource -- the simulation never needs to know which one it is running.

@export var biome_name: String = "Desert"

@export_group("Temperature")
## Peak air temperature, reached mid-afternoon (see temperature_lag_hours).
@export var temp_day_c: float = 40.0
## Coldest air temperature, reached just before dawn.
@export var temp_night_c: float = -20.0
## Hours the ground lags the sun. Rock and sand heat and cool slowly, so peak
## temperature lands mid-afternoon and the minimum just before dawn.
@export_range(0.0, 6.0) var temperature_lag_hours: float = 2.5

@export_group("Wind Chill")
## Felt-temperature drop per sqrt(m/s) of wind when the air is at its coldest.
## Large: this is what makes a cold night feel frigid.
@export var wind_chill_cold_per_ms: float = 2.6
## Felt-temperature drop per sqrt(m/s) of wind when the air is at its hottest.
## Small: wind still cools a hot day, just far less dramatically.
@export var wind_chill_hot_per_ms: float = 0.7

@export_group("Wind Speed")
## Metres per second on a still day.
@export var wind_calm: float = 0.4
## The strongest ordinary wind.
@export var wind_strong: float = 14.0
## In-game days per cycle of the slow wind regime (calm spells vs. blowy ones).
@export var wind_regime_days: float = 1.8
## In-game days per gust cycle. Small: gusts are seconds, not hours.
@export var wind_gust_days: float = 0.05

@export_group("Wind Direction")
## In-game days for the prevailing direction to wander right round. Direction
## is otherwise random -- this just paces how fast it drifts.
@export var wind_bearing_days: float = 4.0

@export_group("Humidity")
## Relative humidity on the driest hour. The desert is arid.
@export_range(0.0, 0.05) var humidity_min: float = 0.01
## Relative humidity on the most humid hour -- never above 5% in the desert.
@export_range(0.0, 0.05) var humidity_max: float = 0.05
## In-game days per cycle of humidity wandering between the two.
@export var humidity_period_days: float = 3.0

@export_group("Clouds")
## Fraction of sky the high, thin deck reaches at its thickest. The desert
## rarely sees more than a tenth of the sky occupied.
@export_range(0.0, 1.0) var cloud_high_max: float = 0.10
## Fraction of sky the lower, puffier deck reaches at its thickest.
@export_range(0.0, 1.0) var cloud_low_max: float = 0.06
## In-game days per cycle of cloud cover building up and clearing again.
@export var cloud_period_days: float = 0.6
## How much a sky full of cloud dims the direct sun and moon light reaching
## the ground -- the gameplay-visible half of "clouds block the sun".
@export_range(0.0, 1.0) var cloud_shadow_strength: float = 0.35
