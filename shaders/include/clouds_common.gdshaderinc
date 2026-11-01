// Procedural cloud layer shared code.
//  * cloud_weather_procedural(): planetary weather (fbm + domain warp + latitude circulation +
//    cyclone swirls). Expensive -> baked once into an equirect texture (cloud_weather_bake).
//  * cloud_weather(): 1 texture tap into the baked map (+ drift rotation over TIME).
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
uniform vec3 cloud_wind_vel = vec3(6.0, 0.0, 3.0); // local evolution of shapes, m/s
uniform int cloud_cyclones = 7;
uniform float cloud_cyclone_strength = 1.0;
uniform float cloud_shadow_strength = 0.0;   // receivers: 0 disables cloud_shadow()
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
	float n = cl_tex(b * 1.13 + vec3(0.21)) * 0.52
		+ cl_tex(vec3(b.x * 2.3, b.y * 4.5, b.z * 2.3) + vec3(0.53, 0.1, 0.4)) * 0.3
		+ cl_tex(b0 * 6.93 + vec3(0.7)) * 0.18;
	n = (n - 0.5) * 2.0 + 0.5;
	b = b0;
	// planetary circulation: wet ITCZ, dry subtropics, stormy mid-latitudes
	float lat = q.y;
	float al = abs(lat);
	float bias = 0.3 * exp(-pow(lat / 0.09, 2.0))
		- 0.28 * exp(-pow((al - 0.40) / 0.14, 2.0))
		+ 0.15 * exp(-pow((al - 0.74) / 0.16, 2.0));
	float thr = mix(0.9, 0.1, cloud_coverage);
	float cov = smoothstep(thr - 0.45, thr + 0.5, n + bias + boost * 1.5);
	float type = clamp((cl_tex(b * 1.7 + vec3(0.33)) - 0.5) * 3.0 + 0.4 + boost + 0.2 * exp(-pow(lat / 0.12, 2.0)), 0.0, 1.0);
	return vec2(cov, type);
}

// Baked weather lookup (equirect), with slow drift around the planet axis.
vec2 cloud_weather(vec3 dir) {
	float a = TIME * cloud_rot_speed;
	float ca = cos(a);
	float sa = sin(a);
	vec3 q = vec3(ca * dir.x - sa * dir.z, dir.y, sa * dir.x + ca * dir.z);
	vec2 uv = vec2(atan(q.z, q.x) * 0.15915494 + 0.5, acos(clamp(q.y, -1.0, 1.0)) * 0.31830989);
	return texture(cloud_weather_tex, uv).rg;
}

// Density (0..~1) at planet-local point pl, radius r, weather w.
// lod 0 = with detail erosion, 1 = shape only (light rays / shadows / far).
float cloud_density_at(vec3 pl, float r, vec2 w, int lod) {
	float h = (r - cloud_bottom) / (cloud_top - cloud_bottom);
	float cov = w.x;
	if (h <= 0.0 || h >= 1.0 || cov <= 0.01) return 0.0;
	// cloud top height from weather type (flat stratocumulus .. towering cumulus)
	float top = mix(0.3, 1.0, w.y);
	float hn = h / top;
	if (hn >= 1.0) return 0.0;
	vec3 drift = cloud_wind_vel * TIME;
	vec3 sp = (pl + drift) / cloud_shape_size;
	// billowy low-frequency shape: perlin fbm + inverted worley
	float s = cl_tex(sp) * 0.45 + cl_tex(sp * 0.29 + vec3(0.5)) * 0.25
		+ texture(cloud_detail_tex, sp * 0.5 + vec3(0.13)).r * 0.30;
	s = clamp((s - 0.25) * 1.9, 0.0, 1.0);
	s = mix(s, 1.0, smoothstep(0.6, 1.0, cov) * 0.4);         // dense weather -> continuous decks
	// coverage remap, then height gradient (flat base, soft rounded top), then dome rounding
	float base = clamp((s - (1.0 - cov)) / max(cov, 0.05), 0.0, 1.0);
	float grad = smoothstep(0.0, 0.07, h) * smoothstep(1.0, 0.7, hn);
	base *= grad;
	base = clamp((base - hn * 0.15) / (1.0 - hn * 0.15), 0.0, 1.0);
	base = clamp(base * 1.8, 0.0, 1.0);
	if (base <= 0.0) return 0.0;
	if (lod == 0) {
		float dn = texture(cloud_detail_tex, (pl + drift * 1.5) / cloud_detail_size).r;
		float er = mix(0.55, 0.3, smoothstep(0.0, 0.5, h));
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
	vec2 w = cloud_weather(normalize(q));
	float d = cloud_density_at(q, rm, w, 1);
	return 1.0 - cloud_shadow_strength * smoothstep(0.0, 0.35, d);
}

// p: world-oriented planet-relative position, L world sun dir, model: receiver MODEL_MATRIX
// (rotation of the planet). Assumes no scale.
float cloud_shadow_m(mat3 model, vec3 p, vec3 L) {
	if (cloud_shadow_strength <= 0.0) return 1.0;
	mat3 to_local = transpose(model);
	return cloud_shadow_local(to_local * p, to_local * L);
}

#endif
