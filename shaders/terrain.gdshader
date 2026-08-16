shader_type spatial;

#include "res://shaders/clouds.gdshaderinc"

// ============================================================================
// ROUTE 41 -- terrain and road surface
//
// Vertex colour carries the wild terrain palette from WorldGen.get_color().
// On top of that this shader adds:
//   1. fine grain, so close-up ground isn't flat plastic
//   2. a cliff normal map on steep faces, for the eroded butte strata
//   3. asphalt, gravel verge and painted markings inside the road corridor
//   4. a moving cloud shadow, sampled from the same field the sky draws
//
// UV2 carries road-local coordinates, written per vertex by ChunkManager:
//   UV2.x = signed metres from the centreline (positive = north of the road)
//   UV2.y = metres along the road, measured in X
// Markings are drawn per pixel from UV2.x rather than baked into vertex
// colour, because a 0.18 m line cannot survive 2 m vertex spacing.
//
// Normals are perturbed in world space, not tangent space -- the terrain
// ArrayMesh has no tangent array and triplanar mapping doesn't need one.
// ============================================================================

group_uniforms Detail;
uniform sampler2D detail_map : hint_default_white, filter_linear_mipmap, repeat_enable;
uniform float detail_scale_a : hint_range(0.01, 1.0) = 0.180;
uniform float detail_scale_b : hint_range(0.005, 0.5) = 0.037;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.35;

group_uniforms Cliff;
uniform sampler2D cliff_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform float cliff_scale : hint_range(0.01, 0.5) = 0.110;
uniform float cliff_strength : hint_range(0.0, 3.0) = 1.20;
uniform bool cliff_flip_green = false;

group_uniforms Slope;
// Keep matched to the rock blend in WorldGen.get_color().
uniform float slope_begin : hint_range(0.0, 1.0) = 0.10;
uniform float slope_end : hint_range(0.0, 1.0) = 0.38;

group_uniforms RoadSurface;
uniform sampler2D road_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D road_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D road_patch_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D road_patch_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D gravel_albedo : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D gravel_normal : hint_normal, filter_linear_mipmap, repeat_enable;
// Metres per tile = 1.0 / scale.
uniform float road_texture_scale : hint_range(0.05, 2.0) = 0.35;
uniform float gravel_texture_scale : hint_range(0.05, 2.0) = 0.50;
// How much of the road gets patch-repair asphalt mixed over it.
uniform float road_patch_amount : hint_range(0.0, 1.0) = 0.55;
uniform float road_patch_scale : hint_range(0.001, 0.05) = 0.012;
uniform float road_normal_strength : hint_range(0.0, 3.0) = 1.0;

group_uniforms RoadGeometry;
// Must match ROAD_HALF_WIDTH in world_gen.gd, or paint will drift off the tarmac.
uniform float road_half_width : hint_range(1.0, 20.0) = 5.5;
uniform float gravel_width : hint_range(0.0, 12.0) = 3.0;
uniform float gravel_fade : hint_range(0.5, 20.0) = 6.0;
// Eastern terminus, used only for the tarmac-to-gravel handoff. How far the
// roadbed itself extends is carried in vertex alpha, not computed here.
uniform float road_end_x = 0.0;

group_uniforms RoadMarkings;
uniform vec3 line_yellow : source_color = vec3(0.72, 0.56, 0.12);
uniform vec3 line_white : source_color = vec3(0.78, 0.77, 0.74);
uniform float line_center_inner : hint_range(0.0, 2.0) = 0.14;
uniform float line_center_outer : hint_range(0.0, 2.0) = 0.38;
uniform float line_edge_inset : hint_range(0.0, 6.0) = 1.70;
uniform float line_edge_half : hint_range(0.02, 0.6) = 0.09;
// 0 = fresh paint, 1 = heavily worn and patchy.
uniform float line_wear : hint_range(0.0, 1.0) = 0.55;

group_uniforms Surface;
uniform float albedo_saturation : hint_range(0.0, 2.0) = 1.35;
uniform float terrain_roughness : hint_range(0.0, 1.0) = 0.95;
uniform float road_roughness : hint_range(0.0, 1.0) = 0.72;
uniform float terrain_specular : hint_range(0.0, 1.0) = 0.04;

group_uniforms CloudShadow;
// Same field the sky's high deck draws from, sampled at world XZ instead of
// view direction, so the shadow drifts with the wind at the same rate the
// visible clouds do. Pushed every frame by WeatherSystem.
uniform float cloud_shadow_time = 0.0;
uniform vec2 cloud_shadow_offset = vec2(0.0);
uniform float cloud_shadow_scale : hint_range(0.00005, 0.01) = 0.00016;
uniform float cloud_shadow_coverage : hint_range(0.0, 1.0) = 0.0;
uniform float cloud_shadow_region_scale : hint_range(0.02, 1.0) = 0.20;
uniform float cloud_shadow_shape_floor : hint_range(0.0, 0.9) = 0.30;
uniform float cloud_shadow_turbulence : hint_range(0.0, 2.0) = 0.35;
// How much a cloud passing overhead darkens the ground beneath it.
uniform float cloud_shadow_strength : hint_range(0.0, 1.0) = 0.35;

varying vec3 world_pos;
varying vec3 world_normal;


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}


void fragment() {
	vec3 wn = normalize(world_normal);
	float steep = 1.0 - clamp(wn.y, 0.0, 1.0);
	float rock = smoothstep(slope_begin, slope_end, steep);

	// ---- road corridor weights -------------------------------------------
	float lateral = UV2.x;
	float along = UV2.y;
	float d = abs(lateral);
	// Derivatives must be taken in uniform control flow, so these are computed
	// before the road branch below even though only the branch uses them.
	// d_px is how many metres of road width one pixel spans.
	float d_px = fwidth(d);
	// Capped: an unbounded AA width smears a 0.24 m stripe across metres at
	// grazing angles, which reads as a broad wash rather than a line.
	float d_aa = clamp(d_px * 0.6, 0.0015, 0.20);

	// Lateral profile: tarmac in the middle, gravel verge either side.
	float lat_paved = 1.0 - smoothstep(road_half_width - 0.35, road_half_width + 0.35, d);
	float gravel_outer = road_half_width + gravel_width;
	float lat_verge = (1.0 - lat_paved)
		* (1.0 - smoothstep(gravel_outer, gravel_outer + gravel_fade, d));

	// Longitudinal profile. `presence` -- how much roadbed exists here, frayed
	// at its eastern end -- arrives in vertex alpha from WorldGen, which used
	// the identical value for corridor flattening and terrain colour. `sealed`
	// is purely a surface question, so it is computed here from UV2.y (world X).
	float presence = COLOR.a;
	float sealed = 1.0 - smoothstep(road_end_x - 6.0, road_end_x + 4.0, along);

	// Unsealed tarmac width becomes gravel, so the roadbed keeps its shape
	// east of the terminus while losing its surface.
	float paved = lat_paved * sealed;
	float verge = lat_paved * (1.0 - sealed) + lat_verge;
	float road_influence = clamp((paved + verge) * presence, 0.0, 1.0);

	// ---- terrain grain ----------------------------------------------------
	float g1 = texture(detail_map, world_pos.xz * detail_scale_a).r;
	float g2 = texture(detail_map, world_pos.xz * detail_scale_b).r;
	float grain = (g1 + g2) - 1.0;   // two maps centred on 0.5 -> centred on 0

	vec3 base = COLOR.rgb;
	float lum = dot(base, vec3(0.2126, 0.7152, 0.0722));
	base = mix(vec3(lum), base, albedo_saturation);
	vec3 albedo = base * (1.0 + grain * detail_strength * (1.0 - rock * 0.75));

	// ---- cliff normal, triplanar on the two vertical projections ----------
	vec2 axis = abs(vec2(wn.x, wn.z));
	vec2 blend = axis / max(axis.x + axis.y, 1e-4);

	vec3 nx = texture(cliff_normal, world_pos.zy * cliff_scale).xyz * 2.0 - 1.0;
	vec3 nz = texture(cliff_normal, world_pos.xy * cliff_scale).xyz * 2.0 - 1.0;
	if (cliff_flip_green) {
		nx.y = -nx.y;
		nz.y = -nz.y;
	}
	vec3 offset = vec3(0.0, nx.y, nx.x) * blend.x
	            + vec3(nz.x, nz.y, 0.0) * blend.y;
	vec3 final_normal = normalize(mix(wn, normalize(wn + offset * cliff_strength), rock));
	float rough = terrain_roughness;

	// ---- road surface -----------------------------------------------------
	// Branch: the corridor is a small, screen-coherent slice of most frames, so
	// the six road fetches are skipped almost everywhere with little divergence.
	if (road_influence > 0.002) {
		vec2 ruv = vec2(lateral, along) * road_texture_scale;
		vec2 guv = vec2(lateral, along) * gravel_texture_scale;

		// Patch repairs mixed in on a slow mask, so the road reads as mended
		// rather than freshly poured -- and so the tile doesn't repeat visibly.
		float patch_m = smoothstep(0.42, 0.72,
			texture(detail_map, vec2(along, lateral) * road_patch_scale).r) * road_patch_amount;

		vec3 surf = mix(texture(road_albedo, ruv).rgb,
		                texture(road_patch_albedo, ruv).rgb, patch_m);

		// Paint, drawn per pixel and antialiased against the lateral gradient.
		float wear = mix(1.0, clamp(texture(detail_map, ruv * 0.7).r * 1.7, 0.0, 1.0), line_wear);

		// Paint exists only on fully sealed tarmac. Without this gate it bleeds
		// onto the gravel run at partial strength as broad yellow washes.
		float paint_gate = smoothstep(0.75, 0.98, sealed);

		// A stripe narrower than one pixel's footprint cannot be drawn crisply.
		// Fading it is correct; widening the band to cover the footprint is what
		// smeared it. Half-widths are compared against half the pixel span.
		float half_px = max(d_px * 0.5, 1e-5);
		float centre_fade = clamp(((line_center_outer - line_center_inner) * 0.5) / half_px, 0.0, 1.0);
		float edge_fade = clamp(line_edge_half / half_px, 0.0, 1.0);

		float centre = smoothstep(line_center_inner - d_aa, line_center_inner + d_aa, d)
		             * (1.0 - smoothstep(line_center_outer - d_aa, line_center_outer + d_aa, d));
		float ep = road_half_width - line_edge_inset;
		float edge = smoothstep(ep - line_edge_half - d_aa, ep - line_edge_half + d_aa, d)
		           * (1.0 - smoothstep(ep + line_edge_half - d_aa, ep + line_edge_half + d_aa, d));

		surf = mix(surf, line_yellow, clamp(centre * wear * centre_fade * paint_gate, 0.0, 1.0));
		surf = mix(surf, line_white, clamp(edge * wear * edge_fade * paint_gate, 0.0, 1.0));

		vec3 grav = texture(gravel_albedo, guv).rgb;
		vec3 road_col = mix(grav, surf, paved);
		albedo = mix(albedo, road_col, road_influence);

		// Tangent frame on a near-horizontal surface: U runs across the road
		// (roughly world Z), V runs along it (roughly world X).
		vec3 nr = mix(texture(road_normal, ruv).xyz,
		              texture(road_patch_normal, ruv).xyz, patch_m) * 2.0 - 1.0;
		vec3 ng = texture(gravel_normal, guv).xyz * 2.0 - 1.0;
		vec3 nt = mix(ng, nr, paved);
		vec3 road_n = normalize(wn + vec3(nt.y, 0.0, nt.x) * road_normal_strength);

		final_normal = normalize(mix(final_normal, road_n, road_influence));
		rough = mix(rough, mix(0.95, road_roughness, paved), road_influence);
	}

	// ---- cloud shadow -------------------------------------------------------
	// World-space, not view-angle, so there is no horizon to fade near and no
	// stretch -- this approximates the high deck's overall cover, not its
	// individual streak shapes.
	float shadow_d = cloud_density(world_pos.xz * cloud_shadow_scale + cloud_shadow_offset,
		cloud_shadow_time, cloud_shadow_coverage, cloud_shadow_region_scale,
		0.22, cloud_shadow_shape_floor, cloud_shadow_turbulence, vec2(1.0), 1.0);
	albedo *= 1.0 - shadow_d * cloud_shadow_strength;

	ALBEDO = albedo;
	// NORMAL is view space in Godot's fragment stage.
	NORMAL = normalize((VIEW_MATRIX * vec4(final_normal, 0.0)).xyz);
	ROUGHNESS = rough;
	SPECULAR = terrain_specular;
}
