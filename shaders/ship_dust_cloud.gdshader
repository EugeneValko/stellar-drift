shader_type spatial;
// Soft, lit dust / sand / mist puffs for GPUParticles3D (landing dust, water spray mist).
// Billboard in the vertex shader (like BILLBOARD_PARTICLES, rotation from INSTANCE_CUSTOM.x),
// billowy fbm shape per particle (seeded by INSTANCE_ID, evolving with age INSTANCE_CUSTOM.y),
// pseudo-spherical normals so the sun lights one side, soft intersection with the ground
// (depth fade) and a near-camera fade. Particle COLOR (ramp) = tint * alpha.
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, diffuse_lambert_wrap, fog_disabled;

uniform vec3 dust_color : source_color = vec3(0.7, 0.62, 0.5);
uniform float density = 1.0;
uniform float soft_dist = 1.6;
uniform float near_fade = 2.5;
uniform float noise_scale = 1.7;
uniform float edge_breakup = 0.8;
uniform float backlight = 0.45;
uniform float ambient_boost = 0.25;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying float v_seed;
varying float v_age;

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

float fbm(vec2 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += vnoise(p) * a;
		p = p * 2.03 + vec2(17.1, 9.3);
		a *= 0.5;
	}
	return s / 0.9375;
}

void vertex() {
	mat4 mat_world = mat4(normalize(INV_VIEW_MATRIX[0]), normalize(INV_VIEW_MATRIX[1]), normalize(INV_VIEW_MATRIX[2]), MODEL_MATRIX[3]);
	float ang = INSTANCE_CUSTOM.x;
	mat_world = mat_world * mat4(vec4(cos(ang), -sin(ang), 0.0, 0.0), vec4(sin(ang), cos(ang), 0.0, 0.0),
		vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat_world;
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0), vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_seed = fract(float(INSTANCE_ID) * 0.6180339 + 0.13);
	v_age = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float r = length(uv);
	if (r > 1.0) {
		discard;
	}
	// billows: the puff "unrolls" as it ages (noise scale shrinks, field drifts)
	vec2 off = vec2(v_seed * 41.3, v_seed * 17.9);
	vec2 p = uv * noise_scale * (1.0 - 0.3 * v_age) + off;
	float n = fbm(p + vec2(v_age * 0.7, -v_age * 0.4));
	float n2 = fbm(p * 2.3 - vec2(v_age * 1.1, 0.0) + 5.0);
	float shape = 1.0 - smoothstep(0.15, 1.0, r + (n - 0.5) * edge_breakup + (n2 - 0.5) * 0.25);
	float a = shape * shape * COLOR.a * density * (0.55 + 0.6 * n);
	// soft intersection with the scene (ground, hull)
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -vp.z / vp.w;
	float frag_z = -VERTEX.z;
	a *= clamp((scene_z - frag_z) / soft_dist, 0.0, 1.0);
	a *= smoothstep(0.3, near_fade, frag_z);
	if (a < 0.002) {
		discard;
	}
	// pseudo-volume normal (view space) bumped by the billows
	vec3 nrm = normalize(vec3(uv.x + (n - 0.5) * 0.6, uv.y + (n2 - 0.5) * 0.6, 0.55 + 0.45 * (1.0 - r)));
	NORMAL = nrm;
	vec3 base = dust_color * COLOR.rgb;
	ALBEDO = base * (0.8 + 0.35 * n);
	EMISSION = base * ambient_boost * 0.15;
	BACKLIGHT = base * backlight;
	ROUGHNESS = 1.0;
	ALPHA = clamp(a, 0.0, 1.0);
}
