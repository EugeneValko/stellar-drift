shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

// Emissive light strips / screens. `energy` is HDR (glow picks it up). Optional slow pulse and a flowing
// highlight along the ship length (ship space Z).
uniform vec3 color : source_color = vec3(0.35, 0.80, 1.0);
uniform float energy = 4.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.08;
uniform float flow : hint_range(0.0, 1.0) = 0.25;
uniform float flow_speed = 3.0;
uniform float time_override = -1.0; // >=0 freezes animation (captures)
instance uniform vec3 part_offset = vec3(0.0);

varying vec3 v_pos;

void vertex() {
	v_pos = VERTEX + part_offset;
}

void fragment() {
	float t = time_override >= 0.0 ? time_override : TIME;
	float pl = 1.0 - pulse * (0.5 + 0.5 * sin(t * 1.7));
	float fl = 1.0 + flow * smoothstep(0.85, 1.0, sin(v_pos.z * 1.2 - t * flow_speed));
	ALBEDO = color * 0.2;
	ROUGHNESS = 0.3;
	EMISSION = color * energy * pl * fl;
}
