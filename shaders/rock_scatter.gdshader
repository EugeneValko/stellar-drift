// Scatter rocks / boulders / basalt columns. Object-space triplanar detail (scaled, offset per instance:
// no precision issues, no two boulders alike), detail normals, and a cover layer (moss / snow / dust)
// on faces that point toward the planet up.
// Vertex colour: r = baked AO, b = variant random.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://shaders/include/flora_common.gdshaderinc"

uniform int style = 0;                // 0 = rock, 1 = basalt columns (joints), 2 = porous volcanic
uniform vec3 color_a : source_color = vec3(0.4, 0.36, 0.32);
uniform vec3 color_b : source_color = vec3(0.25, 0.23, 0.22);
uniform vec3 color_cover : source_color = vec3(0.3, 0.4, 0.14);   // moss / dust
uniform vec3 color_snow : source_color = vec3(0.93, 0.95, 1.0);
uniform float cover_amount = 0.5;     // moss/dust strength (scaled by instance moisture)
uniform float snow_amount = 1.0;      // snow strength (scaled by instance snow)
uniform float detail_scale = 0.8;     // m per noise tile
uniform float normal_strength = 1.0;
uniform float roughness = 0.88;
uniform vec3 emission_color : source_color = vec3(1.0, 0.3, 0.05);
uniform float emission_energy = 0.0;  // glowing cracks (volcanic)
uniform sampler2D tex_noise : repeat_enable, filter_linear_mipmap;
uniform sampler2D tex_rock : hint_normal, repeat_enable, filter_linear_mipmap;

varying vec3 v_obj;
varying vec3 v_on;
varying vec3 v_bx;
varying vec3 v_by;
varying vec3 v_bz;
varying vec3 v_up;
varying float v_fade;
varying vec4 v_custom;
varying float v_ao;

vec3 tri_w(vec3 n) {
	vec3 w = pow(abs(n), vec3(6.0));
	return w / (w.x + w.y + w.z);
}

vec4 tri(sampler2D t, vec3 p, vec3 w) {
	return texture(t, p.zy) * w.x + texture(t, p.xz) * w.y + texture(t, p.xy) * w.z;
}

vec3 tri_nrm(sampler2D t, vec3 p, vec3 n, vec3 w, float s) {
	vec3 tx = texture(t, p.zy).xyz * 2.0 - 1.0;
	vec3 ty = texture(t, p.xz).xyz * 2.0 - 1.0;
	vec3 tz = texture(t, p.xy).xyz * 2.0 - 1.0;
	tx.xy *= s; ty.xy *= s; tz.xy *= s;
	vec3 nx = vec3(tx.xy + n.zy, abs(tx.z) * n.x);
	vec3 ny = vec3(ty.xy + n.xz, abs(ty.z) * n.y);
	vec3 nz = vec3(tz.xy + n.xy, abs(tz.z) * n.z);
	return normalize(nx.zyx * w.x + ny.xzy * w.y + nz.xyz * w.z);
}

void vertex() {
	vec3 inst = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float s = length(MODEL_MATRIX[0].xyz);
	v_fade = flora_instance_fade(inst, CAMERA_POSITION_WORLD, INSTANCE_CUSTOM.x);
	v_obj = VERTEX * s + vec3(INSTANCE_CUSTOM.x * 61.0, INSTANCE_CUSTOM.y * 13.0, INSTANCE_CUSTOM.x * 29.0);
	v_on = NORMAL;
	v_bx = normalize(MODEL_MATRIX[0].xyz);
	v_by = normalize(MODEL_MATRIX[1].xyz);
	v_bz = normalize(MODEL_MATRIX[2].xyz);
	// instance +Y = planet up (plus the small random tilt) — good enough for the cover mask
	v_up = v_by;
	v_custom = INSTANCE_CUSTOM;
	v_ao = COLOR.r;
	if (v_fade <= 0.0) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	if (v_fade < 0.999 && v_fade < flora_ign(FRAGCOORD.xy)) {
		discard;
	}
	vec3 on = normalize(v_on);
	vec3 w = tri_w(on);
	vec3 p = v_obj / detail_scale;
	vec4 n0 = tri(tex_noise, p * 0.25, w);
	vec4 n1 = tri(tex_noise, p, w);
	float var = v_custom.x;
	vec3 c = mix(color_a, color_b, clamp(n0.b * 0.9 + n1.r * 0.4 - 0.25 + (var - 0.5) * 0.5, 0.0, 1.0));
	c *= 0.8 + 0.4 * n1.a;
	float rough = roughness;
	if (style == 1) {
		// columnar joints: horizontal cracks and darker vertical edges
		float j = fract(v_obj.y * 1.3 + n0.r * 0.6);
		c *= mix(0.55, 1.0, smoothstep(0.0, 0.06, j));
		c *= 0.85 + 0.15 * smoothstep(0.2, 0.8, n1.g);
	} else if (style == 2) {
		float pores = smoothstep(0.18, 0.05, n1.g);
		c *= 1.0 - pores * 0.6;
		rough = mix(rough, 1.0, pores);
	}
	// detail normal (object space -> world)
	vec3 nd = tri_nrm(tex_rock, p, on, w, normal_strength);
	nd = tri_nrm(tex_rock, p * 0.25, nd, w, normal_strength * 0.8);
	vec3 nw = normalize(mat3(v_bx, v_by, v_bz) * nd);
	// cover layer on up-facing faces (moss in wet areas, snow where the biome is snowy)
	float top = dot(nw, normalize(v_up));
	float edge = n1.r * 0.35 + n0.a * 0.25;
	float moss = smoothstep(0.55, 0.9, top + edge - 0.2) * clamp(cover_amount * (0.3 + v_custom.z), 0.0, 1.0);
	float snow = smoothstep(0.25, 0.55, top + edge * 0.6 - 0.1) * clamp(snow_amount * v_custom.w * 1.5, 0.0, 1.0);
	c = mix(c, color_cover * (0.75 + 0.5 * n1.a), moss);
	c = mix(c, color_snow * (0.92 + 0.08 * n1.r), snow);
	rough = mix(rough, 0.95, moss);
	rough = mix(rough, 0.55, snow);
	nw = normalize(mix(nw, normalize(mat3(v_bx, v_by, v_bz) * on), snow * 0.6));
	float ao = mix(v_ao, 1.0, 0.15);
	vec3 emit = vec3(0.0);
	if (emission_energy > 0.0) {
		float crack = smoothstep(0.62, 0.92, 1.0 - v_ao) * smoothstep(0.12, 0.02, n1.g + n0.g * 0.2);
		emit = emission_color * crack * emission_energy;
	}
	c = max(c, vec3(0.0));
	ALBEDO = c;
	ROUGHNESS = rough;
	SPECULAR = mix(0.3, 0.5, snow);
	AO = ao;
	AO_LIGHT_AFFECT = 0.35;
	EMISSION = emit;
	NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
}
