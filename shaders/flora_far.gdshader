// Distant tree hulls (LOD2 meshes, ~50 tris). Solid, noise-broken "canopy" shading;
// cross-fades (dither) with the near LOD ring via fade_range.
// Vertex colour: r = sway, g = 1 foliage, b = AO, a = 1 foliage / 0 trunk.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert_wrap, specular_schlick_ggx, world_vertex_coords;

#include "res://shaders/include/flora_common.gdshaderinc"

uniform vec3 color_a : source_color = vec3(0.06, 0.16, 0.11);
uniform vec3 color_b : source_color = vec3(0.16, 0.32, 0.2);
uniform vec3 color_dry : source_color = vec3(0.42, 0.3, 0.1);
uniform float dry_amount = 0.0;
uniform float variation = 0.35;
uniform vec3 color_trunk : source_color = vec3(0.12, 0.09, 0.07);
uniform float brightness = 0.85;
uniform float clump_scale = 1.6;
uniform sampler2D tex_noise : repeat_enable, filter_linear_mipmap;

varying float v_fade;
varying vec3 v_tint;
varying vec3 v_obj;
varying float v_ao;
varying float v_fol;

void vertex() {
	vec3 inst = MODEL_MATRIX[3].xyz;
	vec3 upv = MODEL_MATRIX[1].xyz;
	float hs = length(upv);
	v_fade = flora_instance_fade(inst, CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.x);
	v_obj = (VERTEX - inst) / hs + vec3(INSTANCE_CUSTOM.x * 17.0, 0.0, INSTANCE_CUSTOM.y * 23.0);
	if (v_fade <= 0.0) {
		VERTEX = inst;
	}
	float r = INSTANCE_CUSTOM.x;
	vec3 base = mix(color_a, color_b, clamp(r * variation * 2.0, 0.0, 1.0));
	float dry = clamp(dry_amount * (1.0 - INSTANCE_CUSTOM.z) * 1.6 - 0.15 + (fract(r * 7.13) - 0.5) * 0.3, 0.0, 1.0);
	v_tint = mix(base, color_dry, dry * dry) * (0.85 + 0.3 * fract(r * 13.7)) * brightness;
	v_ao = COLOR.b;
	v_fol = COLOR.a;
}

void fragment() {
	if (v_fade < 0.999 && v_fade < flora_ign(FRAGCOORD.xy)) {
		discard;
	}
	vec3 p = v_obj / clump_scale;
	float n = texture(tex_noise, p.xz * 0.37 + p.y * 0.21).r * 0.6 + texture(tex_noise, p.xy * 0.53).a * 0.4;
	float clump = smoothstep(0.3, 0.75, n);
	vec3 c = mix(v_tint * 0.55, v_tint * 1.15, clump);
	c = mix(color_trunk, c, v_fol);
	ALBEDO = c;
	ROUGHNESS = 0.8;
	SPECULAR = 0.2;
	AO = mix(v_ao, 1.0, 0.25) * (0.7 + 0.3 * clump);
	AO_LIGHT_AFFECT = 0.5;
	BACKLIGHT = c * 0.25 * v_fol;
}
