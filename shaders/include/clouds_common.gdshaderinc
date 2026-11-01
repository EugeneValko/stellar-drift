// Procedural cloud layer shared code.
//  * cloud_weather_procedural(): planetary weather (fbm + domain warp + latitude circulation +
//    cyclone swirls). Expensive -> baked once into an equirect texture (cloud_weather_bake).
//  * cloud_weather(): bicubic lookup of the baked map (+ drift over TIME); _fast = 1 tap.
//  * cloud_density_at(): 3D density inside the shell.
//  * cloud_shadow_local()/cloud_shadow_m(): cheap shadow term for receivers (ocean, terrain).
//    Receivers get uniforms from CloudLayer.get_shadow_uniforms() (cloud_shadow_strength > 0).
//
// Positions: `pl` = planet-local (rotates with the planet), metres from planet centre.
#ifndef CLOUDS_COMMON_INC
#define CLOUDS_COMMON_INC

#include "res://shaders/include/sun_globals.gdshaderinc"

group_uniforms clouds;
uniform sampler3D cloud_shape_tex : hint_default_white, filter_linear, repeat_enable;
uniform sampler3D cloud_detail_tex : hint_default_white, filter_linear, repeat_enable;
uniform sampler2D cloud_weather_tex : hint_default_black, filter_linear, repeat_enable;
uniform float cloud_bottom = 62200.0;        // shell radii, m
uniform float cloud_top = 65200.0;
uniform float cloud_coverage = 0.5;          // global coverage 0..1 (baked into weather)
uniform float cloud_density = 0.03;          // extinction (1/m) at density 1
uniform float cloud_shape_size = 14000.0;     // m per shape noise tile
uniform float cloud_detail_size = 2000.0;    // m per detail noise tile
uniform float cloud_weather_seed = 0.0;
uniform float cloud_rot_speed = 0.00002;     // weather drift around planet axis, rad/s
uniform float cloud_rot_offset = 0.0;        // extra rotation of the weather map (rad)
uniform vec3 cloud_wind_vel = vec3(6.0, 0.0, 3.0); // local evolution of shapes, m/s
uniform int cloud_cyclones = 7;
uniform float cloud_cyclone_strength = 1.0;
uniform float cloud_shadow_strength = 0.0;   // receivers: 0 disables cloud_shadow()
uniform float cloud_stratus = 0.6;           // share of flat stratus / stratocumulus decks (0..1)
uniform float cloud_weather_contrast = 1.0;  // >1 = crisper clear / overcast regions
// wave 4: 0 = additive perlin+worley shape (old), 1 = perlin-worley remap (perlin carved by the
// worley cells -> rounded, billowing lobes)
uniform float cloud_billow = 0.0;
group_uniforms;

float cl_tex(vec3 q) {
	return texture(cloud_shape_tex, q).r;
}

vec3 cl_rot_axis(vec3 v, vec3 axis, float a) {
	float c = cos(a);
	float s = sin(a);
	return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

float cl_hash1(float n) {
	return fract(sin(n * 127.1 + cloud_weather_seed * 31.7) * 43758.5453);
}

// Weather at planet-local unit direction: x = coverage 0..1, y = cloud type (0 low/flat .. 1 tall).
vec2 cloud_weather_procedural(vec3 dir) {
	vec3 q = dir;
	float boost = 0.0;
	// cyclones: twist the domain around a few mid-latitude centres (Coriolis sign per hemisphere)
	for (int i = 0; i < cloud_cyclones; i++) {
		float fi = float(i);
		float hemi = (i % 2 == 0) ? 1.0 : -1.0;
		float lat = hemi * mix(0.42, 1.0, cl_hash1(fi + 1.0));
		float lon = fi * 2.39996 + cl_hash1(fi + 7.0) * 1.3;
		vec3 c = vec3(cos(lat) * cos(lon), sin(lat), cos(lat) * sin(lon));
		float rad = mix(0.13, 0.26, cl_hash1(fi + 13.0));
		float d = length(q - c);
		if (d < rad * 3.0) {
			float w = exp(-(d * d) / (rad * rad));
			float ang = hemi * cloud_cyclone_strength * mix(2.5, 4.5, cl_hash1(fi + 21.0)) * w;
			q = cl_rot_axis(q, c, ang);
			boost += w * 0.18 - exp(-(d * d) / (rad * rad * 0.012)) * 0.5;  // dense spiral, clear eye
		}
	}
	vec3 wq = q * 0.83 + vec3(cloud_weather_seed * 0.37);
	vec3 warp = vec3(cl_tex(wq), cl_tex(wq + vec3(0.37, 0.11, 0.73)), cl_tex(wq + vec3(0.61, 0.83, 0.19))) - 0.5;
	vec3 b = q + warp * 0.45;
	// fine octave is NOT swirled (avoids grooved rings in cyclones)
	vec3 b0 = dir + warp * 0.3;
	// large systems + east-west elongated fronts + medium detail; contrast-expanded
	// (weights favour the large systems: coherent fronts and clear regions instead of speckle)
	float n = cl_tex(b * 1.13 + vec3(0.21)) * 0.6
		+ cl_tex(vec3(b.x * 2.3, b.y * 4.5, b.z * 2.3) + vec3(0.53, 0.1, 0.4)) * 0.3
		+ cl_tex(b0 * 6.93 + vec3(0.7)) * 0.1;
	n = (n - 0.5) * 2.0 + 0.5;
	// wave 4: frontal bands - long, narrow, winding cloud lines (iso-line of a warped noise),
	// strongest in the storm belts, spiralling into the cyclones (b carries their swirl)
	float fr = 1.0 - abs(cl_tex(b * 1.45 + vec3(0.9, 0.3, 0.2)) * 2.0 - 1.0);
	fr = pow(fr, 7.0) * (0.35 + 0.65 * smoothstep(0.2, 0.55, abs(q.y)));
	fr *= 0.6 + 0.4 * cl_tex(b0 * 9.0 + vec3(0.2, 0.7, 0.4));
	n = max(n, fr * 1.05);
	b = b0;
	// planetary circulation: wet ITCZ, dry subtropics, stormy mid-latitudes
	float lat = q.y;
	float al = abs(lat);
	float bias = 0.3 * exp(-pow(lat / 0.09, 2.0))
		- 0.28 * exp(-pow((al - 0.40) / 0.14, 2.0))
		+ 0.15 * exp(-pow((al - 0.74) / 0.16, 2.0));
	float thr = mix(0.9, 0.1, cloud_coverage);
	float wc = 1.0 / max(cloud_weather_contrast, 0.1);
	float cov = smoothstep(thr - 0.38 * wc, thr + 0.4 * wc, n + bias + boost * 1.5);
	float type = clamp((cl_tex(b * 1.2 + vec3(0.33)) - 0.5) * 2.4 + 0.4 + boost + 0.2 * exp(-pow(lat / 0.12, 2.0)), 0.0, 1.0);
	// large overcast regions and the mid-latitude storm belts are flat decks (stratus /
	// stratocumulus); towering cumulus stays in the tropics, cyclones and scattered fields
	float deck = smoothstep(0.55, 0.9, cov) * 0.7 + 0.35 * exp(-pow((al - 0.6) / 0.18, 2.0));
	deck *= cloud_stratus * (1.0 - clamp(boost * 3.0, 0.0, 1.0));
	type = mix(type, type * 0.25, clamp(deck, 0.0, 1.0));
	return vec2(cov, type);
}

// Baked weather lookup (equirect), with slow drift around the planet axis.
vec2 cloud_weather_uv(vec3 dir) {
	float a = TIME * cloud_rot_speed + cloud_rot_offset;
	float ca = cos(a);
	float sa = sin(a);
	vec3 q = vec3(ca * dir.x - sa * dir.z, dir.y, sa * dir.x + ca * dir.z);
	return vec2(atan(q.z, q.x) * 0.15915494 + 0.5, acos(clamp(q.y, -1.0, 1.0)) * 0.31830989);
}

// Cheap single bilinear tap (light rays, shadows, far samples).
vec2 cloud_weather_fast_uv(vec2 uv) {
	return textureLod(cloud_weather_tex, uv, 0.0).rg;
}

vec2 cloud_weather_fast(vec3 dir) {
	return cloud_weather_fast_uv(cloud_weather_uv(dir));
}

// bicubic B-spline from 4 bilinear taps: C2-smooth coverage (bilinear creases would be
// extruded into vertical "curtains" by the density remap)
vec2 cloud_weather_bicubic_uv(vec2 uv) {
	vec2 size = vec2(textureSize(cloud_weather_tex, 0));
	vec2 st = uv * size - 0.5;
	vec2 i = floor(st);
	vec2 f = st - i;
	vec2 w0 = (1.0 - f) * (1.0 - f) * (1.0 - f) / 6.0;
	vec2 w1 = (4.0 - 6.0 * f * f + 3.0 * f * f * f) / 6.0;
	vec2 w2 = (1.0 + 3.0 * f + 3.0 * f * f - 3.0 * f * f * f) / 6.0;
	vec2 w3 = f * f * f / 6.0;
	vec2 g0 = w0 + w1;
	vec2 g1 = w2 + w3;
	vec2 h0 = (i - 1.0 + w1 / g0 + 0.5) / size;
	vec2 h1 = (i + 1.0 + w3 / g1 + 0.5) / size;
	return (textureLod(cloud_weather_tex, vec2(h0.x, h0.y), 0.0).rg * g0.x
		+ textureLod(cloud_weather_tex, vec2(h1.x, h0.y), 0.0).rg * g1.x) * g0.y
		+ (textureLod(cloud_weather_tex, vec2(h0.x, h1.y), 0.0).rg * g0.x
		+ textureLod(cloud_weather_tex, vec2(h1.x, h1.y), 0.0).rg * g1.x) * g1.y;
}

vec2 cloud_weather(vec3 dir) {
	return cloud_weather_bicubic_uv(cloud_weather_uv(dir));
}

// Density (0..~1) at planet-local point pl, radius r, weather w.
// lod 0 = with detail erosion, 1 = shape only (light rays / shadows / far).
float cloud_density_at(vec3 pl, float r, vec2 w, int lod) {
	float h = (r - cloud_bottom) / (cloud_top - cloud_bottom);
	float cov = w.x;
	if (h <= 0.0 || h >= 1.0 || cov <= 0.01) return 0.0;
	// cloud top height from weather type (flat stratocumulus .. towering cumulus); most fields are
	// low/medium cumulus, the full layer depth only for the convective cores (type -> 1)
	float top = mix(0.22, 1.0, pow(w.y, 1.4));
	float hn = h / top;
	if (hn >= 1.0) return 0.0;
	// 0 = cumulus, 1 = flat stratus deck
	float stratus = 1.0 - smoothstep(0.18, 0.5, w.y);
	vec3 drift = cloud_wind_vel * TIME;
	vec3 sp = (pl + drift) / cloud_shape_size;
	float grad = smoothstep(0.0, 0.07, h) * smoothstep(1.0, 0.7, hn);
	float base = 0.0;
	if (stratus < 0.99) {
		// cumulus: billowy low-frequency shape (perlin fbm + inverted worley), coverage remap,
		// flat base, rounded top
		float p1 = cl_tex(sp);
		float p2 = cl_tex(sp * 0.29 + vec3(0.5));
		float wv = texture(cloud_detail_tex, sp * 0.5 + vec3(0.13)).r;
		float s = p1 * 0.45 + p2 * 0.25 + wv * 0.30;
		s = clamp((s - 0.25) * 1.9, 0.0, 1.0);
		if (cloud_billow > 0.0) {
			float pf = p1 * 0.6 + p2 * 0.4;
			float pw = clamp((pf - (1.0 - wv) * 0.7) / max(1.0 - (1.0 - wv) * 0.7, 0.05), 0.0, 1.0);
			s = mix(s, clamp((pw - 0.08) * 1.7, 0.0, 1.0), cloud_billow);
		}
		s = mix(s, 1.0, smoothstep(0.6, 1.0, cov) * 0.4);         // dense weather -> continuous
		// vertical profile (wave 4): flat base, widest low down, narrowing upward -> the noise
		// cores rise into rounded domes instead of extruded boxes with vertical walls
		float prof = smoothstep(0.0, 0.06, h) * (1.0 - 0.72 * hn * hn);
		float cu = clamp((s * prof - (1.0 - cov)) / max(cov, 0.05), 0.0, 1.0);
		base = clamp(cu * 1.5, 0.0, 1.0);
	}
	if (stratus > 0.01) {
		// stratus / stratocumulus deck: continuous sheet whose thickness follows the weather
		// coverage (soft edges over tens of km), low-contrast rolls stretched along parallels
		vec3 sq = vec3(sp.x * 0.8, sp.y * 2.4, sp.z * 0.8) * 0.5;
		float st = cl_tex(sq + vec3(0.17, 0.0, 0.41)) * 0.55 + cl_tex(sq * 2.7 + vec3(0.5)) * 0.3
			+ texture(cloud_detail_tex, sp * 0.9 + vec3(0.3)).r * 0.15;
		// edges: coverage fades out over a wide band and is broken up by the texture (no
		// vertical "box" walls where the weather map changes quickly)
		float edge = smoothstep(0.05, 0.75, cov + (st - 0.5) * 0.35);
		float deck = edge * edge * clamp(0.62 + (st - 0.45) * 0.6, 0.0, 1.0);
		// flat top (decks seen from above are smooth), soft base; the deck thins toward its edges
		// (top sinks, base rises) so it ends in a slope, not a vertical wall
		float thin = (1.0 - edge) * 0.55;
		float prof = smoothstep(thin * 0.6, 0.3 + thin * 0.6, hn)
			* smoothstep(1.0, 0.82, hn + (st - 0.5) * 0.25 + thin);
		base = mix(base, deck * prof * 0.75, stratus);
	}
	if (base <= 0.0) return 0.0;
	if (lod == 0) {
		float dn = texture(cloud_detail_tex, (pl + drift * 1.5) / cloud_detail_size).r;
		float er = mix(0.55, 0.3, smoothstep(0.0, 0.5, h)) * (1.0 - 0.8 * stratus);
		base = (base - (1.0 - dn) * er) / (1.0 - er);
	}
	return clamp(base, 0.0, 1.0);
}

// Fraction of direct sunlight reaching planet-local point pl (one weather tap + 2 shape taps at
// mid-cloud height along the sun ray).
float cloud_shadow_local(vec3 pl, vec3 L_local) {
	if (cloud_shadow_strength <= 0.0) return 1.0;
	float rm = mix(cloud_bottom, cloud_top, 0.25);
	vec2 hit = sd_ray_sphere(pl, L_local, rm);
	if (hit.y <= 0.0 || hit.y < hit.x) return 1.0;
	float t = hit.x > 0.0 ? hit.x : hit.y;
	vec3 q = pl + L_local * t;
	vec2 w = cloud_weather_fast(normalize(q));
	float d = cloud_density_at(q, rm, w, 1);
	return 1.0 - cloud_shadow_strength * smoothstep(0.0, 0.35, d);
}

// p: world-oriented planet-relative position in BODY units (divide by the node scale when the
// body is a scaled-space proxy), L world sun dir, model: receiver MODEL_MATRIX (rotation of the
// planet; a uniform scale is removed here).
float cloud_shadow_m(mat3 model, vec3 p, vec3 L) {
	if (cloud_shadow_strength <= 0.0) return 1.0;
	mat3 to_local = transpose(model) / length(model[0]);
	return cloud_shadow_local(to_local * p, to_local * L);
}

#endif
