class_name BiomeWeather
extends Resource

## The weather envelope for one biome, expressed as sliders.
##
## Everything a biome needs to weather itself lives here: how hot the sun can
## drive it, how cold it falls overnight, how the air responds, how much cloud
## it ordinarily carries, and how often events arrive. The simulation
## (BiomeWeatherState) never names a biome -- a new biome is a new resource.
##
## Defaults are the desert, which is the only biome that exists so far.

@export var biome_name: String = "Desert"

@export_group("Temperature")
## Peak air temperature on a cloudless day, reached shortly after solar noon.
## The sun drives temperature toward this; cloud cover holds it back.
@export var temp_day_c: float = 40.0
## Coldest the night can reach, rolled per night between these two. The low
## lands just before sunrise, because the ground cools continuously in the dark
## and only stops when the sun comes back.
@export var temp_night_low_c: float = -24.0
@export var temp_night_high_c: float = -18.0
## How fast the air chases a rising target, per in-game hour. High enough that
## a clear day genuinely reaches temp_day_c rather than merely approaching it.
@export_range(0.05, 3.0) var heat_response_per_hour: float = 0.75
## How fast the air chases a falling target, per in-game hour. Tuned so the
## fall from sunset takes the whole night and still lands ON the night's rolled
## floor by dawn -- at 0.34 the night ran out with the air still most of a
## degree short, which put some nights above the -18 C the desert is supposed
## to reach. Raising it further starts flattening the small hours instead of
## letting them keep falling to sunrise.
@export_range(0.05, 3.0) var cool_response_per_hour: float = 0.42
## How much of the sun's HEATING a fully clouded sky removes.
##
## Deliberately much lower than the light it blocks (cloud_light_block). Cloud
## does not merely stand between the ground and the sun -- it absorbs that
## energy and re-radiates a good share of it downward, so an overcast desert
## noon is cooler than a clear one by something like twenty degrees, not by
## forty. Driving temperature off the light figure put an overcast midday near
## freezing, which is a much bigger lever than overcast should be.
@export_range(0.0, 1.0) var cloud_sun_block: float = 0.40
## The same for full dust haze. Higher than cloud, because a dust storm really
## does collapse the daytime temperature -- but still nothing like the light it
## swallows, or a dust storm at noon would be as cold as the night.
@export_range(0.0, 1.0) var dust_sun_block: float = 0.70

## How much of the LIGHT reaching the ground a fully clouded sky removes. This
## is the visible half -- sun and moon energy, and how dark it looks.
@export_range(0.0, 1.0) var cloud_light_block: float = 0.75
## The same for full dust haze. Near total: zero visibility, by design, and the
## reason the player's own body glow becomes the only thing to navigate by.
@export_range(0.0, 1.0) var dust_light_block: float = 0.95
## Cloud also works the other way at night -- it traps heat, so an overcast
## night is much less lethal than a clear one. Degrees added to the night floor
## at full cover.
@export_range(0.0, 30.0) var cloud_night_insulation_c: float = 12.0

@export_group("Humidity")
## Relative humidity at the hottest hour. The desert is arid; heat drives what
## little moisture there is out of the air.
@export_range(0.0, 1.0) var humidity_hot: float = 0.01
## Relative humidity at the coldest hour, rolled per night between these two.
@export_range(0.0, 1.0) var humidity_cold_low: float = 0.05
@export_range(0.0, 1.0) var humidity_cold_high: float = 0.08
## Above 1.0 keeps humidity low until the temperature is genuinely falling,
## rather than rising linearly through the afternoon.
@export_range(0.5, 3.0) var humidity_curve: float = 1.4

@export_group("Wind")
## Ordinary wind band in km/h. Events override this while they run.
@export var wind_min_kmh: float = 0.0
@export var wind_max_kmh: float = 15.0
## In-game days per cycle of the slow regime -- calm spells against blowy ones.
@export var wind_regime_days: float = 1.8
## In-game days per gust cycle. Small: gusts are seconds, not hours.
@export var wind_gust_days: float = 0.04
## How much of the wind speed comes from the slow regime rather than gusting.
@export_range(0.0, 1.0) var wind_regime_share: float = 0.62
## The same during a weather event. Lower, so the wind actually ranges across
## the band the event asks for instead of sitting wherever the multi-day regime
## happens to have parked it -- and because strong wind really is gustier.
@export_range(0.0, 1.0) var wind_event_regime_share: float = 0.22
## In-game days for the prevailing direction to wander right round the compass.
@export var wind_bearing_days: float = 4.0

@export_group("Wind Chill")
## Degrees of felt-temperature lost per sqrt(m/s) of wind when the air is at
## its hottest. Small -- wind cools a hot day, but only a little.
@export var wind_chill_hot: float = 0.7
## The same at the coldest air temperature. Large: this is what turns a -21 C
## night with a 40 km/h wind into something that kills you.
@export var wind_chill_cold: float = 3.2

@export_group("Direct Sunlight")
## Degrees added to felt temperature standing in unshaded desert sun at noon
## with a clear sky. Shade removes all of it.
@export var sun_radiant_c: float = 14.0

@export_group("Clouds")
## Fraction of sky the ordinary feathery cirrus reaches at its thickest. The
## desert sky is nearly always empty; events are what close it over.
@export_range(0.0, 1.0) var cirrus_max: float = 0.05
## In-game days per cycle of the cirrus thickening and thinning again.
@export var cirrus_period_days: float = 0.6
## How much a full sky darkens the ground under it.
@export_range(0.0, 1.0) var cloud_shadow_strength: float = 0.45

@export_group("Weather Events")
## In-game hours between weather events, rolled fresh every time the timer
## resets. Also the range used when an item or a debug command forces an event.
@export var event_interval_min_hours: float = 12.0
@export var event_interval_max_hours: float = 96.0
