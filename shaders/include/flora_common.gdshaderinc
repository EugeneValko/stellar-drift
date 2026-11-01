// Shared helpers for scatter shaders (flora_*, rock_scatter, crystal_scatter).
//
// Instances come from MultiMeshInstance3D patches (src/planets/scatter/planet_scatter.gd):
//   MODEL_MATRIX  = patch * instance transform; instance local +Y = planet up at the instance
//   INSTANCE_CUSTOM x = random (colour variation / thinning rank), y = random (wind phase),
//                   z = biome moisture (0..1), w = biome snow / cover (0..1)
// Per-patch instance uniforms (set by PlanetScatter):
//   fade_range  (in_begin, in_end, out_begin, out_end) distance fade per instance, metres from camera
//   thin_range  (begin, end, keep_at_end) distance thinning: instances whose rank > keep shrink away
//   patch_origin planet-local patch origin (mod 4096 m) -> spatially coherent, floating-origin safe wind
//   sway_height nominal mesh height of the layer (m)
// Vertex colour layout: see tools/blender/flora_common.py.

instance uniform vec4 fade_range = vec4(0.0, 0.0, 100000.0, 100001.0);
instance uniform vec3 thin_range = vec3(100000.0, 100001.0, 1.0);
instance uniform vec3 patch_origin = vec3(0.0);
// Nominal mesh height (m) of the layer; wind sway amplitude scales with it (and the instance scale).
instance uniform float sway_height = 10.0;

uniform vec3 wind_dir = vec3(1.0, 0.0, 0.35);
uniform float wind_strength = 1.0;
uniform float wind_speed = 1.0;

float flora_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Interleaved gradient noise (stable screen-space dither for fades).
float flora_ign(vec2 frag) {
	return fract(52.9829189 * fract(dot(frag, vec2(0.06711056, 0.00583715))));
}

float flora_ramp(float a, float b, float x) {
	return b > a ? smoothstep(a, b, x) : 1.0;
}

// Per-instance visibility (0 = hidden, 1 = fully shown) from distance to camera.
float flora_instance_fade(vec3 inst_world, vec3 cam_world, float rank) {
	float d = distance(inst_world, cam_world);
	float f = flora_ramp(fade_range.x, fade_range.y, d) * (1.0 - flora_ramp(fade_range.z, fade_range.w, d));
	float keep = mix(1.0, thin_range.z, flora_ramp(thin_range.x, thin_range.y, d));
	f *= clamp((keep - rank) * 12.0 + 1.0, 0.0, 1.0);
	return clamp(f, 0.0, 1.0);
}

// World-space wind offset. sway_w / flutter_w / branch_phase from vertex colour; height = instance height scale.
vec3 flora_wind(vec3 inst_world, vec3 node_world, vec3 up, vec3 nrm, vec3 vtx_rel,
		float sway_w, float flutter_w, float branch_phase, float phase, float sway_amp, float flutter_amp,
		float t) {
	vec3 wd = wind_dir - up * dot(wind_dir, up);
	wd = normalize(wd + vec3(1e-4, 0.0, 0.0));
	vec3 side = cross(up, wd);
	vec3 pp = patch_origin + (inst_world - node_world);
	float tt = t * wind_speed;
	float gust = 0.55 + 0.45 * sin(dot(pp, wd) * 0.045 - tt * 1.6);
	gust *= 0.8 + 0.2 * sin(dot(pp, side) * 0.021 + tt * 0.63);
	float ph = phase * 6.2831;
	float sway = (sin(tt * 1.1 + ph) * 0.55 + sin(tt * 2.37 + ph * 1.7) * 0.2 + 0.6) * gust;
	vec3 off = wd * sway * sway_w * sway_amp;
	off += side * sin(tt * 0.9 + ph * 2.3) * 0.25 * sway_w * sway_amp * gust;
	// branch-level motion (desynchronised by the per-branch phase)
	float bp = branch_phase * 6.2831;
	off += (wd * 0.7 + up * 0.3) * sin(tt * 1.9 + bp + ph) * flutter_w * sway_amp * 0.35 * gust;
	// leaf flutter
	float fl = sin(tt * 8.3 + bp * 3.0 + dot(vtx_rel, vec3(2.3, 3.1, 1.7)) + ph * 5.0);
	off += (nrm * 0.75 + up * 0.25) * fl * flutter_w * flutter_amp * (0.4 + 0.6 * gust);
	return off * wind_strength;
}

// Foliage cards / blades use "volume" normals that often face away from the camera; GGX specular
// explodes at N.V ~ 0 (bright sparkles + bloom). Bend such normals toward the viewer (view space).
vec3 flora_view_safe_normal(vec3 n, vec3 view) {
	float nv = dot(n, view);
	return normalize(n + view * max(0.0, 0.25 - nv) * 1.2);
}
