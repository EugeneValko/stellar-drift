shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// Additive exhaust plume on a cone mesh whose axis is local +Y from y=+length/2 (nozzle) to -length/2 (tail).
uniform float thrust : hint_range(0.0, 1.0) = 0.0;
uniform float plume_len = 6.0;
uniform vec3 color_start : source_color = vec3(0.60, 0.85, 1.0);
uniform vec3 color_end : source_color = vec3(0.30, 0.25, 1.0);
uniform float intensity = 6.0;
uniform float diamonds = 0.6;
uniform float edge_soft = 1.6;
uniform float time_override = -1.0;

varying float v_t;

void vertex() {
	v_t = clamp(0.5 - VERTEX.y / plume_len, 0.0, 1.0);
}

void fragment() {
	float tm = time_override >= 0.0 ? time_override : TIME;
	float nv = abs(dot(NORMAL, VIEW));
	float core = pow(nv, edge_soft);
	float fall = exp(-v_t * 3.2) * smoothstep(0.0, 0.04, v_t);
	float dia = 1.0 + diamonds * (0.5 + 0.5 * cos(v_t * 34.0 - tm * 2.0)) * (1.0 - v_t);
	float flick = 0.93 + 0.07 * sin(tm * 61.0 + v_t * 20.0);
	vec3 c = mix(color_start, color_end, smoothstep(0.0, 0.8, v_t));
	float a = core * fall * dia * flick * thrust;
	ALBEDO = c * intensity * a;
	ALPHA = 1.0;
}
