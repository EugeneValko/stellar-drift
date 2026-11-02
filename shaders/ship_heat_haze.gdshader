shader_type spatial;
// Screen-space heat shimmer: refracts the opaque scene behind a mesh (engine jets: cylinder
// whose UV.y runs 0 at the nozzle -> 1 downstream; re-entry: the plasma wake shell).
// Offsets SCREEN_UV by flowing noise in the mesh's local space, weighted by a soft mask
// (axial fade, centre-of-jet facing), shrinking with distance; never samples pixels that are in
// front of the haze (keeps the hull edge clean).
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform float strength : hint_range(0.0, 2.0) = 0.0;
uniform float time_s = 0.0;
uniform float scroll = 6.0;
uniform float freq = 1.6;
uniform float v_start = 0.03;
uniform float v_end = 0.75;
uniform float max_offset = 0.012;
uniform vec3 tint : source_color = vec3(1.0);
// local direction the shimmer flows along (cylinder jet: -Y, re-entry wake shell: +Z)
uniform vec3 flow_axis = vec3(0.0, -1.0, 0.0);

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

float lin_depth(vec2 uv, mat4 inv_proj) {
	float d = textureLod(depth_tex, uv, 0.0).r;
	vec4 vp = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -vp.z / vp.w;
}

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	if (strength < 0.002) {
		discard;
	}
	float v = clamp(UV.y, 0.0, 1.0);
	float facing = abs(dot(normalize(NORMAL), VIEW));
	float mask = smoothstep(0.0, v_start + 0.001, v) * (1.0 - smoothstep(v_end * 0.5, v_end, v)) * pow(facing, 1.2);
	float frag_z = -VERTEX.z;
	// the scene must be behind the haze surface
	float scene_z = lin_depth(SCREEN_UV, INV_PROJECTION_MATRIX);
	mask *= clamp((scene_z - frag_z) / 1.5, 0.0, 1.0);
	if (mask < 0.002) {
		discard;
	}
	vec3 q = v_local * freq;
	q -= flow_axis * time_s * scroll;
	float nx = vnoise(q) + 0.5 * vnoise(q * 2.1 + 7.3);
	float ny = vnoise(q + vec3(19.1, 3.7, 11.3)) + 0.5 * vnoise(q * 2.3 + 1.9);
	vec2 off = (vec2(nx, ny) / 1.5 - 0.5) * 2.0;
	float dist_k = clamp(10.0 / max(frag_z, 0.1), 0.08, 1.2);
	vec2 uv2 = SCREEN_UV + off * max_offset * strength * mask * dist_k;
	// don't pull in foreground pixels (hull in front of the jet)
	if (lin_depth(uv2, INV_PROJECTION_MATRIX) < frag_z) {
		uv2 = SCREEN_UV;
	}
	ALBEDO = textureLod(screen_tex, uv2, 0.0).rgb * mix(vec3(1.0), tint, mask * strength * 0.3);
	ALPHA = 1.0;
}
