shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

// Engine nozzle interior (EngineInner slot). thrust 0..1 drives an HDR glow from dull heat to plasma.
uniform float thrust : hint_range(0.0, 1.0) = 0.0;
uniform vec3 hot_color : source_color = vec3(0.55, 0.80, 1.0);
uniform vec3 core_color : source_color = vec3(0.92, 0.96, 1.0);
uniform vec3 idle_color : source_color = vec3(1.0, 0.36, 0.10);
uniform float idle_energy = 0.6;
uniform float max_energy = 28.0;
uniform float time_override = -1.0;

varying vec3 v_pos;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	v_pos = VERTEX;
}

void fragment() {
	float t = time_override >= 0.0 ? time_override : TIME;
	float nv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	// rings along the nozzle depth + flicker
	float rings = 0.75 + 0.25 * sin(v_pos.z * 38.0);
	float flick = 0.92 + 0.08 * hash12(vec2(floor(t * 30.0), v_pos.x));
	float th = thrust * thrust * (3.0 - 2.0 * thrust);
	vec3 c = mix(idle_color, mix(hot_color, core_color, nv * nv), smoothstep(0.0, 0.35, thrust));
	float e = mix(idle_energy, max_energy, th) * (0.35 + 0.65 * nv) * rings * flick;
	ALBEDO = vec3(0.05);
	METALLIC = 0.8;
	ROUGHNESS = 0.5;
	EMISSION = c * e;
}
