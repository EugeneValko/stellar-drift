// Solar prominence loops: plasma flowing along generated arc tubes (src/space/star.gd).
// UV.x = position along the arc (0..1), UV.y = around the tube, UV2.x = strand id.
// Soft view-dependent edges make the tube read as a glowing volume; thread-like strands flow
// along the arc. Additive HDR so the loops bloom against space and the corona.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://shaders/space_noise.gdshaderinc"

uniform float intensity : hint_range(0.0, 40.0) = 4.0;
uniform vec3 color_hot = vec3(1.0, 0.72, 0.36);
uniform vec3 color_cool = vec3(1.0, 0.22, 0.06);
uniform float star_radius = 400000.0;
uniform float wiggle = 0.012;              // vertex turbulence, in star radii
uniform float time_scale = 1.0;
uniform float flow_speed = 0.06;

varying float v_id;

void vertex() {
	v_id = UV2.x;
	// slow turbulent wobble of the plasma ropes (stronger toward the loop top)
	float tt = TIME * time_scale * 0.05;
	vec3 q = VERTEX / star_radius * 6.0 + vec3(v_id * 3.1, tt, -tt);
	vec3 w = vec3(sn_gnoise(q), sn_gnoise(q + 17.3), sn_gnoise(q + 41.7));
	VERTEX += w * wiggle * star_radius * sin(3.14159 * UV.x);
}

void fragment() {
	float t = TIME * time_scale;
	float s = UV.x;
	float a = UV.y;
	// soft tube edge (fresnel-like)
	float nv = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float body = pow(nv, 2.2);
	// strands flowing along the arc toward the footpoints
	float flow = s * 9.0 - t * flow_speed * 9.0;
	vec3 p = vec3(flow, a * 2.0, v_id * 13.7);
	vec2 ring = vec2(cos(a * 6.2831853), sin(a * 6.2831853)) * 1.6;
	float strands = sn_fbm(vec3(s * 2.5 - t * flow_speed * 3.0, ring.x, ring.y + v_id * 7.1), 4, 0.55) * 0.5 + 0.5;
	float knots = sn_fbm(p, 4, 0.6) * 0.5 + 0.5;
	float dens = smoothstep(0.35, 0.8, strands) * (0.3 + 1.2 * knots * knots);
	// fade at footpoints into the photosphere, slightly thinner at the top
	float foot = smoothstep(0.0, 0.07, s) * smoothstep(1.0, 0.93, s);
	float d = dens * body * foot;
	vec3 col = mix(color_cool, color_hot, smoothstep(0.4, 1.0, dens * body));
	ALBEDO = col * intensity * d;
}
