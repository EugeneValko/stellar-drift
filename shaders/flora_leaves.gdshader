// Foliage cards (needles / broad leaves / fronds) for scatter trees and bushes.
// Leaf silhouettes are procedural (no textures): alpha-scissor patterns in card UV space.
//   pattern 0 = pinnate (needle sprays, fern / palm fronds), 1 = broad leaf fan
// UV: x across the card, 1 - y along it (stem -> tip). See tools/blender/flora_common.py.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert_wrap, specular_schlick_ggx,
	world_vertex_coords;

#include "res://shaders/include/flora_common.gdshaderinc"

uniform int pattern = 0;
uniform float leaflets = 14.0;      // leaflets per side along the card
uniform float slant = 0.7;          // leaflet sweep toward the tip
uniform float duty = 0.42;          // leaflet width (0..1 of the spacing)
uniform float rachis = 0.035;       // central stem half width (0..1 of half card)
uniform float envelope_round = 1.0; // 0 = pointed spray, 1 = rounded frond
uniform int broad_leaves = 6;

uniform vec3 color_a : source_color = vec3(0.16, 0.32, 0.26);   // mature
uniform vec3 color_b : source_color = vec3(0.3, 0.5, 0.36);    // young tips / lighter instances
uniform vec3 color_dry : source_color = vec3(0.6, 0.5, 0.25);   // dry / autumn instances
uniform float dry_amount = 0.0;          // global push toward color_dry by (1 - moisture)
uniform float variation = 0.35;
uniform float translucency = 0.55;
uniform float sway_amp = 0.02;            // tip sway, fraction of the plant height
uniform float flutter_amp = 0.05;
uniform float roughness = 0.62;
uniform int debug_mode = 0;   // 1 = no backlight, 2 = no specular, 3 = albedo only

varying float v_fade;
varying vec3 v_tint;
varying float v_ao;
varying float v_tip;
varying float v_glow;

void vertex() {
	vec3 inst = MODEL_MATRIX[3].xyz;
	vec3 upv = MODEL_MATRIX[1].xyz;
	float hs = length(upv);
	vec3 up = upv / hs;
	v_fade = flora_instance_fade(inst, CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.x);
	vec3 off = flora_wind(inst, NODE_POSITION_WORLD, up, NORMAL, VERTEX - inst, COLOR.r, COLOR.g, COLOR.a,
		INSTANCE_CUSTOM.y, sway_amp * hs * sway_height, flutter_amp, TIME);
	VERTEX += off;
	if (v_fade <= 0.0) {
		VERTEX = inst;
	}
	// per-instance colour: mature/young mix + dryness from biome moisture
	float r = INSTANCE_CUSTOM.x;
	vec3 base = mix(color_a, color_b, clamp(r * variation * 2.0, 0.0, 1.0));
	float dry = clamp(dry_amount * (1.0 - INSTANCE_CUSTOM.z) * 1.6 - 0.15 + (fract(r * 7.13) - 0.5) * 0.3, 0.0, 1.0);
	v_tint = mix(base, color_dry, dry * dry);
	v_tint = flora_region_tint(v_tint, INSTANCE_CUSTOM.w, r);
	v_tint *= 0.85 + 0.3 * fract(r * 13.7);
	// a share of the plants glow faintly at their tips at night
	v_glow = night_glow > 0.0 ? flora_night(up) * step(fract(r * 5.71), 0.35) * night_glow : 0.0;
	v_ao = COLOR.b;
	v_tip = COLOR.g;
}

float pinnate(vec2 uv, out float vein) {
	float t = 1.0 - uv.y;
	float x = uv.x * 2.0 - 1.0;
	float ax = abs(x);
	// card envelope: pointed (needle spray) or rounded (frond)
	float env_p = (1.0 - t * t) * smoothstep(0.0, 0.1, t);
	float env_r = sin(3.14159 * clamp(t * 0.97 + 0.03, 0.0, 1.0));
	float env = mix(env_p, pow(max(env_r, 0.0), 0.6), envelope_round) * 0.98;
	float s = t * leaflets - ax * slant * leaflets * 0.08;
	float id = floor(s);
	float f = fract(s);
	float h = flora_hash(vec2(id, sign(x)));
	float envi = env * (0.78 + 0.22 * h);
	// leaflets taper toward their tips; widen with distance so coverage survives minification
	float aa = clamp(fwidth(s) * 1.2, 0.0, 0.6);
	float w = duty * (1.0 - pow(clamp(ax / max(envi, 1e-3), 0.0, 1.0), 2.0)) + aa;
	float leaf = step(abs(f - 0.5) * 2.0, w) * step(ax, envi);
	float stem = step(ax, rachis * (1.0 - t * 0.6) + fwidth(x) * 0.5) * step(t, 0.99);
	vein = clamp(1.0 - ax / max(envi, 1e-3), 0.0, 1.0);
	return max(leaf, stem);
}

float broad(vec2 uv, out float vein, out float lid) {
	vec2 p = vec2(uv.x - 0.5, 1.0 - uv.y);
	float a = 0.0;
	vein = 0.0;
	lid = 0.0;
	float aa = fwidth(p.x) * 1.5;
	for (int k = 0; k < broad_leaves; k++) {
		float fk = float(k) / float(broad_leaves - 1);
		float h = flora_hash(vec2(float(k), 3.7));
		float ang = (fk - 0.5) * 2.2 + (h - 0.5) * 0.3;
		float len = mix(0.52, 0.95, 1.0 - abs(fk - 0.5) * 1.6) * (0.85 + 0.15 * h);
		vec2 o = vec2((fk - 0.5) * 0.12, 0.02 + 0.12 * abs(fk - 0.5));
		vec2 dir = vec2(sin(ang), cos(ang));
		vec2 q = p - o;
		float along = dot(q, dir);
		float across = dot(q, vec2(dir.y, -dir.x));
		float t = along / len;
		float wid = len * 0.24 * sin(3.14159 * clamp(t, 0.0, 1.0)) * (1.0 - 0.35 * t);
		float inside = step(0.0, t) * step(t, 1.0) * step(abs(across), wid + aa);
		if (inside > 0.5 && a < 0.5) {
			vein = clamp(1.0 - abs(across) / max(wid, 1e-3), 0.0, 1.0);
			lid = h;
		}
		a = max(a, inside);
	}
	return a;
}

void fragment() {
	float vein;
	float lid = 0.5;
	float a = pattern == 0 ? pinnate(UV, vein) : broad(UV, vein, lid);
	if (v_fade < 0.999 && v_fade < flora_ign(FRAGCOORD.xy)) {
		a = 0.0;
	}
	ALPHA = a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	// keep the baked "volume" normal on both sides of the card
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	NORMAL = flora_view_safe_normal(NORMAL, VIEW);
	vec3 c = v_tint * mix(0.8, 1.12, vein);
	c *= 0.9 + 0.2 * lid;
	c *= mix(0.55, 1.0, v_ao);   // darker crown interior (depth)
	c = mix(c, c * vec3(1.15, 1.2, 0.9), v_tip * 0.35);
	c = max(c, vec3(0.0));
	ALBEDO = c;
	ROUGHNESS = roughness;
	SPECULAR = 0.22;
	AO = v_ao;
	AO_LIGHT_AFFECT = 0.55;
	BACKLIGHT = c * translucency * (0.5 + 0.5 * v_ao);
	if (v_glow > 0.0) {
		EMISSION = night_glow_color * v_glow * smoothstep(0.55, 1.0, v_tip) * mix(0.6, 1.0, vein);
	}
	if (debug_mode == 1) {
		BACKLIGHT = vec3(0.0);
	} else if (debug_mode == 2) {
		SPECULAR = 0.0;
		ROUGHNESS = 1.0;
	} else if (debug_mode == 3) {
		BACKLIGHT = vec3(0.0);
		SPECULAR = 0.0;
		ALBEDO = vec3(0.0);
		EMISSION = c;
	}
}
