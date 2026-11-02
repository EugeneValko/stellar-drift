shader_type spatial;
// Wingtip vortex condensation ribbon (ShipTrail, camera-facing strip built on the CPU).
// UV.x = emission time (anchors the noise in the air), UV.y = 0..1 across; COLOR.a = alpha.
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, diffuse_lambert_wrap, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(0.95, 0.97, 1.0);
uniform float opacity = 0.55;
uniform float backlight = 0.6;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	float across = abs(UV.y * 2.0 - 1.0);
	float n = vnoise(vec2(UV.x * 9.0, UV.y * 2.5)) * 0.6 + vnoise(vec2(UV.x * 31.0, UV.y * 5.0 + 3.0)) * 0.4;
	float core = 1.0 - smoothstep(0.05 + 0.35 * n, 1.0, across);
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float soft = clamp((-vp.z / vp.w + VERTEX.z) / 0.6, 0.0, 1.0);
	float a = core * COLOR.a * opacity * (0.55 + 0.7 * n) * soft;
	if (a < 0.002) {
		discard;
	}
	NORMAL = normalize(vec3(0.0, (UV.y - 0.5) * 1.2, 1.0));
	ALBEDO = color;
	BACKLIGHT = color * backlight;
	ROUGHNESS = 1.0;
	ALPHA = clamp(a, 0.0, 1.0);
}
