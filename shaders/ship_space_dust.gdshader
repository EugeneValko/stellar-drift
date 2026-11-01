shader_type spatial;
// Space dust streaks around the camera for a sense of speed. Each quad = 4 vertices sharing a
// base position in [0,1)^3 (VERTEX); UV.x = head(0)/tail(1), UV.y = side. The dust is anchored
// in the world through `travel` (accumulated camera displacement, wrapped by the box size), so it
// is unaffected by floating-origin shifts.
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, skip_vertex_transform, fog_disabled, shadows_disabled;

uniform vec3 travel = vec3(0.0);       // world displacement since start, wrapped (m)
uniform vec3 vel_app = vec3(0.0);      // apparent velocity used for streak length (m/s, world)
uniform float box = 90.0;
uniform float streak_time = 0.03;
uniform float max_len = 12.0;
uniform float width = 0.025;
uniform float amount = 1.0;
uniform vec3 color : source_color = vec3(0.75, 0.82, 1.0);

varying float v_alpha;
varying float v_side;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

void vertex() {
	vec3 base = VERTEX;
	vec3 p = (fract(base - travel / box) - 0.5) * box;
	vec3 tail_off = vel_app * streak_time;
	float l = length(tail_off);
	if (l > max_len) {
		tail_off *= max_len / l;
		l = max_len;
	}
	vec3 hv = (MODELVIEW_MATRIX * vec4(p, 1.0)).xyz;
	vec3 tv = (MODELVIEW_MATRIX * vec4(p - tail_off, 1.0)).xyz;
	vec3 axis = hv - tv;
	if (length(axis) < 1e-3) {
		axis = vec3(0.0, 1e-3, 0.0);
	}
	vec3 side = normalize(cross(axis, hv));
	float w = max(width, 0.0012 * -hv.z) * mix(0.6, 1.4, hash13(base * 91.0));
	vec3 pos = mix(hv, tv, UV.x) + side * w * (UV.y * 2.0 - 1.0);
	VERTEX = pos;
	float d = length(p);
	float r = hash13(base * 17.0);
	v_alpha = amount * smoothstep(box * 0.5, box * 0.28, d) * smoothstep(2.0, 6.0, d)
		* mix(0.25, 1.0, r * r) / (1.0 + l * 0.06) * mix(1.0, 0.45, UV.x);
	v_side = UV.y * 2.0 - 1.0;
}

void fragment() {
	float s = 1.0 - v_side * v_side;
	ALBEDO = color * v_alpha * s * 0.9;
}
