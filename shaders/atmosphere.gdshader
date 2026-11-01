// Atmosphere in-scattering pass (additive). Drawn on the BACK faces of a proxy sphere slightly
// larger than the atmosphere top, with depth test off, so it covers the planet from outside and
// the whole view from inside. The ray stops at the opaque scene depth -> aerial perspective.
// Paired with atmosphere_transmittance.gdshader (multiplicative pass drawn just before).
shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_add, fog_disabled;

#include "res://shaders/include/atmosphere_common.gdshaderinc"

uniform int atmo_debug = 0;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

void fragment() {
	vec3 rd = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	vec3 ro = CAMERA_POSITION_WORLD - NODE_POSITION_WORLD;
	float sd = sd_scene_distance(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX);
	vec3 T;
	vec3 L = atmo_scatter(ro, rd, sd, atmo_steps, sd_ign(FRAGCOORD.xy), T);
	ALBEDO = L;
	if (atmo_debug == 1) ALBEDO = vec3(sd / 200000.0, float(atmo_steps) / 16.0, length(ro) / 200000.0);
	if (atmo_debug == 2) ALBEDO = abs(sun_direction);
}
