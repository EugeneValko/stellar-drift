shader_type spatial;
// Warp tunnel: open cylinder around the camera aligned with the velocity (local +Y = forward).
// Light streaks race past along the walls; blue-white core, violet fringe.
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, depth_test_disabled, fog_disabled, shadows_disabled;

uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float time_s = 0.0;
uniform float length_m = 4000.0;
uniform float speed = 1.0;            // streak scroll speed scale
uniform vec3 color_a : source_color = vec3(0.65, 0.8, 1.0);
uniform vec3 color_b : source_color = vec3(0.7, 0.4, 1.0);
uniform float intensity = 2.5;

varying float v_ang;
varying float v_along;

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

void vertex() {
	v_ang = atan(VERTEX.z, VERTEX.x) / TAU + 0.5;
	v_along = VERTEX.y / length_m + 0.5;    // 0 = behind, 1 = ahead
}

void fragment() {
	if (amount < 0.003) {
		discard;
	}
	float cells = 260.0;
	float c = floor(v_ang * cells);
	float r = hash11(c + 1.7);
	float r2 = hash11(c * 3.1 + 9.2);
	float lane = smoothstep(0.5, 0.05, abs(fract(v_ang * cells) - 0.5) * 2.0);
	float ph = fract(v_along * (2.0 + r2 * 3.0) + time_s * speed * (0.8 + r * 1.6) + r * 13.0);
	float streak = smoothstep(0.0, 0.03, ph) * pow(1.0 - ph, 6.0);
	float active = step(0.35, r) * amount;
	float ends = smoothstep(0.0, 0.25, v_along) * smoothstep(1.0, 0.6, v_along);
	vec3 col = mix(color_a, color_b, r2 * 0.6 + 0.2 * smoothstep(0.4, 0.9, ph));
	float glow = 0.08 * amount * ends;   // faint tunnel haze
	ALBEDO = (col * streak * lane * active * ends * (0.5 + r) + color_a * glow) * intensity * amount;
}
