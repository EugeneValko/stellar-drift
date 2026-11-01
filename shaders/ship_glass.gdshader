shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

// Canopy glass: dark smoked tint, gold-ish coating visible at grazing angles, strong fresnel reflections.
uniform vec3 tint : source_color = vec3(0.025, 0.03, 0.035);
uniform vec3 coating : source_color = vec3(0.85, 0.62, 0.32);
uniform float coating_strength : hint_range(0.0, 1.0) = 0.35;
uniform float base_alpha : hint_range(0.0, 1.0) = 0.42;
uniform float roughness : hint_range(0.0, 1.0) = 0.03;
uniform float smudge : hint_range(0.0, 1.0) = 0.3;

varying vec3 v_pos;

void vertex() {
	v_pos = VERTEX;
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void fragment() {
	float nv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fr = pow(1.0 - nv, 4.0);
	float sm = vnoise(v_pos * 7.0) * vnoise(v_pos * 23.0);
	ALBEDO = mix(tint, coating * 0.25, coating_strength * (0.3 + 0.7 * fr));
	METALLIC = coating_strength * 0.6;
	ROUGHNESS = roughness + sm * smudge * 0.12;
	SPECULAR = 0.75;
	ALPHA = clamp(mix(base_alpha, 1.0, fr * 0.9), 0.0, 1.0);
}
