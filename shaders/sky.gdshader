shader_type sky;

#include "res://shaders/clouds.gdshaderinc"

// ============================================================================
// ROUTE 41 -- sky
// Atmosphere gradient, twilight glow, sun disk, phase-lit moon, a rotating
// starfield and two procedural cloud decks, all in a single sky pass. No
// geometry, no draw calls.
// Most uniforms here are driven by day_night_cycle.gd; cloud coverage and
// drift come from weather_system.gd. Defaults exist only so the shader looks
// sane before either script runs.
// ============================================================================

group_uniforms Atmosphere;
uniform vec3 day_zenith : source_color = vec3(0.090, 0.320, 0.750);
uniform vec3 day_horizon : source_color = vec3(0.570, 0.740, 0.930);
uniform vec3 night_zenith : source_color = vec3(0.004, 0.007, 0.022);
uniform vec3 night_horizon : source_color = vec3(0.020, 0.030, 0.065);
uniform float horizon_falloff : hint_range(1.0, 12.0) = 4.0;

group_uniforms Twilight;
// Sampled off the reference photos: hot yellow-white at the sun, orange
// through the middle of the band, dull red-violet at the far edge.
uniform vec3 glow_core : source_color = vec3(1.00, 0.74, 0.34);
uniform vec3 glow_mid : source_color = vec3(0.98, 0.34, 0.09);
uniform vec3 glow_far : source_color = vec3(0.30, 0.11, 0.13);
uniform float glow_strength : hint_range(0.0, 5.0) = 1.7;
uniform float glow_band_tightness : hint_range(1.0, 24.0) = 7.0;
uniform float glow_azimuth_spread : hint_range(0.5, 16.0) = 3.0;
uniform float glow_ambient_ring : hint_range(0.0, 1.0) = 0.22;

group_uniforms Sun;
uniform vec3 sun_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 sun_disk_color : source_color = vec3(1.0, 0.96, 0.88);
uniform float sun_angular_radius : hint_range(0.002, 0.10) = 0.0075;
uniform float sun_disk_energy : hint_range(0.0, 40.0) = 14.0;
uniform float sun_corona : hint_range(0.0, 2.0) = 0.55;

group_uniforms Moon;
uniform sampler2D moon_albedo : source_color, filter_linear_mipmap;
uniform vec3 moon_direction = vec3(0.0, -1.0, 0.0);
uniform vec3 moon_right = vec3(1.0, 0.0, 0.0);
uniform vec3 moon_up = vec3(0.0, 1.0, 0.0);
uniform float moon_angular_radius : hint_range(0.002, 0.10) = 0.0082;
uniform float moon_energy : hint_range(0.0, 8.0) = 1.7;
uniform float moon_earthshine : hint_range(0.0, 0.3) = 0.025;
// 0 = night (opaque, high contrast), 1 = full daylight (pale, lit limb only).
uniform float moon_washout : hint_range(0.0, 1.0) = 0.0;

group_uniforms Clouds;
// In-game days elapsed, pushed every frame by WeatherSystem. Feeds the fbm
// swirl and the region field's own drift, so the field genuinely evolves
// instead of only translating with the wind-driven offset below.
uniform float cloud_time = 0.0;
// How hard the puff shape is domain-warped. Always on now -- clouds roil a
// little even on a calm day, not only during weather events.
uniform float cloud_turbulence : hint_range(0.0, 2.0) = 0.35;
// Softness of a region's outer edge.
uniform float cloud_region_edge : hint_range(0.02, 0.6) = 0.22;
uniform float cloud_absorption : hint_range(0.1, 10.0) = 3.2;
uniform float cloud_light_step : hint_range(0.0, 0.3) = 0.05;
uniform float cloud_opacity : hint_range(0.0, 1.0) = 0.92;
uniform vec3 cloud_shade_color : source_color = vec3(0.40, 0.46, 0.60);
uniform vec3 cloud_sun_color : source_color = vec3(1.0, 0.96, 0.90);
// Kept alive past sunset by DayNightCycle, so cloud bases still catch the last
// light after the sun itself has gone.
uniform float cloud_sun_energy : hint_range(0.0, 4.0) = 1.0;
uniform vec3 cloud_moon_color : source_color = vec3(0.55, 0.62, 0.85);
// Dim: clouds reflecting moonlight should read as a faint blue-grey glow at
// the edges, not a second sun.
uniform float cloud_moon_energy : hint_range(0.0, 1.0) = 0.0;

group_uniforms CloudsHigh;
// Thin, high, wind-scoured deck. In the desert this rarely covers more than a
// tenth of the sky.
uniform float cloud_hi_coverage : hint_range(0.0, 1.0) = 0.0;
// Wind-driven scroll, in uv units. Pushed by WeatherSystem.
uniform vec2 cloud_hi_offset = vec2(0.0);
uniform float cloud_hi_altitude : hint_range(200.0, 12000.0) = 2600.0;
// Radius of the shell the layer sits on. Deliberately far smaller than a real
// planet: it is what bounds how far toward the horizon the layer reaches, and
// so how many times the tile repeats. Smaller curves harder.
uniform float cloud_hi_curvature_radius : hint_range(5000.0, 400000.0) = 45000.0;
// World metres to uv. One uv unit is 1.0 / cloud_hi_scale metres of sky.
uniform float cloud_hi_scale : hint_range(0.00005, 0.01) = 0.00016;
// Scale of the region mask relative to the puffs. Well below 1.0, so cloud
// regions are much larger than the puffs that fill them.
uniform float cloud_hi_region_scale : hint_range(0.02, 1.0) = 0.20;
// Higher than the low deck's -- thin and sparse rather than a solid sheet.
uniform float cloud_hi_shape_floor : hint_range(0.0, 0.9) = 0.52;
// Stretched hard along one axis: this is what turns a round puff into a
// wispy cirrus streak.
uniform vec2 cloud_hi_stretch = vec2(3.2, 1.0);

group_uniforms CloudsLow;
// Lower, puffier deck. Sitting closer and moving faster than the high layer
// is what reads as parallax and gives the sky a sense of depth.
uniform float cloud_lo_coverage : hint_range(0.0, 1.0) = 0.0;
uniform vec2 cloud_lo_offset = vec2(0.0);
uniform float cloud_lo_altitude : hint_range(100.0, 6000.0) = 900.0;
uniform float cloud_lo_curvature_radius : hint_range(5000.0, 400000.0) = 30000.0;
uniform float cloud_lo_scale : hint_range(0.00005, 0.02) = 0.00034;
uniform float cloud_lo_region_scale : hint_range(0.02, 1.0) = 0.30;
// Lower than the high deck's -- fills in to solid, rounded lumps.
uniform float cloud_lo_shape_floor : hint_range(0.0, 0.9) = 0.24;
// Round: no stretch. This is the fat, puffy cumulus-style deck.
uniform vec2 cloud_lo_stretch = vec2(1.0, 1.0);

group_uniforms Lightning;
// A flash inside the cloud deck. LightningDirector picks the direction and
// pulses the energy; the deck lights up from the inside rather than being
// washed over from outside, which is what reads as lightning in cloud rather
// than as the whole screen flickering.
uniform vec3 flash_direction = vec3(0.0, 1.0, 0.0);
uniform vec3 flash_color : source_color = vec3(0.78, 0.85, 1.0);
uniform float flash_energy : hint_range(0.0, 12.0) = 0.0;
// How tightly the flash is localised around its direction. Low values light
// the whole deck faintly, which is what a distant flash behind cloud does.
uniform float flash_focus : hint_range(1.0, 64.0) = 7.0;

group_uniforms Dust;
// Airborne dust, 0..1. Composited over everything -- sun disk, moon, stars,
// cloud -- because that is exactly what a dust storm does to a sky.
uniform float dust_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec3 dust_color : source_color = vec3(0.60, 0.42, 0.24);
// How brightly the dust is lit from above. Driven by WeatherSystem from the
// day/night light level, so the same wall of dust is a glowing tan by day and
// very nearly black at night.
uniform float dust_light : hint_range(0.0, 4.0) = 1.0;

group_uniforms Stars;
uniform sampler2D star_field : source_color, filter_linear;
uniform vec3 star_pole = vec3(0.0, 1.0, 0.0);
uniform float star_angle = 0.0;
uniform float star_energy : hint_range(0.0, 6.0) = 1.0;
// How strongly local sky brightness erases stars. Higher = the horizon glow
// clears a wider band of sky, which is what real twilight does.
uniform float star_glow_washout : hint_range(0.0, 12.0) = 5.0;

const float TAU_ = 6.28318530718;
const float PI_ = 3.14159265359;


vec2 equirect_uv(vec3 d) {
	return vec2(0.5 + atan(d.x, -d.z) / TAU_,
	            0.5 - asin(clamp(d.y, -1.0, 1.0)) / PI_);
}

// One cloud deck: intersects the view ray with the shell it sits on, samples
// its density, and lights it from both the sun and the moon. Returns
// (colour, alpha) so the caller composites decks back-to-front.
vec4 cloud_layer(vec3 d, vec3 sun_dir, vec3 moon_dir, float day,
		float altitude, float curvature_radius, float scale, vec2 offset,
		float coverage, float region_scale, float shape_floor, vec2 stretch) {
	// The layer sits on a shell, not a flat plane. A plane divides by d.y, so
	// its uv derivative runs to infinity at the horizon -- the field gets
	// sampled far below Nyquist and moires into radial streaks. Intersecting a
	// sphere instead bounds the distance.
	float ry = max(d.y, 0.0);
	float b = curvature_radius * ry;
	float ray = -b + sqrt(b * b + 2.0 * curvature_radius * altitude + altitude * altitude);
	vec2 uv = d.xz * ray * scale + offset;

	// Same singularity, felt one derivative earlier: right at the horizon the
	// warp would be displacing samples across a wildly undersampled region,
	// which is what turns fine turbulence into visible aliasing there.
	float horizon_fade = smoothstep(-0.05, 0.25, d.y);

	float cd = cloud_density(uv, cloud_time, coverage, region_scale,
		cloud_region_edge, shape_floor, cloud_turbulence, stretch, horizon_fade);
	if (cd <= 0.001) {
		return vec4(0.0);
	}

	// Beer's law along the sun and moon directions, sampled within the layer.
	// With a body overhead its .xz collapses toward zero and the lighting
	// flattens, which is what actually happens when the light source is
	// directly above the cloud.
	float cd_sun = cloud_density(uv + sun_dir.xz * cloud_light_step, cloud_time,
		coverage, region_scale, cloud_region_edge, shape_floor, cloud_turbulence,
		stretch, horizon_fade);
	float transmit_sun = exp(-cd_sun * cloud_absorption);

	float cd_moon = cloud_density(uv + moon_dir.xz * cloud_light_step, cloud_time,
		coverage, region_scale, cloud_region_edge, shape_floor, cloud_turbulence,
		stretch, horizon_fade);
	float transmit_moon = exp(-cd_moon * cloud_absorption);

	vec3 col = cloud_shade_color * mix(0.10, 1.0, day)
	         + cloud_sun_color * cloud_sun_energy * transmit_sun
	         + cloud_moon_color * cloud_moon_energy * transmit_moon;

	// Lightning lights the cloud from within: a bright core where the bolt is
	// and a weaker glow across the rest of the deck, since the whole underside
	// catches some of it.
	if (flash_energy > 0.001) {
		float near_bolt = pow(max(dot(d, normalize(flash_direction)), 0.0), flash_focus);
		col += flash_color * flash_energy * (0.20 + 0.80 * near_bolt);
	}

	// Fade out at the horizon: the shell projection goes singular there and
	// would otherwise smear into a grey band.
	float a = cd * cloud_opacity * smoothstep(-0.01, 0.09, d.y);
	return vec4(col, clamp(a, 0.0, 1.0));
}


// Rodrigues rotation -- used to spin the star sphere about the celestial pole.
vec3 rotate_about(vec3 v, vec3 axis, float a) {
	float c = cos(a);
	float s = sin(a);
	return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}


void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 sun_dir = normalize(sun_direction);
	vec3 moon_dir = normalize(moon_direction);
	float sun_alt = sun_dir.y;

	// ---- base atmosphere gradient ------------------------------------------
	float day = smoothstep(-0.14, 0.22, sun_alt);
	vec3 zenith = mix(night_zenith, day_zenith, day);
	vec3 horizon = mix(night_horizon, day_horizon, day);
	float band = pow(1.0 - clamp(abs(d.y), 0.0, 1.0), horizon_falloff);
	vec3 col = mix(zenith, horizon, band);

	// ---- twilight glow ------------------------------------------------------
	// Computed before the stars so it can wash them out locally.
	// Asymmetric falloff: fades quickly as the sun climbs, lingers as it sinks,
	// so the afterglow behaves like real civil twilight.
	float s = sun_alt - 0.02;
	float sigma = s > 0.0 ? 0.13 : 0.20;
	float twilight = exp(-(s * s) / (sigma * sigma));

	// Guard the horizontal projection properly. A "+ 1e-5" trick does not
	// remove the normalize(0) singularity, it relocates it to the direction
	// where d.x and d.z both equal -1e-5 -- producing a NaN along one azimuth.
	vec2 dxz = vec2(d.x, d.z);
	vec2 sxz = vec2(sun_dir.x, sun_dir.z);
	float dl = max(length(dxz), 1e-4);
	float sl = max(length(sxz), 1e-4);
	// clamp before pow(): a base even fractionally below zero also returns NaN.
	float azim = pow(clamp(dot(dxz / dl, sxz / sl) * 0.5 + 0.5, 0.0, 1.0), glow_azimuth_spread);
	float glow_band = pow(1.0 - clamp(abs(d.y), 0.0, 1.0), glow_band_tightness);

	float ang = acos(clamp(dot(d, sun_dir), -1.0, 1.0));
	vec3 gcol = mix(glow_core, glow_mid, smoothstep(0.05, 0.55, ang));
	gcol = mix(gcol, glow_far, smoothstep(0.45, 1.50, ang));

	// Weak all-round warming of the horizon -- the sky reddens everywhere at
	// sunset, not only where the sun is.
	vec3 glow_add = gcol * (twilight * glow_strength * glow_band * azim)
	              + glow_far * (twilight * glow_band * glow_ambient_ring);

	// ---- stars --------------------------------------------------------------
	// Two separate fades. Altitude: none at civil twilight (-6 deg), full by
	// astronomical twilight (-18 deg) -- matching when stars actually appear.
	// Local: bright sky erases stars in front of it, so the horizon glow clears
	// its own patch while the zenith still shows them.
	float star_fade = 1.0 - smoothstep(-0.31, -0.10, sun_alt);
	float local_wash = 1.0 - clamp(dot(glow_add, vec3(0.4)) * star_glow_washout, 0.0, 1.0);
	vec3 sd = rotate_about(d, normalize(star_pole), star_angle);
	col += texture(star_field, equirect_uv(sd)).rgb * star_energy * star_fade * local_wash;

	col += glow_add;

	// ---- sun disk and corona -------------------------------------------------
	float sun_cos = dot(d, sun_dir);
	float sun_ang = acos(clamp(sun_cos, -1.0, 1.0));
	float disk = 1.0 - smoothstep(sun_angular_radius * 0.90,
	                              sun_angular_radius * 1.06, sun_ang);
	// Tight term survives an eclipse as a corona ring; wide term is ordinary
	// daytime glare around the sun.
	float corona = pow(max(sun_cos, 0.0), 1400.0) * sun_corona
	             + pow(max(sun_cos, 0.0), 90.0) * 0.10 * day;
	col += sun_disk_color * (disk * sun_disk_energy + corona);

	// ---- moon ---------------------------------------------------------------
	vec3 mr = normalize(moon_right);
	vec3 mu = normalize(moon_up);
	float inv_r = 1.0 / max(sin(moon_angular_radius), 1e-6);
	float mx = dot(d, mr) * inv_r;
	float my = dot(d, mu) * inv_r;
	float r2 = mx * mx + my * my;
	float r = sqrt(r2);

	float aa = clamp(fwidth(r) * 1.2, 0.002, 0.25);
	// step() kills the phantom disk that the projection produces at the
	// antipode, where mx and my both collapse to zero.
	float cover = (1.0 - smoothstep(1.0 - aa, 1.0, r)) * step(0.0, dot(d, moon_dir));

	float mz = sqrt(max(0.0, 1.0 - min(r2, 1.0)));
	vec3 n = mx * mr + my * mu - mz * moon_dir;   // surface normal, near side

	// Tidally locked: the body frame is (right, up, away-from-viewer), so the
	// same face is always turned toward the planet.
	vec3 nb = vec3(dot(n, mr), dot(n, mu), dot(n, moon_dir));
	vec2 muv = vec2(0.5 + atan(nb.x, -nb.z) / TAU_,
	                0.5 - asin(clamp(nb.y, -1.0, 1.0)) / PI_);
	vec3 albedo = texture(moon_albedo, muv).rgb;

	// True phase: the terminator falls where the moon's own surface turns away
	// from the sun, so it curves correctly and eclipses come out for free.
	float lambert = dot(n, sun_dir);
	float lit = smoothstep(-0.05, 0.12, lambert);
	float limb = mix(1.0, 0.80, clamp(r2, 0.0, 1.0));

	vec3 night_moon = albedo * (lit + moon_earthshine * (1.0 - lit)) * moon_energy * limb;

	// Daylight: pale and low-contrast, and only the lit limb reads at all --
	// the dark limb dissolves into the sky, as in the reference photo.
	vec3 pale = mix(col, vec3(1.0), 0.62) * mix(0.92, 1.10, lit);
	pale *= mix(vec3(1.0), albedo * 1.5 + 0.5, 0.30);

	vec3 moon_col = mix(night_moon, pale, moon_washout);
	float moon_alpha = cover * mix(1.0, lit * 0.92 + 0.08, moon_washout);

	// mix() rather than add: the moon is opaque, so it occludes the sun disk
	// and the inner corona during an eclipse.
	col = mix(col, moon_col, moon_alpha);

	// ---- cloud decks, back to front ------------------------------------------
	// The high deck is farther away, so it is drawn first; the low deck sits
	// in front of it and is composited on top, which is what gives the sky its
	// sense of depth when the two drift at different rates.
	vec4 hi = cloud_layer(d, sun_dir, moon_dir, day,
		cloud_hi_altitude, cloud_hi_curvature_radius, cloud_hi_scale, cloud_hi_offset,
		cloud_hi_coverage, cloud_hi_region_scale, cloud_hi_shape_floor, cloud_hi_stretch);
	vec4 lo = cloud_layer(d, sun_dir, moon_dir, day,
		cloud_lo_altitude, cloud_lo_curvature_radius, cloud_lo_scale, cloud_lo_offset,
		cloud_lo_coverage, cloud_lo_region_scale, cloud_lo_shape_floor, cloud_lo_stretch);
	col = mix(col, hi.rgb, hi.a);
	col = mix(col, lo.rgb, lo.a);

	// ---- dust ---------------------------------------------------------------
	// Last, and over everything. Dust is between the viewer and the whole sky,
	// so it hides the sun disk, the moon, the stars and the cloud alike -- at
	// full strength there is no sky left, only the colour of the air.
	if (dust_amount > 0.001) {
		vec3 dust = dust_color * dust_light + flash_color * flash_energy * 0.5;
		col = mix(col, dust, clamp(dust_amount, 0.0, 1.0));
	}

	// NaN never escapes into the radiance map. x != x is only true for NaN.
	col.r = (col.r == col.r) ? col.r : 0.0;
	col.g = (col.g == col.g) ? col.g : 0.0;
	col.b = (col.b == col.b) ? col.b : 0.0;
	COLOR = col;
}
