shader_type spatial;
// Full-screen warp post effect (quad 2x2 in clip space, child of the camera): radial zoom blur
// toward the vanishing point, chromatic split, blue shift, vignette, engage flash.
// Wave 4: drop-out ripple (an expanding refraction ring + chromatic fringe from the centre).
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, skip_vertex_transform, fog_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 center = vec2(0.5);
uniform float flash = 0.0;
uniform float blur = 0.09;
// drop-out ripple: progress 0..1 (< 0 = off) and strength
uniform float ripple = -1.0;
uniform float ripple_amp = 0.035;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float aspect0 = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	float ring = 0.0;
	vec2 rdir = vec2(0.0);
	if (ripple >= 0.0) {
		vec2 dc = (uv - center) * vec2(aspect0, 1.0);
		float rr = length(dc);
		float front = ripple * 1.5;
		float x = (rr - front) / (0.06 + 0.12 * ripple);
		ring = exp(-x * x) * (1.0 - ripple);
		rdir = dc / max(rr, 1e-4) / vec2(aspect0, 1.0);
		// refraction (derivative of the ring profile: a lens-like bulge travelling outward)
		uv += rdir * ripple_amp * (-x * 1.6) * exp(-x * x) * (1.0 - ripple);
	}
	vec2 d = uv - center;
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	const int N = 12;
	for (int i = 0; i < N; i++) {
		float t = float(i) / float(N - 1);
		float s = 1.0 - blur * amount * t;
		float w = 1.0 - t * 0.6;
		vec2 base = center + d * s;
		acc.r += texture(screen_tex, center + d * (s * (1.0 + 0.012 * amount))).r * w;
		acc.g += texture(screen_tex, base).g * w;
		acc.b += texture(screen_tex, center + d * (s * (1.0 - 0.012 * amount))).b * w;
		wsum += w;
	}
	vec3 col = acc / wsum;
	float aspect = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	float r = length(d * vec2(aspect, 1.0));
	col *= mix(vec3(1.0), vec3(0.78, 0.9, 1.25), amount * 0.6);
	col *= 1.0 - smoothstep(0.35, 1.1, r) * 0.55 * amount;
	col += flash * vec3(0.75, 0.88, 1.0) * (1.4 - r);
	// chromatic fringe + faint glow on the ripple ring
	col += ring * vec3(0.25, 0.45, 0.8) * 0.35;
	ALBEDO = col;
	ALPHA = ripple >= 0.0 ? 1.0 : clamp(amount * 0.9 + flash, 0.0, 1.0);
}
