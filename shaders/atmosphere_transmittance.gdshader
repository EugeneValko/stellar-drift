// Atmosphere transmittance pass (multiplicative, chromatic): dst *= T(view ray).
// Reddens the sun disk / distant terrain at sunset. See atmosphere.gdshader.
shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_mul, fog_disabled;

#include "res://shaders/include/atmosphere_common.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

void fragment() {
	vec3 rd = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	float S = sd_node_scale(MODEL_MATRIX);   // scaled-space proxy: work in body units
	vec3 ro = (CAMERA_POSITION_WORLD - NODE_POSITION_WORLD) / S;
	float sd = sd_scene_distance(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX) / S;
	ALBEDO = atmo_transmittance(ro, rd, sd, atmo_steps, sd_ign(FRAGCOORD.xy));
}
