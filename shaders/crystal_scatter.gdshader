// Crystal formations (glowing, Ignis / Vex) and ice shards (Glacia). Opaque (no screen reads):
// fresnel rim + a parallax "inner glow" fake the depth of a translucent crystal.
//   mode 0 = glowing crystal, 1 = ice
// Vertex colour: r = AO, g = position along the crystal (0 base -> 1 tip), b = per-crystal random.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/flora_common.gdshaderinc"

uniform int mode = 0;
uniform vec3 color_body : source_color = vec3(0.35, 0.06, 0.12);
uniform vec3 color_glow : source_color = vec3(1.0, 0.35, 0.15);
uniform vec3 color_rim : source_color = vec3(1.0, 0.75, 0.5);
uniform float glow_energy = 3.0;
uniform float pulse = 0.15;
uniform float roughness = 0.12;
uniform sampler2D tex_noise : repeat_enable, filter_linear_mipmap;

varying vec3 v_obj;
varying float v_fade;
varying vec4 v_col;
varying float v_rnd;

void vertex() {
	vec3 inst = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	v_fade = flora_instance_fade(inst, CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.x);
	v_obj = VERTEX + vec3(INSTANCE_CUSTOM.x * 31.0, 0.0, INSTANCE_CUSTOM.y * 17.0);
	v_col = COLOR;
	v_rnd = fract(INSTANCE_CUSTOM.x * 3.1 + COLOR.b);
	if (v_fade <= 0.0) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	if (v_fade < 0.999 && v_fade < flora_ign(FRAGCOORD.xy)) {
		discard;
	}
	float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 3.0);
	// "inner" layer: noise sampled behind the surface along the view ray
	vec3 vo = v_obj - (INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz * 0.35;
	float inner = texture(tex_noise, vo.xy * 0.45 + vo.z * 0.2).r * 0.6
		+ texture(tex_noise, vo.zy * 0.9).g * 0.4;
	float tip = v_col.g;
	if (mode == 0) {
		float pl = 1.0 + pulse * sin(TIME * 1.4 + v_rnd * 6.28);
		vec3 core = color_glow * (0.25 + 1.6 * tip * tip) * (0.6 + 0.8 * inner);
		ALBEDO = color_body * (0.6 + 0.6 * inner);
		EMISSION = (core * (1.0 - fres * 0.5) + color_rim * fres * 0.6) * glow_energy * pl * (0.4 + 0.6 * v_col.r);
		ROUGHNESS = roughness;
		SPECULAR = 0.6;
	} else {
		vec3 deep = color_body;
		vec3 pale = color_rim;
		vec3 c = mix(deep, pale, clamp(fres * 1.2 + inner * 0.35 + tip * 0.25, 0.0, 1.0));
		ALBEDO = c * (0.75 + 0.25 * v_col.r);
		EMISSION = color_glow * glow_energy * (0.2 + 0.8 * inner) * (1.0 - fres) * 0.15;
		ROUGHNESS = roughness + inner * 0.1;
		SPECULAR = 0.7;
		BACKLIGHT = c * 0.4;
	}
	AO = v_col.r;
	AO_LIGHT_AFFECT = 0.3;
}
