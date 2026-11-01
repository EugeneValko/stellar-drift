// Procedural planet terrain (PlanetTerrain chunks). See src/planets/terrain_generator.gd
// for the vertex layout:
//   COLOR   r rock exposure, g lava, b crater ejecta, a curvature (0.5 = flat)
//   CUSTOM0 xyz detail coords (planet-local pos mod 4096 m), w height above radius (m)
//   CUSTOM1 xyz unit dir from planet centre, w moisture
//   CUSTOM2 xyz morph delta of odd edge vertices, w edge id + 1
// All detail textures tile at power-of-two sizes <= 2048 m, so they are continuous across
// chunks while the coordinates stay small (no float precision loss far from the origin).
//
// Lighting: custom light() so the sun is attenuated by the planet's atmosphere per vertex
// (atmo_sun_transmittance -> red sunsets, planet shadow) and by cloud shadows per pixel; sky
// ambient from the atmosphere model is added as emission. Works on scaled-space proxies
// (distances divided by the node scale). The DirectionalLight3D must carry the UNATTENUATED
// star colour (SolarSystem does that).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back;

#include "res://shaders/include/atmosphere_common.gdshaderinc"
#include "res://shaders/include/clouds_common.gdshaderinc"

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

group_uniforms lighting;
uniform bool use_atmosphere = false;      // atmo_* uniforms are set (AtmosphereLayer.uniforms)
uniform float sky_ambient_scale = 0.55;   // sky light (atmosphere) on the terrain
uniform vec3 night_ambient = vec3(0.006, 0.007, 0.011);  // starlight / airglow floor (radiance)
group_uniforms;

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
varying vec3 v_sun_tint;
varying vec3 v_sky_amb;
varying float v_shadow;
varying float v_f0;

// Bit i set = edge i (0 bottom, 1 right, 2 top, 3 left) borders a coarser chunk.
instance uniform int coarse_edges = 0;

void vertex() {
	v_detail = CUSTOM0.xyz;
	if (CUSTOM2.w > 0.5) {
		int e = int(CUSTOM2.w + 0.5) - 1;
		if (((coarse_edges >> e) & 1) != 0) {
			VERTEX += CUSTOM2.xyz;
			v_detail += CUSTOM2.xyz;
		}
	}
	v_height = CUSTOM0.w;
	v_dir = CUSTOM1.xyz;
	v_moist = CUSTOM1.w;
	v_mask = COLOR;
	v_nrm = NORMAL;
	// atmosphere terms per vertex (smooth; chunks are dense): world-oriented, body units
	v_sun_tint = vec3(1.0);
	v_sky_amb = vec3(0.0);
	if (use_atmosphere) {
		vec3 pw = normalize(mat3(MODEL_MATRIX) * CUSTOM1.xyz) * (planet_radius + CUSTOM0.w);
		v_sun_tint = atmo_sun_transmittance(pw, sd_sun_dir());
		v_sky_amb = atmo_sky_ambient(pw);
	}
}

vec3 tri_w(vec3 n) {
	vec3 w = pow(abs(n), vec3(8.0));
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
	float node_s = sd_node_scale(MODEL_MATRIX);
	float dist = length(VERTEX) / node_s;     // body units (scaled-space proxies)
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
	// snow collects in gullies and on flats, thins out on convex ridges and steep faces
	float snow_in = hb + (n1 * 0.6 + (nband.b - 0.5)) * 420.0 - slope * 900.0 + curv * 900.0;
	float snow = smoothstep(snow_h - 180.0, snow_h + 180.0, snow_in);
	float rock_slope = smoothstep(0.13, 0.3, slope + n1 * 0.08 + n2 * 0.1);
	// alpine zone: scree and bare rock between the tree line and the snow line
	float alpine = smoothstep(snow_h * 0.5, snow_h * 0.75, hb + n2 * 400.0 + n1 * 120.0);
	float rock = max(rock_slope, smoothstep(0.35, 0.85, v_mask.r + n2 * 0.4) * (1.0 - snow * 0.7));
	rock = max(rock, alpine * smoothstep(0.35, 0.65, nband.r + slope * 2.0) * (1.0 - snow));
	snow *= 1.0 - smoothstep(0.2, 0.36, slope + n1 * 0.12);   // snow slides off steep walls
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
		// a beach narrower than a few pixels would read as a thick contour line from orbit
		beach *= clamp(bw * 1.5 / max(fwidth(hb) * 4.0, 1e-3), 0.0, 1.0) * (1.0 - smoothstep(6000.0, 25000.0, dist));
		under = smoothstep(0.0, -bw * 2.0, hb);
	}

	// ---------- albedo ----------
	vec3 low = mix(color_dry, color_grass, smoothstep(0.25, 0.6, moist));
	low = mix(low, color_desert, desert);
	low = mix(low, color_forest, forest);
	// soil/grass breakup at all scales: lush / dry-yellow / dark clumps / bare soil
	float g1 = nband.r;
	float g2 = nband.a;
	low = mix(low, low * vec3(1.25, 1.12, 0.6), smoothstep(0.55, 0.8, g1) * (1.0 - forest) * 0.8);
	low = mix(low, low * vec3(0.55, 0.65, 0.5), smoothstep(0.45, 0.2, g2) * 0.7);
	float soil = smoothstep(0.62, 0.8, nband.b + n2 * 0.4) * (1.0 - forest) * (1.0 - desert);
	low = mix(low, mix(color_dry, color_rock, 0.5) * 0.8, soil * 0.6);
	low *= 0.85 + 0.3 * g2 + n1 * 0.2;
	// close range: grass clumps & pebbles (fades out with distance)
	float near_f = 1.0 - smoothstep(25.0, 120.0, dist);
	if (near_f > 0.0) {
		vec4 nn = tri(tex_noise, p / 0.5, w);
		vec4 nn2 = tri(tex_noise, p / 2.0, w);
		float clump = smoothstep(0.3, 0.75, nn.a * 0.6 + nn2.r * 0.6 - 0.1);
		vec3 lush = low * mix(vec3(0.75, 0.85, 0.7), vec3(1.15, 1.12, 0.9), clump);
		float peb = smoothstep(0.12, 0.04, nn2.g) * (1.0 - forest * 0.7);
		lush = mix(lush, mix(color_rock, color_dry, 0.4) * (0.7 + 0.5 * nn.r), peb * 0.75);
		low = mix(low, lush, near_f);
	}
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
	float soft_s = mix(1.0, 1.5, rock) * detail_normal_strength;
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
	SPECULAR = mix(mix(0.18, 0.35, rock), 0.5, snow);
	v_f0 = 0.08 * SPECULAR;
	AO = clamp(0.75 + curv * 1.5 + (1.0 - rock) * 0.1, 0.4, 1.0);
	AO_LIGHT_AFFECT = 0.4;
	// sky ambient (atmosphere) + night floor; cloud shadow for the sun term (planet-local)
	float ao_amb = AO * (0.65 + 0.35 * clamp(dot(n, up), 0.0, 1.0));
	EMISSION = emit + col * (v_sky_amb * sky_ambient_scale + night_ambient) * ao_amb;
	v_shadow = 1.0;
	if (cloud_shadow_strength > 0.0) {
		mat3 to_local = transpose(mat3(MODEL_MATRIX)) / node_s;
		v_shadow = cloud_shadow_local(up * (planet_radius + v_height), to_local * sd_sun_dir());
	}
	NORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(n, 0.0))).xyz);
}

void light() {
	// Burley-ish lambert + GGX specular; sun attenuated by atmosphere and cloud shadows
	vec3 lc = LIGHT_COLOR * ATTENUATION / PI * v_sun_tint * v_shadow;
	float ndl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	float ndv = clamp(dot(NORMAL, VIEW), 1e-3, 1.0);
	vec3 h = normalize(LIGHT + VIEW);
	float ldh = clamp(dot(LIGHT, h), 0.0, 1.0);
	float fd90 = 0.5 + 2.0 * ROUGHNESS * ldh * ldh;
	float fl = 1.0 + (fd90 - 1.0) * pow(1.0 - ndl, 5.0);
	float fv = 1.0 + (fd90 - 1.0) * pow(1.0 - ndv, 5.0);
	DIFFUSE_LIGHT += lc * ndl * fl * fv;
	float a = ROUGHNESS * ROUGHNESS;
	float a2 = a * a;
	float ndh = clamp(dot(NORMAL, h), 0.0, 1.0);
	float dd = ndh * ndh * (a2 - 1.0) + 1.0;
	float D = a2 / (PI * dd * dd);
	float k = a * 0.5;
	float vis = 0.25 / ((ndl * (1.0 - k) + k) * (ndv * (1.0 - k) + k));
	float F = v_f0 + (1.0 - v_f0) * pow(1.0 - ldh, 5.0);
	SPECULAR_LIGHT += lc * ndl * D * vis * F * PI;
}
