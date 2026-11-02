shader_type spatial;
// Plasma sheath / bow shock and wake around the ship during re-entry.
// Mesh: paraboloid/cone shell around local +Z (apex at z = 0, +Z = downstream),
// UV.y = 0 at the apex -> 1 at the open end, UV.x = angle (0..1).
// Wave 4: 3D flowing turbulence in the shell's local space (no UV cells / seam), filaments that
// break up the shell edge, soft fades everywhere (no visible geometric rim), hot white-yellow
// cap -> orange -> violet tail.
render_mode blend_add, unshaded, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform float time_s = 0.0;
// 0 = bow shock, 1 = wake (long trailing flame)
uniform int mode = 0;
uniform vec3 color_a : source_color = vec3(1.0, 0.55, 0.2);
uniform vec3 color_b : source_color = vec3(0.7, 0.25, 1.0);
uniform float intensity = 3.0;
uniform float scroll = 6.0;
uniform float depth_fade = 2.0;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 v_local;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
				mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
				mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += vnoise(p) * a;
		p = p * 2.07 + vec3(13.7, 5.1, 9.9);
		a *= 0.5;
	}
	return s / 0.9375;
}

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	if (amount < 0.003) {
		discard;
	}
	float v = clamp(UV.y, 0.0, 1.0);
	float facing = clamp(abs(dot(normalize(NORMAL), VIEW)), 0.0, 1.0);
	float rim = 1.0 - facing;
	float t = time_s;
	// soft intersection with the hull/terrain
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	float scene_z = -vp.z / vp.w;
	float soft = clamp((scene_z - (-VERTEX.z)) / depth_fade, 0.0, 1.0);
	vec3 col;
	float a;
	if (mode == 0) {
		// flow streams aft over the shell: stretched along z, domain-warped
		vec3 q = v_local * vec3(0.32, 0.32, 0.12) - vec3(0.0, 0.0, t * scroll * 0.9);
		vec3 w = vec3(fbm(q + 3.1), fbm(q + 7.7), 0.0);
		float n = fbm(q + w * 1.6);
		float fil = smoothstep(0.42, 0.85, n);
		float cap = exp(-v * 9.0) * (0.75 + 0.5 * n);
		// the sheath brightens toward grazing angles, but softly (no hard silhouette line)
		// brightest just inside the silhouette, fading to nothing at the exact grazing edge
		float sheath = pow(rim, 1.4) * (1.0 - smoothstep(0.8, 1.0, rim)) * 1.6
			* (1.0 - smoothstep(0.08, 0.85, v + (n - 0.5) * 0.7));
		a = cap * 1.5 + sheath * (0.08 + 1.5 * fil) + exp(-v * 3.0) * 0.12 * fil;
		float flick = 0.8 + 0.4 * vnoise(vec3(v_local.xy * 0.5, t * 9.0));
		a *= flick;
		col = mix(vec3(1.0, 0.9, 0.72), color_a, smoothstep(0.0, 0.3, v));
		col = mix(col, color_b, smoothstep(0.35, 1.0, v) * 0.75);
	} else {
		vec3 q = v_local * vec3(0.26, 0.26, 0.04) - vec3(0.0, 0.0, t * scroll * 0.35);
		vec3 w = vec3(fbm(q * 1.3 + 1.7), fbm(q * 1.3 + 9.2), 0.0) - 0.5;
		float n = fbm(q + vec3(w.xy * 1.8, 0.0));
		float tongues = smoothstep(0.52, 0.82, n);
		float fade = pow(1.0 - v, 2.0) * smoothstep(0.0, 0.1, v);
		// the shell vanishes toward its silhouette (no cone outline): only tongues of flame
		float body = pow(facing, 1.4);
		a = fade * (0.03 + 1.25 * tongues) * body;
		a *= 1.0 - smoothstep(0.55, 1.0, v + (0.5 - n) * 0.35);
		col = mix(color_a, color_b, smoothstep(0.08, 0.65, v + (n - 0.5) * 0.2));
		col = mix(col, vec3(1.0, 0.85, 0.65), tongues * (1.0 - v) * 0.35);
	}
	ALBEDO = col * a * amount * intensity * soft;
}
