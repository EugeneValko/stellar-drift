// Procedural planet terrain (PlanetTerrain chunks). See src/planets/terrain_generator.gd
// for the vertex layout:
//   COLOR   r rock exposure, g lava, b crater ejecta, a curvature (0.5 = flat)
//   CUSTOM0 xyz detail coords (planet-local pos mod 4096 m), w height above radius (m)
//   CUSTOM1 xyz unit dir from planet centre, w moisture
// All detail textures tile at power-of-two sizes <= 2048 m, so they are continuous across
// chunks while the coordinates stay small (no float precision loss far from the origin).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform int planet_type = 0;          // PlanetConfig.PlanetType
uniform float planet_radius = 10000.0;
uniform float height_amplitude = 2000.0;
uniform float base_level = 0.0;       // sea level (m above radius) or 0
uniform bool has_ocean = false;
uniform float beach_width = 25.0;
uniform float snow_line = 4000.0;
uniform float polar_snow = 0.75;
uniform float strata_strength = 0.3;
uniform float macro_variation = 0.35;
uniform float lava_intensity = 0.0;
uniform float detail_normal_strength = 1.0;

uniform vec3 color_seabed : source_color = vec3(0.16, 0.18, 0.15);
uniform vec3 color_sand : source_color = vec3(0.76, 0.68, 0.5);
uniform vec3 color_grass : source_color = vec3(0.22, 0.38, 0.12);
uniform vec3 color_forest : source_color = vec3(0.08, 0.2, 0.06);
uniform vec3 color_dry : source_color = vec3(0.55, 0.5, 0.3);
uniform vec3 color_desert : source_color = vec3(0.78, 0.6, 0.38);
uniform vec3 color_rock : source_color = vec3(0.38, 0.34, 0.3);
uniform vec3 color_rock2 : source_color = vec3(0.24, 0.22, 0.21);
uniform vec3 color_snow : source_color = vec3(0.92, 0.94, 0.98);
uniform vec3 color_lava : source_color = vec3(1.0, 0.32, 0.05);

uniform sampler2D tex_noise : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_normal : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_rock : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;

varying vec3 v_detail;
varying float v_height;
varying vec3 v_dir;
varying float v_moist;
varying vec4 v_mask;
varying vec3 v_nrm;

void vertex() {
	v_detail = CUSTOM0.xyz;
	v_height = CUSTOM0.w;
	v_dir = CUSTOM1.xyz;
	v_moist = CUSTOM1.w;
	v_mask = COLOR;
	v_nrm = NORMAL;
}

vec3 tri_w(vec3 n) {
	vec3 w = pow(abs(n), vec3(4.0));
	return w / (w.x + w.y + w.z);
}

vec4 tri(sampler2D t, vec3 p, vec3 w) {
	return texture(t, p.zy) * w.x + texture(t, p.xz) * w.y + texture(t, p.xy) * w.z;
}

// Triplanar normal map, whiteout blend, model space.
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

// Distance-banded scale: returns tile size (m) for band i of a log4 ladder.
float band_tile(float dist, float base, float bias, out float f) {
	float l = max(log2(max(dist, 0.01) / base) * 0.5 + bias, 0.0);
	float i = floor(l);
	f = l - i;
	return min(base * exp2(2.0 * i), 512.0);
}

void fragment() {
	vec3 up = normalize(v_dir);
	vec3 ng = normalize(v_nrm);
	vec3 w = tri_w(ng);
	float dist = length(VERTEX);
	vec3 p = v_detail;
	float hb = v_height - base_level;          // height above sea / base
	float hn = v_height / height_amplitude;

	// ---------- noise ladder (distance banded, avoids visible tiling at every range) ----------
	float bf;
	float tile = band_tile(dist, 2.0, -0.3, bf);
	vec4 na = tri(tex_noise, p / tile, w);
	vec4 nb = tri(tex_noise, p / (tile * 4.0), w);
	vec4 nband = mix(na, nb, smoothstep(0.0, 1.0, bf));
	vec4 nbig = tri(tex_noise, p / 2048.0, w);
	// orbit-scale macro variation from the direction (no precision issue: |dir| = 1)
	vec3 wd = tri_w(up);
	vec4 nmac = tri(tex_noise, up * planet_radius / 24000.0, wd);
	vec4 nmac2 = tri(tex_noise, up * planet_radius / 90000.0, wd);
	float macro = (nmac.r * 0.6 + nmac2.r * 0.4) - 0.5;
	float n1 = nband.r - 0.5;
	float n2 = nbig.r - 0.5;

	// ---------- geometric slope ----------
	float slope = 1.0 - clamp(dot(ng, up), 0.0, 1.0);
	float lat = abs(up.y);
	float curv = v_mask.a - 0.5;

	// ---------- biome weights ----------
	float moist = clamp(v_moist + macro * 0.35 + n2 * 0.25, 0.0, 1.0);
	float snow_h = snow_line * (1.0 - polar_snow * lat * lat) + (macro + n2) * snow_line * 0.15;
	float snow = smoothstep(snow_h - 120.0, snow_h + 120.0, hb + n1 * 160.0);
	float rock_slope = smoothstep(0.22, 0.42, slope + n1 * 0.08 + n2 * 0.1);
	float rock = max(rock_slope, smoothstep(0.35, 0.85, v_mask.r + n2 * 0.4) * (1.0 - snow * 0.7));
	snow *= 1.0 - smoothstep(0.32, 0.5, slope + n1 * 0.1);   // snow slides off steep walls
	// polar ice caps (independent of height, ragged edge)
	float cap = smoothstep(0.9, 0.95, lat + macro * 0.12 + n2 * 0.06) * step(0.0, polar_snow - 0.01);
	snow = max(snow, cap * (1.0 - rock_slope * 0.6));
	float desert = smoothstep(0.32, 0.12, moist + n2 * 0.1);
	float forest = smoothstep(0.5, 0.7, moist + n1 * 0.25 + macro * 0.2)
		* (1.0 - smoothstep(snow_h * 0.45, snow_h * 0.7, hb)) * (1.0 - smoothstep(0.25, 0.4, slope));
	float beach = 0.0;
	float under = 0.0;
	if (has_ocean) {
		float bw = beach_width * (1.0 + n2 * 1.2);
		beach = (1.0 - smoothstep(bw * 0.6, bw * 1.4, hb)) * (1.0 - smoothstep(0.15, 0.3, slope));
		under = smoothstep(0.0, -bw * 2.0, hb);
	}

	// ---------- albedo ----------
	vec3 low = mix(color_dry, color_grass, smoothstep(0.25, 0.6, moist));
	low = mix(low, color_desert, desert);
	low = mix(low, color_forest, forest);
	// soil/grass breakup at all scales
	low *= 0.82 + 0.36 * nband.a + n1 * 0.25;
	low = mix(low, low * vec3(1.08, 1.0, 0.85), smoothstep(-0.1, 0.25, n2));

	// rock with strata bands (stronger in canyons / mesas)
	float strata = sin((v_height + n2 * 60.0 + nband.b * 8.0) * 0.21) * 0.5 + 0.5;
	strata = mix(strata, sin(v_height * 0.047 + n1 * 2.0) * 0.5 + 0.5, 0.5);
	vec3 rk = mix(color_rock, color_rock2, clamp(nband.b * 0.9 + n2 * 0.6 + (strata - 0.5) * strata_strength * 2.0, 0.0, 1.0));
	rk *= 0.85 + 0.3 * nband.g;
	rk = mix(rk, rk * 0.75, smoothstep(0.0, -0.1, curv));   // darker in gullies

	vec3 col = mix(low, rk, rock);
	col = mix(col, color_sand * (0.9 + 0.2 * nband.a), beach);
	col = mix(col, color_seabed * (0.85 + 0.3 * n1), under);
	vec3 sn = color_snow * (0.94 + 0.08 * nband.a);
	col = mix(col, sn, snow);

	// crater ejecta (moons) and fresh-impact brightening
	col *= 1.0 + v_mask.b * 0.45;
	// macro variation visible from orbit
	col *= 1.0 + macro * macro_variation * 1.6;
	col = max(col, vec3(0.0));

	// ---------- detail normal ----------
	float soft_s = mix(0.6, 1.4, rock) * detail_normal_strength;
	vec3 n = ng;
	// big-scale relief (always) – keeps orbit/high-altitude shading alive
	n = tri_nrm(tex_rock, p / 2048.0, n, w, 0.8 * rock + 0.25);
	n = tri_nrm(tex_rock, p / 512.0, n, w, 0.5 * rock + 0.15);
	// banded near detail
	float nf;
	float ntile = band_tile(dist, 1.0, -0.6, nf);
	vec3 n_soft = n;
	vec3 n_rock = n;
	if (rock < 0.99) {
		n_soft = normalize(mix(tri_nrm(tex_normal, p / ntile, n, w, soft_s),
			tri_nrm(tex_normal, p / (ntile * 4.0), n, w, soft_s), nf));
	}
	if (rock > 0.01) {
		n_rock = normalize(mix(tri_nrm(tex_rock, p / ntile, n, w, soft_s),
			tri_nrm(tex_rock, p / (ntile * 4.0), n, w, soft_s), nf));
	}
	n = normalize(mix(n_soft, n_rock, rock));
	n = normalize(mix(n, ng, snow * 0.5 + beach * 0.4));

	// ---------- lava ----------
	vec3 emit = vec3(0.0);
	if (lava_intensity > 0.0) {
		float lv = smoothstep(0.25, 0.7, v_mask.g + n1 * 0.3);
		float cracks = smoothstep(0.55, 0.15, nband.g);            // glowing crust cracks
		float flow = mix(cracks, 1.0, smoothstep(0.75, 0.95, v_mask.g + n2 * 0.2));
		float heat = lv * flow;
		col = mix(col, vec3(0.05, 0.03, 0.025), lv * 0.85);       // dark basalt crust
		emit = color_lava * heat * lava_intensity * (0.6 + 0.8 * nband.r);
		emit += color_lava * smoothstep(0.1, 0.6, v_mask.g) * lava_intensity * 0.06; // ambient glow
	}

	float ice = 0.0;
	if (planet_type == 2) {
		// blue glacier ice in low flat areas
		ice = smoothstep(0.05, 0.6, nbig.b + macro) * (1.0 - rock) * (1.0 - smoothstep(0.1, 0.25, slope));
		col = mix(col, vec3(0.55, 0.75, 0.92) * (0.9 + 0.2 * nband.r), ice * 0.6);
	}

	float rough = mix(0.92, 0.82, rock);
	rough = mix(rough, 0.6, snow);
	rough = mix(rough, 0.25, ice * 0.7);
	rough = mix(rough, 0.55, lava_intensity > 0.0 ? smoothstep(0.3, 0.8, v_mask.g) : 0.0);

	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = mix(0.25, 0.5, snow);
	AO = clamp(0.75 + curv * 1.5 + (1.0 - rock) * 0.1, 0.4, 1.0);
	AO_LIGHT_AFFECT = 0.4;
	EMISSION = emit;
	NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n, 0.0))).xyz);
}
