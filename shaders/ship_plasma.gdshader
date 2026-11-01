shader_type spatial;
// Plasma sheath / bow shock and wake around the ship during re-entry.
// Mesh: paraboloid/cone shell, local -Z = direction of travel,
// UV.y = 0 at the apex -> 1 at the open end, UV.x = angle (0..1).
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float time_s = 0.0;
// 0 = bow shock, 1 = wake (long trailing flame)
uniform int mode = 0;
uniform vec3 color_a : source_color = vec3(1.0, 0.55, 0.2);
uniform vec3 color_b : source_color = vec3(0.7, 0.25, 1.0);
uniform float intensity = 3.0;
uniform float scroll = 6.0;
uniform float depth_fade = 2.0;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1, 0)), f.x),
		mix(hash12(i + vec2(0, 1)), hash12(i + vec2(1, 1)), f.x), f.y);
}

// periodic in x (angle), so the seam at UV.x = 0/1 is invisible
float pnoise(vec2 uv, float cells_x, float cells_y) {
	vec2 p = vec2(uv.x * cells_x, uv.y * cells_y);
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float i0 = mod(i.x, cells_x);
	float i1 = mod(i.x + 1.0, cells_x);
	return mix(mix(hash12(vec2(i0, i.y)), hash12(vec2(i1, i.y)), f.x),
		mix(hash12(vec2(i0, i.y + 1.0)), hash12(vec2(i1, i.y + 1.0)), f.x), f.y);
}

void fragment() {
	if (amount < 0.003) {
		discard;
	}
	float v = clamp(UV.y, 0.0, 1.0);
	float rim = 1.0 - clamp(abs(dot(normalize(NORMAL), VIEW)), 0.0, 1.0);
	float t = time_s;
	float n1 = pnoise(vec2(UV.x, v - t * scroll * 0.1), 48.0, 10.0);
	float n2 = pnoise(vec2(UV.x + 0.37, v * 0.5 - t * scroll * 0.23), 22.0, 6.0);
	float flick = 0.6 + 0.8 * n1 * n2;
	// soft intersection with the hull/terrain
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -vp.z / vp.w;
	float soft = clamp((scene_z - (-VERTEX.z)) / depth_fade, 0.0, 1.0);
	vec3 col;
	float a;
	if (mode == 0) {
		// bright cap at the apex, glowing rim (shock front seen edge-on)
		float cap = exp(-v * 10.0);
		float streak = smoothstep(0.4, 0.95, pnoise(vec2(UV.x, v * 1.5 - t * scroll * 0.15), 36.0, 4.0));
		float body = pow(rim, 2.5) * (1.0 - smoothstep(0.25, 1.0, v)) * (0.35 + 0.9 * streak);
		a = (cap * 1.8 + body + 0.05 * (1.0 - v) * streak) * flick;
		col = mix(vec3(1.0, 0.85, 0.6), color_a, smoothstep(0.0, 0.25, v));
		col = mix(col, color_b, smoothstep(0.35, 1.0, v) * 0.7);
	} else {
		float fade = pow(1.0 - v, 2.5) * smoothstep(0.0, 0.08, v);
		float streaks = smoothstep(0.45, 0.95, pnoise(vec2(UV.x, v * 0.6 - t * scroll * 0.08), 30.0, 3.0));
		a = fade * (0.15 + 0.85 * streaks) * (0.35 + 0.4 * rim) * flick;
		col = mix(color_a, color_b, smoothstep(0.1, 0.7, v));
	}
	ALBEDO = col * a * amount * intensity * soft;
}
