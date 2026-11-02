shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, specular_schlick_ggx;

// Canopy glass: smoked tint, thin-film coating at grazing angles, strong fresnel reflections of the real
// environment, plus a faint procedural "studio" reflection (soft horizon band + highlight streaks along the
// bubble) so the glass still reads as glass against black space or at night. Interior stays visible.
uniform vec3 tint : source_color = vec3(0.035, 0.05, 0.065);
uniform vec3 coating : source_color = vec3(0.35, 0.75, 0.85);
uniform vec3 coating2 : source_color = vec3(0.95, 0.62, 0.30);
uniform float coating_strength : hint_range(0.0, 1.0) = 0.35;
uniform float base_alpha : hint_range(0.0, 1.0) = 0.30;
uniform float roughness : hint_range(0.0, 1.0) = 0.03;
uniform float smudge : hint_range(0.0, 1.0) = 0.3;
uniform float fake_reflection : hint_range(0.0, 1.0) = 0.10;
instance uniform vec3 part_offset = vec3(0.0);

varying vec3 v_pos;
varying vec3 v_wnrm;

void vertex() {
	v_pos = VERTEX + part_offset;
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
	float fr = pow(1.0 - nv, 3.0);
	float sm = vnoise(v_pos * 7.0) * vnoise(v_pos * 23.0);
	// thin-film: hue shifts with the viewing angle
	vec3 film = mix(coating, coating2, smoothstep(0.25, 0.85, nv));
	ALBEDO = mix(tint, film * 0.22, coating_strength * (0.25 + 0.75 * fr));
	METALLIC = 0.25 + coating_strength * 0.4;
	ROUGHNESS = roughness + sm * smudge * 0.12;
	SPECULAR = 1.0;
	// procedural reflection in ship space: reflect the view ray off the bubble (model-space normal)
	vec3 r_world = reflect(-VIEW, NORMAL);
	vec3 r = (INV_VIEW_MATRIX * vec4(r_world, 0.0)).xyz;
	r = (inverse(MODEL_MATRIX) * vec4(r, 0.0)).xyz;
	r = normalize(r);
	float horizon = smoothstep(-0.15, 0.25, r.y) * (0.5 + 0.5 * smoothstep(0.9, 0.2, r.y));
	float streak = smoothstep(0.92, 1.0, 1.0 - abs(fract(v_pos.z * 0.55 + v_pos.x * 0.25) - 0.5) * 2.0);
	streak *= smoothstep(0.2, 0.8, r.y);
	vec3 fake = vec3(0.55, 0.65, 0.75) * horizon + vec3(1.0) * streak * 0.6;
	EMISSION = fake * fake_reflection * (0.25 + 0.75 * fr);
	ALPHA = clamp(mix(base_alpha, 1.0, fr * 0.92), 0.0, 1.0);
}
