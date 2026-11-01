// Tree bark for scatter trees (trunks, limbs, twigs). Sways with the same wind as the foliage.
//   style 0 = fissured (conifer / broadleaf), 1 = ringed palm trunk
// UV: x around the trunk (0..1), y along it in units of ~1-1.6 m.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx, world_vertex_coords;

#include "res://shaders/include/flora_common.gdshaderinc"

uniform int style = 0;
uniform vec3 color_a : source_color = vec3(0.22, 0.17, 0.13);
uniform vec3 color_b : source_color = vec3(0.09, 0.07, 0.06);
uniform vec3 color_moss : source_color = vec3(0.12, 0.2, 0.06);
uniform float moss_amount = 0.3;
uniform float sway_amp = 0.02;
uniform sampler2D tex_noise : repeat_enable, filter_linear_mipmap;

varying float v_fade;
varying float v_ao;
varying float v_rand;
varying float v_moss;

void vertex() {
	vec3 inst = MODEL_MATRIX[3].xyz;
	vec3 upv = MODEL_MATRIX[1].xyz;
	float hs = length(upv);
	vec3 up = upv / hs;
	v_fade = flora_instance_fade(inst, CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.x);
	VERTEX += flora_wind(inst, NODE_POSITION_WORLD, up, NORMAL, VERTEX - inst, COLOR.r, COLOR.g, COLOR.a,
		INSTANCE_CUSTOM.y, sway_amp * hs * sway_height, 0.0, TIME);
	if (v_fade <= 0.0) {
		VERTEX = inst;
	}
	v_ao = COLOR.b;
	v_rand = INSTANCE_CUSTOM.x;
	// moss on the shaded, wet side near the ground
	v_moss = moss_amount * INSTANCE_CUSTOM.z * (1.0 - COLOR.r) * clamp(0.6 - dot(NORMAL, up) * 0.5, 0.0, 1.0);
}

void fragment() {
	if (v_fade < 0.999 && v_fade < flora_ign(FRAGCOORD.xy)) {
		discard;
	}
	vec2 uv = UV + vec2(v_rand * 3.0, v_rand * 11.0);
	vec3 c;
	float rough = 0.9;
	float bump = 0.0;
	if (style == 1) {
		// palm: leaf-scar rings + fibrous vertical streaks
		float ring = fract(uv.y * 2.6);
		float scar = smoothstep(0.0, 0.12, ring) * smoothstep(1.0, 0.75, ring);
		float fib = texture(tex_noise, vec2(uv.x * 6.0, uv.y * 0.4)).a;
		c = mix(color_b, color_a, scar * 0.7 + fib * 0.3);
		bump = scar;
	} else {
		// fissured bark: vertically stretched noise ridges
		float n1 = texture(tex_noise, vec2(uv.x * 3.0, uv.y * 0.35)).b;
		float n2 = texture(tex_noise, vec2(uv.x * 9.0, uv.y * 1.1)).r;
		float ridge = smoothstep(0.35, 0.7, n1 * 0.7 + n2 * 0.5);
		c = mix(color_b, color_a, ridge);
		c *= 0.85 + 0.3 * texture(tex_noise, uv * vec2(1.0, 0.2)).a;
		bump = ridge;
	}
	c = mix(c, color_moss, clamp(v_moss * 2.0, 0.0, 1.0));
	ALBEDO = c;
	ROUGHNESS = rough;
	SPECULAR = 0.25;
	AO = v_ao * (0.75 + 0.25 * bump);
	AO_LIGHT_AFFECT = 0.4;
}
