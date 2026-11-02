// Procedural planet terrain (PlanetTerrain chunks). See src/planets/terrain_generator.gd
// for the vertex layout:
//   COLOR   r rock exposure, g lava mask (river / water mask on planets without lava),
//           b crater ejecta + bright rays, a curvature (0.5 = flat, > 0.5 concave)
//   CUSTOM0 xyz detail coords (planet-local pos mod 4096 m), w height above radius (m)
//   CUSTOM1 xyz unit dir from planet centre, w moisture
//   CUSTOM2 xyz morph delta of odd edge vertices, w edge id + 1
// All detail textures tile at power-of-two sizes <= 2048 m, so they are continuous across
// chunks while the coordinates stay small (no float precision loss far from the origin).
//
// Biome logic (moisture, snow, rock, desert, forest, savanna, tundra, beach, river, alien canopy
// regions) is mirrored on the CPU by src/planets/scatter/scatter_biome.gd so vegetation grows
// where the ground is painted for it: keep both in sync ("SYNC" comments).
//
// Near ground (< ~90 m): material stack with height blending (soil / stones / grass / sand / scree /
// rock / snow) from assets/textures/ground_*.png (tools/textures/make_ground_textures.py): stones,
// pebbles, contact AO, mud cracks, wet sand, sand ripples, snow sparkle, one-step parallax.
// Surface styles (PlanetConfig.surface_style): 0 Earth-like, 1 Ignis, 2 Vex, 3 Glacia, 4 Selene, 5 Nyx.
//
// Lighting: custom light() so the sun is attenuated by the planet's atmosphere per vertex
// (atmo_sun_transmittance -> red sunsets, planet shadow) and by cloud shadows per pixel; sky
// ambient from the atmosphere model is added as emission. Works on scaled-space proxies
// (distances divided by the node scale). The DirectionalLight3D carries the star colour; when
// SolarSystem tints the shared main light for the ship/player (sunset, planet shadow at the
// camera) it sets `light_unattenuate` = 1 / that tint on the focus group's terrain, so the
// terrain still starts from the unattenuated star light. Environment ambient is not used
// (ambient_light_disabled): the sky ambient comes from the atmosphere model below.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, ambient_light_disabled;

#include "res://shaders/include/atmosphere_common.gdshaderinc"
#include "res://shaders/include/clouds_common.gdshaderinc"

uniform int planet_type = 0;          // PlanetConfig.PlanetType
uniform int surface_style = 0;        // PlanetConfig.surface_style
uniform float planet_radius = 10000.0;
uniform float height_amplitude = 2000.0;
uniform float base_level = 0.0;       // sea level (m above radius) or 0
uniform bool has_ocean = false;
uniform bool has_rivers = false;      // COLOR.g is a river mask (no lava)
uniform float beach_width = 25.0;
uniform float snow_line = 4000.0;
uniform float polar_snow = 0.75;
uniform float strata_strength = 0.3;
uniform float macro_variation = 0.35;
uniform float lava_intensity = 0.0;
uniform float detail_normal_strength = 1.0;
uniform float alien_forest = 0.0;
uniform float sand_variety = 0.0;
uniform float stone_amount = 0.5;
// 0 off; 1 (desert, forest, savanna), 2 (tundra, snow, beach), 3 (alien_b, alien_c, river),
// 4 (rock, scree, stones), 5 (moist, temp, 0)
uniform int debug_view = 0;

group_uniforms lighting;
uniform bool use_atmosphere = false;      // atmo_* uniforms are set (AtmosphereLayer.uniforms)
uniform float sky_ambient_scale = 0.9;   // sky light (atmosphere) on the terrain
uniform vec3 night_ambient = vec3(0.025, 0.032, 0.055);  // starlight / airglow / planetshine floor (artistic)
uniform vec3 light_unattenuate = vec3(1.0);   // undoes SolarSystem's main-light tint (see header)
group_uniforms;

uniform vec3 color_seabed : source_color = vec3(0.16, 0.18, 0.15);
uniform vec3 color_sand : source_color = vec3(0.76, 0.68, 0.5);
uniform vec3 color_sand_b : source_color = vec3(0.82, 0.62, 0.56);
uniform vec3 color_grass : source_color = vec3(0.22, 0.38, 0.12);
uniform vec3 color_forest : source_color = vec3(0.08, 0.2, 0.06);
uniform vec3 color_forest_b : source_color = vec3(0.22, 0.12, 0.24);
uniform vec3 color_forest_c : source_color = vec3(0.06, 0.22, 0.22);
uniform vec3 color_dry : source_color = vec3(0.55, 0.5, 0.3);
uniform vec3 color_desert : source_color = vec3(0.78, 0.6, 0.38);
uniform vec3 color_savanna : source_color = vec3(0.62, 0.55, 0.3);
uniform vec3 color_tundra : source_color = vec3(0.42, 0.4, 0.3);
uniform vec3 color_rock : source_color = vec3(0.38, 0.34, 0.3);
uniform vec3 color_rock2 : source_color = vec3(0.24, 0.22, 0.21);
uniform vec3 color_snow : source_color = vec3(0.92, 0.94, 0.98);
uniform vec3 color_lava : source_color = vec3(1.0, 0.32, 0.05);
uniform vec3 color_water : source_color = vec3(0.03, 0.08, 0.1);
uniform vec3 color_accent : source_color = vec3(0.9, 0.8, 0.2);

uniform sampler2D tex_noise : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_normal : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_rock : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
// near ground: r stones height, g stone id, b cracks, a grit (see make_ground_textures.py)
uniform sampler2D tex_ground : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_ground_n : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
// r ripples, g dunes, b broad fbm, a sparkle seeds
uniform sampler2D tex_ripple : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_ripple_n : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D tex_dune_n : hint_normal, repeat_enable, filter_linear_mipmap_anisotropic;

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
varying float v_sparkle;
varying float v_wrap;

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

// Triplanar weights. Planes below TRI_CUT are dropped continuously (weight - cut, renormalized):
// most pixels then read one or two planes instead of three (fewer fetches on slopes), with no seam.
// SYNC: ScatterBiome.tri_w.
const float TRI_CUT = 0.05;

vec3 tri_w(vec3 n) {
	vec3 w = pow(abs(n), vec3(8.0));
	w = max(w / (w.x + w.y + w.z) - TRI_CUT, 0.0);
	return w / (w.x + w.y + w.z);
}

// Triplanar lookups skip projections with negligible weight (pow-8 weights: on most pixels only
// one or two planes contribute). Explicit gradients keep mip selection valid inside the branches.
const float TRI_EPS = 0.004;

vec4 tri(sampler2D t, vec3 p, vec3 w) {
	vec3 dx = dFdx(p);
	vec3 dy = dFdy(p);
	vec4 r = vec4(0.0);
	if (w.x > TRI_EPS) { r += textureGrad(t, p.zy, dx.zy, dy.zy) * w.x; }
	if (w.y > TRI_EPS) { r += textureGrad(t, p.xz, dx.xz, dy.xz) * w.y; }
	if (w.z > TRI_EPS) { r += textureGrad(t, p.xy, dx.xy, dy.xy) * w.z; }
	return r;
}

// Blurred lookup (gradients scaled like a mip bias).
vec4 tri_bias(sampler2D t, vec3 p, vec3 w, float bias) {
	float k = exp2(bias);
	vec3 dx = dFdx(p) * k;
	vec3 dy = dFdy(p) * k;
	vec4 r = vec4(0.0);
	if (w.x > TRI_EPS) { r += textureGrad(t, p.zy, dx.zy, dy.zy) * w.x; }
	if (w.y > TRI_EPS) { r += textureGrad(t, p.xz, dx.xz, dy.xz) * w.y; }
	if (w.z > TRI_EPS) { r += textureGrad(t, p.xy, dx.xy, dy.xy) * w.z; }
	return r;
}

// Triplanar normal map, whiteout blend, model space. z is rebuilt from xy (robust to RG-only
// normal-map compression).
vec3 nrm_xy(vec4 t, float s) {
	vec2 xy = t.xy * 2.0 - 1.0;
	return vec3(xy * s, sqrt(clamp(1.0 - dot(xy, xy), 0.0, 1.0)));
}

vec3 tri_nrm(sampler2D t, vec3 p, vec3 n, vec3 w, float s) {
	vec3 dx = dFdx(p);
	vec3 dy = dFdy(p);
	vec3 tx = vec3(0.0, 0.0, 1.0);
	vec3 ty = vec3(0.0, 0.0, 1.0);
	vec3 tz = vec3(0.0, 0.0, 1.0);
	if (w.x > TRI_EPS) { tx = nrm_xy(textureGrad(t, p.zy, dx.zy, dy.zy), s); }
	if (w.y > TRI_EPS) { ty = nrm_xy(textureGrad(t, p.xz, dx.xz, dy.xz), s); }
	if (w.z > TRI_EPS) { tz = nrm_xy(textureGrad(t, p.xy, dx.xy, dy.xy), s); }
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

// Fall-line rills in one triplanar plane: channels stretched along the projection of the local
// "up" on that plane (rills, couloirs, rock-fall stains). The frame rotates with `up` (~1 deg/km on
// Terra): a smooth, invisible warp, no seams inside a chunk.
float streak_plane(sampler2D t, vec2 q, vec2 upp) {
	float l = length(upp);
	if (l < 0.15) {
		return 0.5;
	}
	vec2 u2 = upp / l;
	float a = dot(q, u2);
	float s = dot(q, vec2(-u2.y, u2.x));
	// discrete channels: crests of the ridged channel, broken up along their length
	float c1 = smoothstep(0.62, 0.86, texture(t, vec2(s / 220.0, a / 1100.0)).b);
	float c2 = smoothstep(0.66, 0.88, texture(t, vec2(s / 60.0, a / 300.0)).b);
	float brk = smoothstep(0.3, 0.6, texture(t, vec2(s / 400.0, a / 500.0)).a);
	return clamp(c1 * (0.5 + 0.5 * brk) + c2 * 0.6 * brk, 0.0, 1.0);
}

void fragment() {
	vec3 up = normalize(v_dir);
	vec3 ng = normalize(v_nrm);
	vec3 w = tri_w(ng);
	float node_s = sd_node_scale(MODEL_MATRIX);
	float dist = length(VERTEX) / node_s;     // body units (scaled-space proxies)
	vec3 p = v_detail;
	float hb = v_height - base_level;          // height above sea / base
	// view direction (toward the camera) in planet space
	vec3 vw = normalize(transpose(mat3(MODEL_MATRIX)) * (mat3(INV_VIEW_MATRIX) * VIEW));

	// ---------- noise ladder (distance banded, avoids visible tiling at every range) ----------
	float bf;
	float tile = band_tile(dist, 2.0, -0.3, bf);
	vec4 na = tri(tex_noise, p / tile, w);
	vec4 nb = tri(tex_noise, p / (tile * 4.0), w);
	vec4 nband = mix(na, nb, smoothstep(0.0, 1.0, bf));
	vec4 nbig = tri(tex_noise, p / 2048.0, w);
	vec4 nmid = tri(tex_noise, p / 256.0, w);
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
	float concave = smoothstep(0.0, 0.12, curv);
	// rills / couloirs down the fall line on slopes (0..1, mostly 0; ScatterBiome ignores it like n1)
	float rill = 0.0;
	float steep = smoothstep(0.06, 0.22, slope);
	if (steep > 0.0) {
		rill = streak_plane(tex_noise, p.zy, up.zy) * w.x + streak_plane(tex_noise, p.xz, up.xz) * w.y
			+ streak_plane(tex_noise, p.xy, up.xy) * w.z;
		rill *= steep;
	}

	// ---------- biome weights (SYNC: ScatterBiome.evaluate_into) ----------
	float moist = clamp(v_moist + macro * 0.35 + n2 * 0.25, 0.0, 1.0);
	float snow_h = snow_line * (1.0 - polar_snow * lat * lat) + (macro + n2) * snow_line * 0.15;
	// snow collects in gullies, couloirs and on flats, thins out on convex ridges and steep faces
	float snow_in = hb + (n1 * 0.6 + (nband.b - 0.5)) * 420.0 - slope * 900.0 + curv * 900.0
		+ rill * 700.0;
	float snow = smoothstep(snow_h - 180.0, snow_h + 180.0, snow_in);
	float rock_slope = smoothstep(0.13, 0.3, slope + n1 * 0.08 + n2 * 0.1 + rill * 0.1);
	// alpine zone: scree and bare rock between the tree line and the snow line
	float alpine = smoothstep(snow_h * 0.5, snow_h * 0.75, hb + n2 * 400.0 + n1 * 120.0);
	float rock = max(rock_slope, smoothstep(0.35, 0.85, v_mask.r + n2 * 0.4) * (1.0 - snow * 0.7));
	rock = max(rock, alpine * smoothstep(0.35, 0.65, nband.r + slope * 2.0) * (1.0 - snow));
	snow *= 1.0 - smoothstep(0.2, 0.36, slope + n1 * 0.12);   // snow slides off steep walls
	// polar ice caps (independent of height, ragged edge)
	float cap = smoothstep(0.9, 0.95, lat + macro * 0.12 + n2 * 0.06) * step(0.0, polar_snow - 0.01);
	snow = max(snow, cap * (1.0 - rock_slope * 0.6));
	// temperature: latitude + altitude (1 = warm lowland, 0 = polar / high)
	float temp = 1.0 - lat * lat * 1.3 - max(hb, 0.0) / max(snow_line, 1.0) * 0.6 + macro * 0.3 + n2 * 0.15;
	float desert = smoothstep(0.32, 0.12, moist + n2 * 0.1);
	float savanna = smoothstep(0.2, 0.32, moist + n2 * 0.1) * smoothstep(0.5, 0.38, moist + n2 * 0.1)
		* smoothstep(0.45, 0.65, temp);
	float tundra = smoothstep(0.4, 0.2, temp) * (1.0 - snow);
	if (surface_style != 0) {
		savanna = 0.0;     // Earth-like climate zones only
		tundra = 0.0;
	}
	float forest = smoothstep(0.5, 0.7, moist + n1 * 0.25 + macro * 0.2)
		* (1.0 - smoothstep(snow_h * 0.45, snow_h * 0.7, hb)) * (1.0 - smoothstep(0.25, 0.4, slope));
	forest *= 1.0 - tundra * 0.65;
	float beach = 0.0;
	float under = 0.0;
	float wet = 0.0;
	if (has_ocean) {
		float bw = beach_width * (1.0 + n2 * 1.2);
		beach = (1.0 - smoothstep(bw * 0.6, bw * 1.4, hb)) * (1.0 - smoothstep(0.15, 0.3, slope));
		// a beach narrower than a few pixels would read as a thick contour line from orbit
		beach *= clamp(bw * 1.5 / max(fwidth(hb) * 4.0, 1e-3), 0.0, 1.0) * (1.0 - smoothstep(6000.0, 25000.0, dist));
		under = smoothstep(0.0, -bw * 2.0, hb);
		// swash zone: wet, dark, glossy sand just above the waterline
		wet = smoothstep(2.2, 0.15, hb + n1 * 1.2 + (nband.a - 0.5) * 0.8) * (1.0 - smoothstep(0.2, 0.4, slope));
	}
	float river = 0.0;
	float bank = 0.0;
	if (has_rivers) {
		river = smoothstep(0.55, 0.85, v_mask.g + n1 * 0.15) * (1.0 - snow);
		bank = smoothstep(0.02, 0.5, v_mask.g);
	}
	// alien canopy regions (SYNC: ScatterBiome A_ALIEN_B / A_ALIEN_C)
	float alien_b = 0.0;
	float alien_c = 0.0;
	if (alien_forest > 0.0) {
		alien_b = smoothstep(0.72, 0.8, nmac.b + n2 * 0.1) * alien_forest;
		alien_c = smoothstep(0.36, 0.28, nmac2.a + n2 * 0.1) * alien_forest * (1.0 - alien_b);
	}

	// ---------- albedo: lowland vegetation / soil ----------
	vec3 low = mix(color_dry, color_grass, smoothstep(0.25, 0.6, moist));
	// savanna: golden grass mottled with green thickets (from orbit: olive-gold, not sand)
	vec3 sav = mix(color_savanna, color_grass * 0.9, smoothstep(0.45, 0.75, nmid.r + n1 * 0.4) * 0.6);
	low = mix(low, sav * (0.85 + 0.25 * nband.a), savanna);
	low = mix(low, color_desert, desert);
	vec3 fcol = color_forest;
	fcol = mix(fcol, color_forest_b, alien_b);
	fcol = mix(fcol, color_forest_c, alien_c);
	// canopy texture from altitude: crowns / gaps (dark) at the 30-120 m scale
	fcol *= 0.8 + 0.4 * smoothstep(0.25, 0.75, nmid.a);
	low = mix(low, fcol, forest);
	low = mix(low, color_tundra * (0.8 + 0.4 * nband.a) * mix(vec3(1.0), vec3(1.15, 0.95, 0.85), smoothstep(0.5, 0.8, nmid.g)),
		tundra * (1.0 - forest * 0.5));
	// soil/grass breakup at all scales: lush / dry-yellow / dark clumps / bare soil
	float g1 = nband.r;
	float g2 = nband.a;
	bool earth = surface_style == 0;
	low = mix(low, low * (earth ? vec3(1.25, 1.12, 0.6) : vec3(1.15)), smoothstep(0.55, 0.8, g1) * (1.0 - forest) * 0.8);
	low = mix(low, low * (earth ? vec3(0.55, 0.65, 0.5) : vec3(0.7)), smoothstep(0.45, 0.2, g2) * 0.7);
	float soil = smoothstep(0.62, 0.8, nband.b + n2 * 0.4) * (1.0 - forest) * (1.0 - desert);
	vec3 soil_col = mix(color_dry, color_rock, 0.5) * 0.8;
	low = mix(low, soil_col, soil * 0.6);
	low *= 0.85 + 0.3 * g2 + n1 * 0.2;
	// damp river banks: darker, greener
	low = mix(low, low * vec3(0.7, 0.85, 0.65), bank * (1.0 - desert * 0.5));

	// ---------- rock: strata, weathered tops, gullies ----------
	float sh = v_height + n2 * 60.0 + nband.b * 8.0;
	float strata = sin(sh * 0.21) * 0.5 + 0.5;
	strata = mix(strata, sin(v_height * 0.047 + n1 * 2.0) * 0.5 + 0.5, 0.5);
	vec3 rk = mix(color_rock, color_rock2, clamp(nband.b * 0.9 + n2 * 0.6 + (strata - 0.5) * strata_strength * 2.0, 0.0, 1.0));
	// coloured layers (warm / cool beds) and thin bright bands
	float bed = smoothstep(0.55, 0.85, sin(sh * 0.083 + 1.3) * 0.5 + 0.5);
	rk *= mix(vec3(1.0), vec3(1.16, 1.0, 0.84), bed * strata_strength * 1.4);
	rk *= 1.0 + smoothstep(0.94, 0.99, sin(sh * 0.61 + nband.g) * 0.5 + 0.5) * strata_strength * 0.4;
	rk *= 0.85 + 0.3 * nband.g;
	// rills / rock-fall stains down the fall line; greyer, colder rock up high
	rk *= mix(1.06, 0.62, rill);
	rk = mix(rk, vec3(dot(rk, vec3(0.33))) * vec3(0.95, 0.98, 1.04), smoothstep(0.3, 0.9, hb / max(snow_line, 1.0)) * 0.45);
	rk = mix(rk, rk * 0.72, concave * 0.8);     // darker, wetter gullies
	rk *= 0.92 + 0.16 * smoothstep(0.3, 0.9, dot(ng, up));   // weathered, lighter ledges
	// scree aprons at the foot of rock (concave, moderate slope) and in the alpine zone
	float scree = smoothstep(0.06, 0.14, slope) * (1.0 - rock_slope)
		* clamp(alpine * 1.2 + v_mask.r * 1.4 + smoothstep(0.08, 0.13, slope) * concave * 2.0, 0.0, 1.0) * (1.0 - snow);
	scree *= smoothstep(0.35, 0.55, nmid.b + n1 * 0.3);
	low = mix(low, mix(color_rock, color_rock2, 0.35) * (0.85 + 0.3 * nband.r), scree * (1.0 - forest));

	vec3 sandc = mix(color_sand, color_sand_b, smoothstep(0.55, 0.7, nmac2.b + n2 * 0.2) * sand_variety);
	sandc *= 0.9 + 0.2 * nband.a;

	// ---------- near ground: stones, pebbles, cracks, grit (height-blended) ----------
	float near_f = 1.0 - smoothstep(35.0, 90.0, dist);
	float st = 0.0;           // visible stone (0..1)
	float ao_near = 1.0;
	float crack = 0.0;
	vec3 pp = p;
	if (near_f > 0.0) {
		// one-step parallax on the 4 m stone layer (planet-space offset along the view)
		vec4 gh = tri(tex_ground, p / 4.0, w);
		float vu = max(dot(vw, ng), 0.25);
		vec3 vt = vw - ng * dot(vw, ng);
		pp = p - vt / vu * (gh.r - 0.15) * 0.035 * (1.0 - smoothstep(4.0, 18.0, dist));
		vec4 g4 = tri(tex_ground, pp / 4.0, w);
		vec4 g4b = tri_bias(tex_ground, pp / 4.0, w, 2.5);    // blurred stones: contact shadow
		vec4 g16 = tri(tex_ground, p / 16.0, w);
		vec4 nn = tri(tex_noise, p / 0.5, w);
		vec4 nn2 = tri(tex_noise, p / 2.0, w);
		float grassy = smoothstep(0.3, 0.55, moist) * (1.0 - desert) * (1.0 - rock) * (1.0 - beach) * (1.0 - snow)
			* (1.0 - scree) * (1.0 - tundra * 0.5);
		// stony and clean patches; grass hides all but the larger stones
		float patchy = smoothstep(0.3, 0.7, nn2.b + n1 * 0.6 + (nmid.g - 0.5) * 0.6);
		float amount = stone_amount * (0.35 + 1.1 * patchy);
		float thr = mix(0.1, 0.55, grassy) + (1.0 - amount) * 0.35;
		st = smoothstep(thr, thr + 0.06, g4.r);
		st = max(st, smoothstep(0.05, 0.12, g16.r) * max(scree, rock * 0.6));   // scree cobbles
		st *= 1.0 - beach * 0.85;
		st *= 1.0 - river;
		vec3 stone_col = mix(color_rock, color_rock2, g4.g * 0.7) * (0.85 + 0.5 * fract(g4.g * 7.3));
		// stones are cleaner and greyer than the soil they sit in; a few pale / rusty ones
		float slum = dot(stone_col, vec3(0.33));
		stone_col = mix(stone_col, vec3(slum) * vec3(0.98, 1.0, 1.03), 0.45) * 1.15;
		stone_col *= mix(vec3(1.0), vec3(1.15, 0.92, 0.78), step(0.85, fract(g4.g * 13.1)));
		stone_col = mix(stone_col, low, 0.08);
		// grass clumps and dirt
		float clump = smoothstep(0.3, 0.75, nn.a * 0.6 + nn2.r * 0.6 - 0.1);
		vec3 lush = low * (earth ? mix(vec3(0.75, 0.85, 0.7), vec3(1.15, 1.12, 0.9), clump) : vec3(0.85 + 0.25 * clump));
		// grit / soil micro variation
		lush *= 0.88 + 0.24 * g4.a;
		// mud cracks in dry, bare soil and desert pans
		crack = g16.b * smoothstep(0.35, 0.15, moist) * (1.0 - beach) * (1.0 - rock) * (1.0 - snow) * (1.0 - grassy);
		if (surface_style == 1 || surface_style == 2) {
			crack = max(crack, g16.b * (1.0 - smoothstep(0.1, 0.25, slope)) * (1.0 - snow));   // basalt joints
		}
		lush *= 1.0 - crack * 0.45;
		lush = mix(lush, stone_col, st);
		ao_near = 1.0 - smoothstep(0.03, 0.25, g4b.r) * 0.45 * (1.0 - st);
		lush *= mix(1.0, ao_near, 0.8);
		low = mix(low, lush, near_f);
		rk *= mix(1.0, 0.75 + 0.35 * g4.a, near_f);
		rk = mix(rk, rk * 0.55, g16.b * 0.6 * near_f * rock);   // rock fractures
		sandc = mix(sandc, mix(sandc, stone_col, st * 0.6) * (0.92 + 0.16 * g4.a), near_f);
	}
	low = mix(low, low * (earth ? vec3(1.08, 1.0, 0.85) : vec3(1.0)), smoothstep(-0.1, 0.25, n2));

	// lichen and moss on Earth-like rock (moist, not too steep)
	if (surface_style == 0 && has_ocean) {
		float lich = smoothstep(0.62, 0.8, nband.g * 0.7 + nmid.r * 0.5 + moist * 0.25) * (1.0 - snow)
			* (1.0 - smoothstep(60.0, 220.0, dist));
		rk = mix(rk, rk * mix(vec3(0.85, 1.0, 0.7), vec3(1.25, 1.0, 0.6), step(0.6, nmid.a)), lich * 0.6);
		rk = mix(rk, rk * vec3(0.7, 0.95, 0.6), concave * moist * 0.5);
	}

	vec3 col = mix(low, rk, rock);
	col = mix(col, sandc, beach);
	col = mix(col, col * 0.55, wet * (1.0 - under));
	col = mix(col, color_seabed * (0.85 + 0.3 * n1), under);
	vec3 sn = color_snow * (0.94 + 0.08 * nband.a);
	col = mix(col, sn, snow);

	// crater ejecta / rays (moons) and fresh-impact brightening
	float ej_gain = surface_style == 4 ? 1.1 : (surface_style == 5 ? 0.6 : 0.45);
	col *= 1.0 + v_mask.b * ej_gain;
	// macro variation visible from orbit
	col *= 1.0 + macro * macro_variation * 1.6;
	col = max(col, vec3(0.0));

	// ---------- surface styles ----------
	vec3 emit = vec3(0.0);
	float rough_add = 0.0;
	float ice = 0.0;
	float glint = 0.0;
	if (surface_style == 3) {
		// Glacia: blue ice in low flat areas, blue ice cliffs, crevasse fields, wind-packed snow
		ice = smoothstep(0.05, 0.6, nbig.b + macro) * (1.0 - rock) * (1.0 - smoothstep(0.1, 0.25, slope));
		vec3 icec = mix(vec3(0.42, 0.66, 0.86), vec3(0.7, 0.86, 0.97), nband.r);
		col = mix(col, icec, ice * 0.65);
		// most exposed "rock" is glacier ice: blue cliffs with vertical melt streaks and bands
		float icecliff = smoothstep(0.25, 0.45, nbig.g + n1 * 0.4 + nmid.b * 0.2) * rock;
		float streak = tri(tex_noise, vec3(p.x * 0.25, p.y * 0.01, p.z * 0.25) / 8.0, w).r;
		vec3 blue = mix(vec3(0.12, 0.34, 0.55), vec3(0.58, 0.8, 0.94),
			smoothstep(0.25, 0.85, nband.a * 0.6 + streak * 0.5 + (strata - 0.5) * 0.4));
		blue = mix(blue, vec3(0.88, 0.94, 0.98), smoothstep(0.55, 0.9, dot(ng, up)) * 0.7);   // snow on ledges
		col = mix(col, blue, icecliff * 0.9);
		vec4 c64 = tri(tex_ground, p / 64.0, w);
		float crev = c64.b * smoothstep(0.03, 0.08, slope) * (1.0 - rock) * smoothstep(0.3, 0.6, nmid.g);
		col = mix(col, color_accent * 0.35, crev * 0.9);
		ice = max(ice, icecliff);
		glint = 1.0;
	} else if (surface_style == 1) {
		// Ignis: black basalt plains, ash dunes, sulfur vents around lava
		float ash = desert * (1.0 - rock);
		col = mix(col, vec3(0.16, 0.15, 0.15) * (0.8 + 0.4 * nband.a), ash * 0.7);
		float vent = smoothstep(0.06, 0.2, v_mask.g) * (1.0 - smoothstep(0.35, 0.6, v_mask.g))
			* smoothstep(0.62, 0.8, nmid.g + nband.g * 0.3);
		col = mix(col, color_accent * (0.75 + 0.4 * nband.r), vent * 0.85);
		emit += color_lava * vent * 0.03 * lava_intensity;
		col *= 0.9 + 0.25 * smoothstep(0.3, 0.9, dot(ng, up)) * (1.0 - vent);
	} else if (surface_style == 2) {
		// Vex (Io-like): sulfur regions, white frost, red-orange plumes, black paterae
		col = mix(col, vec3(0.85, 0.48, 0.14) * (0.85 + 0.3 * nband.r), smoothstep(0.5, 0.7, nmac.g + n2 * 0.3) * 0.7);
		col = mix(col, vec3(0.92, 0.9, 0.76), smoothstep(0.62, 0.78, nmac2.b + n1 * 0.2) * 0.6);
		col = mix(col, vec3(0.62, 0.2, 0.08), smoothstep(0.7, 0.85, nmac.a + n2 * 0.2) * 0.6);
		float pat = smoothstep(0.16, 0.08, nmac.g + n2 * 0.08);
		col = mix(col, vec3(0.05, 0.04, 0.035), pat);
		emit += color_lava * smoothstep(0.16, 0.12, nmac.g + n2 * 0.08) * smoothstep(0.06, 0.11, nmac.g + n2 * 0.08) * 0.25 * lava_intensity;
	} else if (surface_style == 4) {
		// Selene: darker maria basins, fine regolith
		col *= mix(1.0, 0.72, smoothstep(-20.0, -150.0, hb));
	} else if (surface_style == 5) {
		// Nyx: dark eerie ground, faint glowing crystal veins
		vec4 v32 = tri(tex_ground, p / 32.0, w);
		vec4 v8 = tri(tex_ground, p / 8.0, w);
		// thin, branching veins: sharpened crack mask, only in some regions, brighter where they meet
		float vein = max(v32.b * v32.b * smoothstep(0.45, 0.7, nmid.b), v8.b * v8.b * smoothstep(0.6, 0.8, nmid.g) * 0.6);
		vein *= 0.6 + 0.4 * smoothstep(0.3, 0.7, nband.r);
		float pulse = 0.75 + 0.25 * sin(TIME * 0.6 + (p.x + p.z) * 0.02);
		col = mix(col, col * 0.45, vein);
		emit += color_accent * vein * 0.16 * pulse * (1.0 - smoothstep(400.0, 3000.0, dist));
		glint = 0.4;
	}

	// ---------- detail normal ----------
	float soft_s = mix(1.0, 1.5, rock) * detail_normal_strength;
	vec3 n = ng;
	// big-scale relief (always) – keeps orbit/high-altitude shading alive
	n = tri_nrm(tex_rock, p / 2048.0, n, w, 0.8 * rock + 0.25);
	n = tri_nrm(tex_rock, p / 512.0, n, w, 0.5 * rock + 0.15);
	// dunes (desert / ash / snow) at the 256 m and 32 m scales
	float dune = max(desert * (1.0 - rock) * (1.0 - forest), snow * 0.6) * (1.0 - beach);
	if (dune > 0.01) {
		n = tri_nrm(tex_dune_n, p / 256.0, n, w, dune * 1.2);
		if (dist < 400.0) {
			n = tri_nrm(tex_dune_n, p / 32.0, n, w, dune * 0.6 * (1.0 - smoothstep(150.0, 400.0, dist)));
		}
	}
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
	if (near_f > 0.0) {
		// stones / grit / cracks (masked where grass hides the stones), sand & snow ripples
		float gs = near_f * (0.35 + 1.3 * st + crack * 0.6) * (1.0 - snow * 0.7) * (1.0 - river);
		n = tri_nrm(tex_ground_n, pp / 4.0, n, w, gs);
		float rip = max(beach * (1.0 - wet * 0.7), max(desert * (1.0 - forest), snow)) * (1.0 - st)
			* (1.0 - smoothstep(8.0, 35.0, dist));
		if (rip > 0.01) {
			n = tri_nrm(tex_ripple_n, p / (snow > 0.5 ? 8.0 : 4.0), n, w, rip * 0.9);
		}
		n = tri_nrm(tex_ground_n, p / 16.0, n, w, near_f * (scree + rock * 0.5) * 0.8);
	}
	n = normalize(mix(n, ng, snow * 0.35 + beach * 0.3 + wet * 0.3));

	// ---------- water (rivers / lakes on Earth-like planets) ----------
	float water = river * (1.0 - under);
	if (water > 0.0) {
		vec3 wn = tri_nrm(tex_ripple_n, p / 16.0, up, w, 0.15);
		n = normalize(mix(n, wn, water));
		float fres = 0.02 + 0.98 * pow(1.0 - clamp(dot(wn, vw), 0.0, 1.0), 5.0);
		vec3 wc = color_water * (0.8 + 0.4 * nband.r);
		col = mix(col, wc, water);
		emit += v_sky_amb * sky_ambient_scale * fres * water * 2.2;
	}

	if (has_rivers && snow > 0.0) {
		// frozen rivers / lakes: grey-blue ice, not a bright snow stripe
		float frozen = smoothstep(0.55, 0.85, v_mask.g + n1 * 0.15) * snow * (1.0 - under);
		col = mix(col, vec3(0.5, 0.62, 0.72) * (0.85 + 0.25 * nband.r), frozen * 0.85);
		n = normalize(mix(n, up, frozen * 0.7));
	}

	// ---------- lava ----------
	if (lava_intensity > 0.0) {
		float lv = smoothstep(0.25, 0.7, v_mask.g + n1 * 0.3);
		float cracks = smoothstep(0.55, 0.15, nband.g);            // glowing crust cracks
		float flow = mix(cracks, 1.0, smoothstep(0.75, 0.95, v_mask.g + n2 * 0.2));
		if (near_f > 0.0) {
			// crust plates with glowing seams up close
			vec4 lp = tri(tex_ground, p / 8.0, w);
			flow = max(flow * (1.0 - near_f * 0.5), lp.b * near_f);
		}
		float heat = lv * flow;
		col = mix(col, vec3(0.05, 0.03, 0.025), lv * 0.85);       // dark basalt crust
		emit += color_lava * heat * lava_intensity * (0.6 + 0.8 * nband.r);
		emit += color_lava * smoothstep(0.1, 0.6, v_mask.g) * lava_intensity * 0.06; // ambient glow
	}

	float rough = mix(0.92, 0.82, rock);
	rough = mix(rough, 0.6, snow);
	rough = mix(rough, 0.25, ice * 0.7);
	rough = mix(rough, 0.3, wet * (1.0 - under));
	rough = mix(rough, 0.06, water);
	rough = mix(rough, 0.55, lava_intensity > 0.0 ? smoothstep(0.3, 0.8, v_mask.g) : 0.0);

	if (debug_view > 0) {
		vec3 dv = debug_view == 1 ? vec3(desert, forest, savanna) : (debug_view == 2 ? vec3(tundra, snow, beach)
			: (debug_view == 3 ? vec3(alien_b, alien_c, river) : (debug_view == 4 ? vec3(rock, scree, st)
			: vec3(moist, clamp(temp, 0.0, 1.0), 0.0))));
		col = dv * 0.8 + 0.05;
		emit = vec3(0.0);
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = mix(mix(mix(0.18, 0.35, rock), 0.5, snow), 0.5, max(wet, water));
	v_f0 = 0.08 * SPECULAR;
	if (water > 0.0) {
		v_f0 = mix(v_f0, 0.02, water);
	}
	AO = clamp(0.75 + curv * 1.5 + (1.0 - rock) * 0.1, 0.4, 1.0) * ao_near;
	AO_LIGHT_AFFECT = 0.4;
	// snow / ice / sand sparkle: sparse texels, twinkling with the view direction
	v_sparkle = 0.0;
	float spk_w = max(snow, ice) * (1.0 + glint) + beach * 0.25 + desert * 0.15;
	if (spk_w > 0.01 && dist < 60.0) {
		float s1 = tri(tex_ripple, p / 2.0 + vw * 0.03, w).a;
		float s2 = tri(tex_ripple, p / 2.0 * 1.37 - vw * 0.05, w).a;
		v_sparkle = s1 * s2 * 60.0 * spk_w * (1.0 - smoothstep(20.0, 60.0, dist));
	}
	v_wrap = surface_style == 3 ? 0.25 * max(snow, ice) : 0.0;     // soft, translucent snow / ice
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
	vec3 lc = LIGHT_COLOR * light_unattenuate * ATTENUATION / PI * v_sun_tint * v_shadow;
	float ndl_raw = dot(NORMAL, LIGHT);
	float ndl = clamp(ndl_raw, 0.0, 1.0);
	float ndl_w = clamp((ndl_raw + v_wrap) / (1.0 + v_wrap), 0.0, 1.0);
	float ndv = clamp(dot(NORMAL, VIEW), 1e-3, 1.0);
	vec3 h = normalize(LIGHT + VIEW);
	float ldh = clamp(dot(LIGHT, h), 0.0, 1.0);
	float fd90 = 0.5 + 2.0 * ROUGHNESS * ldh * ldh;
	float fl = 1.0 + (fd90 - 1.0) * pow(1.0 - ndl, 5.0);
	float fv = 1.0 + (fd90 - 1.0) * pow(1.0 - ndv, 5.0);
	DIFFUSE_LIGHT += lc * ndl_w * fl * fv;
	float a = ROUGHNESS * ROUGHNESS;
	float a2 = a * a;
	float ndh = clamp(dot(NORMAL, h), 0.0, 1.0);
	float dd = ndh * ndh * (a2 - 1.0) + 1.0;
	float D = a2 / (PI * dd * dd);
	float k = a * 0.5;
	float vis = 0.25 / ((ndl * (1.0 - k) + k) * (ndv * (1.0 - k) + k));
	float F = v_f0 + (1.0 - v_f0) * pow(1.0 - ldh, 5.0);
	SPECULAR_LIGHT += lc * ndl * D * vis * F * PI;
	// glints (snow crystals, mica in sand)
	SPECULAR_LIGHT += lc * ndl * v_sparkle;
}
