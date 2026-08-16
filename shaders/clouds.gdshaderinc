// ============================================================================
// ROUTE 41 -- procedural cloud density
//
// Shared by the sky dome (two puffy layers) and the terrain shader (the
// shadow those layers cast on the ground), so both read from the same field
// instead of an unwrapped texture asset. No baked noise texture is involved:
// everything below is a hash-based value noise, fractal-summed.
// ============================================================================

float _cloud_hash(vec2 p) {
	p = fract(p * vec2(127.1, 311.7));
	p += dot(p, p + 34.23);
	return fract(p.x * p.y);
}

float _cloud_value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = _cloud_hash(i);
	float b = _cloud_hash(i + vec2(1.0, 0.0));
	float c = _cloud_hash(i + vec2(0.0, 1.0));
	float d = _cloud_hash(i + vec2(1.0, 1.0));
	// Quintic fade (Perlin's improved curve), not the cheaper cubic
	// smoothstep. Cubic only zeroes the *first* derivative at a cell edge;
	// the second derivative still jumps, which shows up as a faint
	// grid-aligned crease once the field gets domain-warped. Quintic zeroes
	// both, which is what keeps a warped puff from picking up visible box
	// edges at the underlying noise grid's cell boundaries.
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal sum of value noise. Each octave's sample point drifts around its
// own small circle over time rather than staying fixed, so the field churns
// instead of only translating -- this is what makes cloud puffs roil in
// place rather than just drift as a rigid pattern.
//
// Earlier this rotated each octave by a turning angle instead of drifting
// it. Value noise built from a square hash grid carries a faint directional
// grain along its grid axes; rotating octaves by different angles overlays
// that grain at multiple angles at once, and superimposed grain reads as
// sharp crossing creases -- exactly the boxy line artifacts that showed up
// in-game. A translating offset animates the field without ever turning its
// grid relative to itself, so the grain from every octave stays aligned and
// the creases disappear.
float cloud_fbm(vec2 p, float swirl_time, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float freq = 1.0;
	for (int i = 0; i < octaves; i++) {
		float phase = swirl_time * (0.6 + 0.35 * float(i));
		vec2 drift = vec2(cos(phase), sin(phase)) * 0.7;
		sum += _cloud_value_noise(p * freq + drift) * amp;
		amp *= 0.5;
		freq *= 2.07;
	}
	return sum;
}

// Puffy-cloud density at `uv`, 0..1. Two roles, deliberately separated:
//
// The region field decides WHERE cloud exists, at a much larger scale than
// the puffs, and drifts on its own slow time offset -- that domain shift is
// what makes whole regions of cloud dissipate and reform, independent of
// whatever wind-driven scroll is already baked into `uv`. Thresholding the
// puff shape directly instead would keep only the bright tips of every puff
// at low coverage, which reads as scattered flecks rather than as a few
// distinct clouds.
//
// The shape field is the puffs themselves, domain-warped by a second,
// FINER noise sample -- finer than the puffs, not coarser -- so their edges
// billow instead of the whole field folding over itself in blocky lumps.
// A displacement anywhere near a full cell wide, sourced from noise coarser
// than the thing it is warping, is what actually produces boxy creases: the
// warp field's own grid boundaries get dragged along as visible seams.
//
// `stretch` anisotropically scales the shape sample only -- >1 on one axis
// draws puffs into streaks along the other, the knob that turns a round
// cumulus lump into a wispy cirrus streak. `horizon_fade` (0 at the horizon,
// 1 well above it) damps the warp there: the sky dome's shell projection
// makes uv change fastest per pixel right at the horizon, so that is where
// warped high-frequency detail aliases hardest.
float cloud_density(vec2 uv, float time, float coverage, float region_scale,
		float region_edge, float shape_floor, float turbulence,
		vec2 stretch, float horizon_fade) {
	vec2 warp = vec2(cloud_fbm(uv * 1.7 + vec2(1.7, 9.2), time * 0.6, 2),
	                  cloud_fbm(uv * 1.7 + vec2(8.3, 2.1), time * 0.6, 2)) - 0.5;
	vec2 puv = uv + warp * turbulence * horizon_fade;

	vec2 drift = vec2(time * 0.017, -time * 0.011);
	float mask = cloud_fbm(uv * region_scale + drift, time * 0.25, 3);
	float cov = clamp(coverage, 0.0, 1.0);
	float region = smoothstep(1.0 - cov, 1.0 - cov + region_edge, mask);

	float shape = cloud_fbm(puv * stretch, time * 0.4, 4);
	shape = smoothstep(shape_floor, shape_floor + 0.55, shape);

	return clamp(shape * region, 0.0, 1.0);
}
