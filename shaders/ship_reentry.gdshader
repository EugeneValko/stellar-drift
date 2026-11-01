shader_type spatial;
// Re-entry heating overlay (GeometryInstance3D.material_overlay on every ship mesh).
// Windward faces and convex leading edges (vertex colour R = convexity, baked in Blender)
// glow orange-white; a violet plasma fringe at grazing angles; streaks flow aft along the hull.
render_mode blend_add, unshaded, cull_back, depth_draw_never, depth_test_default, fog_disabled;

uniform float heat : hint_range(0.0, 1.0) = 0.0;
// Direction of travel in model space (unit). Air hits faces whose normal points along it.
uniform vec3 flow_dir = vec3(0.0, 0.0, -1.0);
uniform float time_s = 0.0;
uniform float grow = 0.06;
uniform vec3 hot_color : source_color = vec3(1.0, 0.42, 0.12);
uniform vec3 core_color : source_color = vec3(1.0, 0.86, 0.62);
uniform vec3 plasma_color : source_color = vec3(1.0, 0.38, 0.55);
uniform float intensity = 5.0;

varying vec3 v_pos;
varying vec3 v_nrm;
varying float v_edge;

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

void vertex() {
	VERTEX += NORMAL * grow * heat;
	v_pos = VERTEX;
	v_nrm = NORMAL;
	v_edge = COLOR.r;
}

void fragment() {
	if (heat < 0.002) {
		discard;
	}
	vec3 n = normalize(v_nrm);
	vec3 fd = normalize(flow_dir);
	float facing = dot(n, fd);
	float wind = smoothstep(-0.05, 0.85, facing);
	float edge = smoothstep(0.35, 0.9, v_edge) * smoothstep(-0.4, 0.4, facing);
	// streaks flowing aft: coordinate along the flow + slow lateral variation
	float along = dot(v_pos, fd);
	vec3 q = v_pos * vec3(1.6, 1.6, 1.6);
	float streak = vnoise(vec3(q.x * 1.3, q.y * 1.3, along * 0.35 + time_s * 9.0) + q.zxy * 0.2);
	float flick = 0.75 + 0.5 * vnoise(vec3(v_pos * 0.7 + time_s * vec3(0.0, 0.0, 14.0)));
	float h = heat;
	float glow = (wind * 0.55 + edge * 1.6) * flick * mix(0.6, 1.3, streak);
	vec3 col = mix(hot_color, core_color, clamp(glow * h * 0.8, 0.0, 1.0));
	// view-grazing plasma fringe
	float fres = pow(1.0 - clamp(abs(dot(NORMAL, VIEW)), 0.0, 1.0), 3.0);
	vec3 fringe = plasma_color * fres * smoothstep(-0.2, 0.6, facing) * 0.5;
	ALBEDO = (col * glow * h * h + fringe * h * h * flick) * intensity;
}
