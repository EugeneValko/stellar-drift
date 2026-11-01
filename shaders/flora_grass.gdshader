// Grass blades, small plants, flowers and glow bulbs (geometry, no alpha: keeps early-z).
//   mode 0 = grass / stems / small leaves, 1 = flower petals, 2 = glow bulbs
// Vertex colour: r = height along the plant (0..1), g = flutter / petal radius, b = AO, a = blade random.
// Distance fade shrinks instances into the ground (no discard).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx,
	world_vertex_coords;

#include "res://shaders/include/flora_common.gdshaderinc"

uniform int mode = 0;
// Ground palette (from PlanetConfig) so blades match the terrain under them.
uniform vec3 color_grass : source_color = vec3(0.2, 0.36, 0.1);
uniform vec3 color_dry : source_color = vec3(0.5, 0.46, 0.26);
uniform vec3 color_base : source_color = vec3(0.07, 0.1, 0.03);
uniform vec3 color_tip_dry : source_color = vec3(0.62, 0.55, 0.3);
uniform float tip_dryness = 0.35;
uniform float brightness = 1.0;
// Flower palette (picked per instance)
uniform vec3 flower_a : source_color = vec3(0.95, 0.92, 1.0);
uniform vec3 flower_b : source_color = vec3(1.0, 0.75, 0.15);
uniform vec3 flower_c : source_color = vec3(0.75, 0.35, 0.95);
uniform vec3 flower_d : source_color = vec3(1.0, 0.42, 0.3);
uniform vec3 flower_center : source_color = vec3(0.35, 0.22, 0.05);
uniform vec3 glow_color : source_color = vec3(0.3, 0.95, 0.85);
uniform float glow_energy = 1.5;
uniform float bend = 0.18;          // m of tip bend at full gust
uniform float flutter_amp = 0.03;
uniform float translucency = 0.6;

varying float v_t;
varying float v_g;
varying float v_ao;
varying vec3 v_col;
varying float v_rnd;

void vertex() {
	vec3 inst = MODEL_MATRIX[3].xyz;
	vec3 upv = MODEL_MATRIX[1].xyz;
	float hs = length(upv);
	vec3 up = upv / hs;
	float fade = flora_instance_fade(inst, CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.x);
	vec3 rel = VERTEX - inst;
	float h2 = COLOR.r * COLOR.r;
	VERTEX += flora_wind(inst, NODE_POSITION_WORLD, up, NORMAL, rel, h2, COLOR.g * 0.6, COLOR.a,
		INSTANCE_CUSTOM.y + COLOR.a * 0.15, bend * hs, flutter_amp, TIME);
	// shrink into the ground with distance (and collapse when hidden)
	VERTEX = inst + (VERTEX - inst) * fade;
	v_t = COLOR.r;
	v_g = COLOR.g;
	v_ao = COLOR.b;
	v_rnd = COLOR.a;
	float moist = INSTANCE_CUSTOM.z;
	vec3 g = mix(color_dry, color_grass, smoothstep(0.25, 0.6, moist));
	g *= 0.82 + 0.36 * fract(INSTANCE_CUSTOM.x * 5.31);
	if (mode == 1) {
		float k = fract(INSTANCE_CUSTOM.x * 3.7) * 4.0;
		vec3 fc = k < 1.0 ? flower_a : (k < 2.0 ? flower_b : (k < 3.0 ? flower_c : flower_d));
		g = fc;
	}
	v_col = g * brightness;
	// grass normals: bias toward the local up so blades shade like the ground under them
	if (mode == 0) {
		NORMAL = normalize(mix(NORMAL, up, 0.45));
	}
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	NORMAL = flora_view_safe_normal(NORMAL, VIEW);
	vec3 c = v_col;
	vec3 emit = vec3(0.0);
	if (mode == 0) {
		c = mix(color_base * (0.8 + 0.4 * v_rnd), c, smoothstep(0.0, 0.55, v_t));
		c = mix(c, color_tip_dry * brightness, smoothstep(0.55, 1.0, v_t) * tip_dryness * (0.5 + v_rnd));
		// slight midrib highlight across the blade
		c *= 0.9 + 0.2 * (1.0 - abs(UV.x - 0.5) * 2.0);
	} else if (mode == 1) {
		c = mix(flower_center, c, smoothstep(0.2, 0.45, v_g));
		c *= 0.85 + 0.25 * v_g;
	} else {
		c = mix(glow_color * 0.4, vec3(0.9, 1.0, 0.95), v_g * 0.2);
		emit = glow_color * glow_energy * (0.35 + 0.65 * v_g);
	}
	c = max(c, vec3(0.0));
	ALBEDO = c;
	ROUGHNESS = mode == 2 ? 0.35 : 0.7;
	SPECULAR = 0.25;
	AO = v_ao;
	AO_LIGHT_AFFECT = 0.6;
	BACKLIGHT = c * translucency;
	EMISSION = emit;
}
