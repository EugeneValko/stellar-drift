// Star light shared by all planet shaders. Set from GDScript via SunGlobals (src/core/sun_globals.gd).
#ifndef SUN_GLOBALS_INC
#define SUN_GLOBALS_INC

global uniform vec3 sun_direction;   // world space, unit, toward the sun
global uniform vec4 sun_color;       // linear RGB, unattenuated
global uniform float sun_intensity;  // lambert white facing sun -> radiance = color * intensity

#define SD_PI 3.14159265
#define SD_INV_4PI 0.0795774715

// Robust ray/sphere intersection (sphere centered at origin). Returns (t_near, t_far);
// no hit -> (1e30, -1e30). Uses the closest-approach form for float32 precision at
// planetary scales (|ro| up to ~1e6 m).
vec2 sd_ray_sphere(vec3 ro, vec3 rd, float R) {
	float b = dot(ro, rd);
	vec3 q = ro - b * rd;
	float d = length(q);
	if (d >= R) return vec2(1e30, -1e30);
	float h = sqrt((R - d) * (R + d));
	return vec2(-b - h, -b + h);
}

// Per-pixel jitter (0..1), stable.
float sd_ign(vec2 fc) {
	// R2 low-discrepancy pattern (more isotropic than IGN when not accumulated temporally)
	return fract(dot(floor(fc), vec2(0.7548776662, 0.5698402910)) + 0.5);
}

// Distance along the view ray to the opaque scene (from a hint_depth_texture value).
// Reverse-Z: depth 0 == far/sky -> 1e30.
float sd_scene_distance(float depth, vec2 screen_uv, mat4 inv_proj) {
	if (depth <= 0.0) return 1e30;
	vec4 v = inv_proj * vec4(screen_uv * 2.0 - 1.0, depth, 1.0);
	return length(v.xyz / v.w);
}

float sd_hg(float cos_t, float g) {
	float g2 = g * g;
	return SD_INV_4PI * (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * cos_t, 1e-4), 1.5);
}

#endif
