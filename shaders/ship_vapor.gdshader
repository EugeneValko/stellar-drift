shader_type spatial;
// Condensation (Prandtl-Glauert vapor cone) shell around the fuselage when fast in thick air.
// Mesh: open cone along local Z, UV.y 0 (front) -> 1 (back). Lit by the sun (wet white mist).
render_mode blend_mix, cull_disabled, depth_draw_never, shadows_disabled, specular_disabled, diffuse_lambert_wrap;

uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float time_s = 0.0;
uniform vec3 color : source_color = vec3(0.95, 0.97, 1.0);
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float pnoise(vec2 uv, float cx, float cy) {
	vec2 p = vec2(uv.x * cx, uv.y * cy);
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float i0 = mod(i.x, cx);
	float i1 = mod(i.x + 1.0, cx);
	return mix(mix(hash12(vec2(i0, i.y)), hash12(vec2(i1, i.y)), f.x),
		mix(hash12(vec2(i0, i.y + 1.0)), hash12(vec2(i1, i.y + 1.0)), f.x), f.y);
}

void fragment() {
	if (amount < 0.003) {
		discard;
	}
	float v = clamp(UV.y, 0.0, 1.0);
	float n = pnoise(vec2(UV.x, v - time_s * 3.0), 40.0, 8.0) * 0.6 + pnoise(vec2(UV.x + 0.5, v * 2.0 - time_s * 5.0), 90.0, 14.0) * 0.4;
	float band = smoothstep(0.0, 0.2, v) * (1.0 - smoothstep(0.35, 1.0, v));
	float rim = 1.0 - clamp(abs(dot(normalize(NORMAL), VIEW)), 0.0, 1.0);
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float soft = clamp((-vp.z / vp.w - (-VERTEX.z)) / 0.8, 0.0, 1.0);
	ALBEDO = color;
	ALPHA = clamp(band * (0.25 + 0.75 * rim) * smoothstep(0.25, 0.75, n) * amount * 0.85, 0.0, 1.0) * soft;
}
