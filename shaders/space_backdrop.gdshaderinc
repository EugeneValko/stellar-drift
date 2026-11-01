// Low-frequency space backdrop: background gradient + galactic cirrus, Milky Way band with
// granular star clouds and filamentary dust lanes, emission nebula complexes (per-complex
// palettes: teal/gold, magenta/violet, crimson/amber) with dark pillars and bright ionisation
// rims, a "hero" spiral galaxy and a dense layer of faint unresolved stars.
// Included by shaders/space_sky_bake.gdshader (baked once into a cube atlas at startup) and by
// shaders/space_sky.gdshader (live fallback when no bake is bound, e.g. in the editor).
// Requires space_noise.gdshaderinc to be included first.
//
// Output: rgb = HDR emission, a = transmission of the dust in front (multiplies resolved stars).

group_uniforms backdrop;
uniform int seed = 7;
uniform float backdrop_energy : hint_range(0.0, 8.0) = 1.0;
uniform vec3 background_color_a : source_color = vec3(0.30, 0.42, 1.00);
uniform vec3 background_color_b : source_color = vec3(0.70, 0.28, 1.00);
uniform float background_brightness : hint_range(0.0, 0.05) = 0.0030;
uniform vec3 cirrus_color : source_color = vec3(0.45, 0.62, 0.85);
uniform float cirrus_brightness : hint_range(0.0, 0.2) = 0.012;

group_uniforms milky_way;
uniform vec3 galaxy_normal = vec3(0.32, 0.86, -0.40);
uniform vec3 galaxy_center = vec3(-0.55, 0.15, -0.82);
uniform float band_width : hint_range(0.02, 0.6) = 0.12;
uniform float band_brightness : hint_range(0.0, 2.0) = 0.10;
uniform vec3 band_color : source_color = vec3(0.78, 0.80, 0.92);
uniform vec3 core_color : source_color = vec3(1.00, 0.76, 0.50);
uniform float core_brightness : hint_range(0.0, 4.0) = 0.6;
uniform float core_length : hint_range(0.05, 1.5) = 0.55;
uniform float core_height : hint_range(0.02, 0.6) = 0.12;
uniform float dust_strength : hint_range(0.0, 4.0) = 1.0;
uniform vec3 dust_color : source_color = vec3(0.42, 0.24, 0.14);
uniform float dust_glow : hint_range(0.0, 0.2) = 0.018;

group_uniforms nebulae;
// palette A (SHO-like): outer gold, inner teal
uniform vec3 nebula_a_outer : source_color = vec3(1.00, 0.58, 0.20);
uniform vec3 nebula_a_inner : source_color = vec3(0.12, 0.80, 0.85);
// palette B: outer magenta, inner sky-cyan
uniform vec3 nebula_b_outer : source_color = vec3(0.90, 0.14, 0.50);
uniform vec3 nebula_b_inner : source_color = vec3(0.40, 0.78, 1.00);
// palette C: outer crimson, inner amber
uniform vec3 nebula_c_outer : source_color = vec3(0.85, 0.10, 0.12);
uniform vec3 nebula_c_inner : source_color = vec3(1.00, 0.62, 0.30);
// wave 4: two extra hand-placed complexes with their own palettes so every part of the sky
// has something (D: violet veil with an emerald OIII core, E: rose HII with a pale gold core)
uniform vec3 nebula_d_outer : source_color = vec3(0.45, 0.36, 0.85);
uniform vec3 nebula_d_inner : source_color = vec3(0.30, 0.85, 0.75);
uniform vec3 nebula_d_dir = vec3(0.807, -0.574, 0.142);    // below Aurelion seen from Terra
uniform float nebula_d_size : hint_range(0.0, 1.5) = 0.5;  // angular radius (rad), 0 = off
uniform vec3 nebula_e_outer : source_color = vec3(0.95, 0.26, 0.45);
uniform vec3 nebula_e_inner : source_color = vec3(0.55, 0.75, 1.00);
uniform vec3 nebula_e_dir = vec3(0.760, 0.545, -0.355);    // Terra's evening / night sky
uniform float nebula_e_size : hint_range(0.0, 1.5) = 0.42;
uniform float nebula_brightness : hint_range(0.0, 4.0) = 1.4;
uniform float nebula_coverage : hint_range(0.0, 1.0) = 0.40;
uniform float nebula_dust : hint_range(0.0, 4.0) = 1.4;
uniform float nebula_scale : hint_range(0.5, 8.0) = 3.0;
uniform float nebula_warp : hint_range(0.0, 4.0) = 0.6;
uniform float nebula_depth : hint_range(0.0, 4.0) = 1.6;
uniform int nebula_steps : hint_range(1, 16) = 6;

group_uniforms hero_galaxy;
uniform vec3 hero_dir = vec3(0.55, 0.42, 0.72);
uniform float hero_size : hint_range(0.0, 0.3) = 0.075;
uniform float hero_tilt : hint_range(-3.2, 3.2) = 0.6;
uniform float hero_incl : hint_range(0.1, 1.0) = 0.38;
uniform float hero_brightness : hint_range(0.0, 4.0) = 0.8;

group_uniforms faint_stars;
uniform float faint_star_grid : hint_range(64.0, 900.0) = 420.0;
uniform float faint_star_density : hint_range(0.0, 1.0) = 0.30;
uniform float faint_star_brightness : hint_range(0.0, 4.0) = 0.6;
group_uniforms;

vec3 sb_seed_offset() {
	vec3 h = sn_hash3i(ivec3(seed, 913, 271));
	return (h - 0.5) * 517.0;
}

// Galactic frame (x -> galactic centre, y -> galactic north pole, z completes).
vec3 sb_galactic(vec3 d) {
	vec3 n = normalize(galaxy_normal);
	vec3 c = galaxy_center - n * dot(galaxy_center, n);
	c = normalize(c);
	vec3 e = cross(n, c);
	return vec3(dot(d, c), dot(d, n), dot(d, e));
}

// Cheap analytic band density (used by star layers to concentrate stars in the Milky Way).
float sb_band_density(vec3 d) {
	vec3 g = sb_galactic(d);
	float lon = atan(g.z, g.x);
	float core_t = exp(-lon * lon / (core_length * core_length));
	float w = band_width * (1.0 + 1.1 * core_t);
	return exp(-g.y * g.y / (w * w * 2.0)) * (1.0 + 1.5 * core_t);
}

vec3 sb_hero_galaxy(vec3 d) {
	vec3 hd = normalize(hero_dir);
	float cd = dot(d, hd);
	if (hero_size <= 0.0 || cd < cos(hero_size * 3.0)) return vec3(0.0);
	vec3 t1 = normalize(cross(hd, abs(hd.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
	vec3 t2 = cross(hd, t1);
	vec2 p = vec2(dot(d, t1), dot(d, t2)) / hero_size;
	float cs = cos(hero_tilt), sn = sin(hero_tilt);
	p = mat2(vec2(cs, sn), vec2(-sn, cs)) * p;
	p.y /= hero_incl;
	float r = length(p);
	float th = atan(p.y, p.x);
	// logarithmic two-arm spiral, slightly noisy
	float wob = sn_fbm(vec3(p * 4.0, 1.3), 3, 0.5);
	float arm_phase = 2.0 * th - 5.2 * log(max(r, 0.02)) + wob * 1.2;
	float arms = pow(0.5 + 0.5 * cos(arm_phase), 2.5);
	float clump = sn_fbm(vec3(p * 11.0, 3.1), 5, 0.6) * 0.5 + 0.5;
	float disk = exp(-r / 0.30) * smoothstep(1.7, 0.5, r);
	float core = exp(-r / 0.04) * 2.2 + exp(-r / 0.12) * 0.6;
	// dust lane on the inner side of the arms
	float lane = pow(0.5 + 0.5 * cos(arm_phase - 1.0), 5.0) * smoothstep(0.06, 0.3, r) * smoothstep(1.4, 0.4, r);
	vec3 arm_col = vec3(0.55, 0.70, 1.0);
	vec3 core_col = vec3(1.0, 0.80, 0.56);
	vec3 col = core_col * core;
	col += mix(core_col, arm_col, smoothstep(0.05, 0.45, r)) * disk * (0.2 + 1.5 * arms * clump);
	// pink HII knots along the arms
	float knots = smoothstep(0.75, 0.97, sn_gnoise(vec3(p * 30.0, 7.7)) * 0.5 + 0.5) * arms * disk;
	col += vec3(1.0, 0.35, 0.6) * knots * 3.0;
	col *= 1.0 - 0.8 * clamp(lane * clump * 2.5, 0.0, 1.0);
	// faint outer halo
	col += vec3(0.6, 0.65, 0.8) * exp(-r / 0.7) * 0.06;
	return col * hero_brightness;
}

// Dense faint stars on an equi-angular cube grid. texel_cells = bake texel size in grid cells.
vec3 sb_faint_stars(int face, vec2 st, float texel_cells, float density_boost) {
	if (faint_star_density <= 0.0) return vec3(0.0);
	float N = faint_star_grid;
	vec2 g = (st * 0.5 + 0.5) * N;
	vec2 base = floor(g - 0.5);
	float sig = max(0.6 * texel_cells, 0.12);
	float p_star = clamp(faint_star_density * (0.25 + 2.2 * density_boost), 0.0, 1.0);
	vec3 acc = vec3(0.0);
	for (int j = 0; j <= 1; j++)
	for (int i = 0; i <= 1; i++) {
		vec2 cell = base + vec2(float(i), float(j));
		vec3 h = sn_hash3i(ivec3(int(cell.x), int(cell.y), face * 7919 + seed * 131 + 17));
		if (h.x > p_star) continue;
		vec3 h2 = sn_hash3i(ivec3(int(cell.x), int(cell.y), face * 7919 + seed * 131 + 4093));
		vec2 sp = cell + 0.2 + 0.6 * h.yz;
		vec2 dd = g - sp;
		float r2 = dot(dd, dd);
		float flux = faint_star_brightness * (0.004 + 0.05 * pow(h2.x, 6.0));
		float temp = mix(3200.0, 11000.0, pow(h2.y, 1.6));
		vec3 c = sn_blackbody(temp);
		c = mix(vec3(dot(c, vec3(0.3333))), c, 0.6);
		// energy-normalised gaussian (in units of a 0.15-cell reference spot)
		acc += c * flux * exp(-r2 / (2.0 * sig * sig)) * (0.0225 / (sig * sig));
	}
	return acc;
}

// Full backdrop. face/st are the cube-atlas coordinates of `d` (for the faint-star grid).
vec4 sb_backdrop(vec3 d, int face, vec2 st, float texel_cells) {
	vec3 q = d + sb_seed_offset();
	vec3 g = sb_galactic(d);
	float lat = asin(clamp(g.y, -1.0, 1.0));
	float lon = atan(g.z, g.x);
	// galactic-aligned, latitude-compressed domain -> structures elongated along the band
	vec3 ga = vec3(g.x, g.y * 2.8, g.z) + sb_seed_offset() * 0.37;

	// --- background gradient + faint galactic cirrus
	float bgn = sn_fbm(q * 1.3, 3, 0.5) * 0.5 + 0.5;
	vec3 col = mix(background_color_a, background_color_b, smoothstep(0.25, 0.75, bgn));
	col *= background_brightness * (0.4 + 1.2 * bgn * bgn);
	float cw = sn_fbm(q * 2.0 + 31.0, 3, 0.5);
	float cir = sn_ridged(q * 3.2 + vec3(cw * 1.4), 6, 0.62);
	float cir_mask = smoothstep(0.45, 0.8, sn_fbm(q * 0.9 + 17.0, 3, 0.5) * 0.5 + 0.5);
	col += cirrus_color * cirrus_brightness * pow(cir, 3.0) * cir_mask;

	// --- Milky Way band
	float warp = sn_fbm(q * 2.1, 4, 0.5);
	float latw = lat + 0.04 * warp;
	float core_t = exp(-lon * lon / (core_length * core_length));
	float wvar = 0.75 + 0.5 * (sn_fbm(q * 1.4 + 7.0, 3, 0.5) * 0.5 + 0.5);
	float width = band_width * (1.0 + 1.0 * core_t) * wvar;
	float band = exp(-latw * latw / (width * width));
	float halo = exp(-latw * latw / (width * width * 9.0));
	float clouds = sn_fbm(ga * 5.0 + vec3(warp), 6, 0.55) * 0.5 + 0.5;
	clouds = pow(smoothstep(0.2, 0.85, clouds), 1.6);
	float grain = sn_fbm(q * 70.0, 3, 0.6) * 0.5 + 0.5;
	float bulge = exp(-(lon * lon) / (core_length * core_length * 0.30) - (lat * lat) / (core_height * core_height));
	vec3 bcol = mix(band_color, core_color, core_t * 0.75);
	float patch = sn_fbm(ga * 1.5 + 23.0, 3, 0.5) * 0.5 + 0.5;
	patch = 0.35 + 1.3 * smoothstep(0.25, 0.8, patch);
	vec3 light = bcol * band_brightness * patch * (band * (0.15 + 1.9 * clouds) * (0.6 + 0.8 * grain) + halo * 0.06);
	light += core_color * core_brightness * bulge * (0.55 + 0.9 * clouds) * (0.8 + 0.4 * grain);

	// --- faint unresolved stars (concentrated in the band)
	float star_boost = band * (0.6 + 1.2 * clouds) * (1.0 + 1.0 * core_t) + 0.25 * halo;
	vec3 faint = sb_faint_stars(face, st, texel_cells, star_boost);

	// --- dust: big dark clouds + thin filaments, elongated along the plane
	float dw = sn_fbm(ga * 3.0 + 11.0, 4, 0.5);
	vec3 gd = ga * 4.6 + vec3(dw * 1.4, dw * -0.8, dw * 1.1);
	float dust_big = sn_fbm(gd, 7, 0.56) * 0.5 + 0.5;
	float dust_fil = sn_ridged(ga * 8.5 + vec3(dw * 2.2), 6, 0.62);
	float lane_lat = latw - 0.22 * width * (0.6 + 0.4 * sn_fbm(q * 2.6 + 3.0, 3, 0.5));
	float lane_mask = exp(-lane_lat * lane_lat / (width * width * 0.40));
	float wide_mask = exp(-latw * latw / (width * width * 5.0));
	float D = lane_mask * (smoothstep(0.46, 0.74, dust_big) * 1.3
			+ pow(dust_fil, 3.0) * smoothstep(0.30, 0.55, dust_big) * 1.6);
	D += wide_mask * (smoothstep(0.62, 0.86, dust_big) * 0.6 + pow(dust_fil, 4.0) * 0.35 * smoothstep(0.45, 0.65, dust_big));
	D *= dust_strength;

	// --- nebula complexes: short volumetric raymarch through a slab of 3D noise (gas emits,
	// dust + dense gas absorb, front-to-back). Baked once, so the step count is affordable.
	float region_n = sn_fbm(q * 0.95 + 3.3, 6, 0.55) * 0.5 + 0.5;
	float region = smoothstep(1.0 - nebula_coverage, 1.0 - nebula_coverage + 0.30, region_n);
	region = region * region * (3.0 - 2.0 * region);
	// hand-placed complexes: ragged angular masks (noise-broken edges, not discs)
	float md = 0.0;
	float me = 0.0;
	if (nebula_d_size > 0.0 || nebula_e_size > 0.0) {
		// ragged, lobed outlines (strong low-frequency warp) and a clumpy, filamentary interior
		float edge_n = sn_fbm(q * 1.4 + 51.0, 6, 0.62);
		float clump = sn_fbm(q * 3.6 + 13.0, 6, 0.62) * 0.5 + 0.5;
		float wisp = sn_ridged(q * 2.6 + 7.0, 5, 0.6);
		if (nebula_d_size > 0.0) {
			float a = acos(clamp(dot(d, normalize(nebula_d_dir)), -1.0, 1.0)) / nebula_d_size;
			float core = smoothstep(1.1, 0.1, a + edge_n * 1.7);
			md = core * smoothstep(0.38, 0.75, clump + (1.0 - a) * 0.2) + smoothstep(1.4, 0.4, a) * wisp * wisp * 0.35;
		}
		if (nebula_e_size > 0.0) {
			float a = acos(clamp(dot(d, normalize(nebula_e_dir)), -1.0, 1.0)) / nebula_e_size;
			float core = smoothstep(1.1, 0.1, a + edge_n * 1.7);
			me = core * smoothstep(0.38, 0.75, clump + (1.0 - a) * 0.2) + smoothstep(1.4, 0.4, a) * wisp * wisp * 0.35;
		}
	}
	region = max(region, max(md, me) * 0.7);
	vec3 neb = vec3(0.0);
	float Tn = 1.0;
	if (region > 0.0005) {
		// which palette this complex uses (large-scale, mostly one palette per complex)
		float pal = sn_fbm(q * 0.8 + 40.0, 2, 0.5) * 0.5 + 0.5;
		float wa = 1.0 - smoothstep(0.38, 0.48, pal);
		float wc = smoothstep(0.56, 0.66, pal);
		float wb = max(1.0 - wa - wc, 0.0);
		vec3 outer = nebula_a_outer * wa + nebula_b_outer * wb + nebula_c_outer * wc;
		vec3 inner = nebula_a_inner * wa + nebula_b_inner * wb + nebula_c_inner * wc;
		float kd = smoothstep(0.0, 0.6, md);
		float ke = smoothstep(0.0, 0.6, me);
		outer = mix(mix(outer, nebula_d_outer, kd), nebula_e_outer, ke);
		inner = mix(mix(inner, nebula_d_inner, kd), nebula_e_inner, ke);

		vec3 w1 = vec3(sn_fbm(q * 2.0 + 1.7, 4, 0.5), sn_fbm(q * 2.0 + 9.2, 4, 0.5), sn_fbm(q * 2.0 + 4.1, 4, 0.5));
		vec3 base = q * nebula_scale + w1 * nebula_warp;
		float hue_n = sn_fbm(q * 2.4 + 60.0, 3, 0.5);
		float fil = sn_ridged(base * 3.1 + 2.0, 5, 0.62);
		fil = fil * fil * fil;
		int steps = max(nebula_steps, 1);
		float dt = 1.0 / float(steps);
		for (int i = 0; i < steps; i++) {
			float t = (float(i) + 0.5) * dt;
			vec3 p = base + d * (nebula_depth * (t - 0.5));
			float g = sn_fbm(p, 6, 0.56);
			float gas = region * exp(4.6 * g - 0.5);
			// foreground dust: mostly 2D (crisp edges), only in the front part of the slab
			vec3 pd = base * 1.15 + 77.0 + d * (0.35 * (t - 0.5));
			float dk = sn_fbm(pd, 7, 0.58);
			float front = 1.0 - smoothstep(0.35, 0.75, t);
			float dust = region * smoothstep(0.03, 0.16, dk) * nebula_dust * front;
			// ionisation front: bright rim just outside the dust
			float rim = exp(-pow((dk + 0.015) / 0.045, 2.0)) * front;
			vec3 ecol = mix(outer, inner, smoothstep(0.05, 0.55, hue_n * 0.5 + g));
			ecol = mix(ecol, vec3(1.0, 0.95, 0.9), smoothstep(2.5, 7.0, gas) * 0.45);
			vec3 e = ecol * gas * (0.85 + 0.35 * fil) + mix(inner, vec3(1.0), 0.5) * gas * rim * 1.8;
			neb += Tn * e * dt;
			Tn *= exp(-(dust * 4.5 + gas * 0.08) * dt);
		}
		neb *= nebula_brightness * 0.35;
	}

	float T = exp(-D * 1.7);
	vec3 hero = sb_hero_galaxy(d);
	vec3 outc = (col + light + faint + hero) * T * Tn;
	outc += neb * mix(1.0, T, 0.6);
	// dust faintly lit by the galaxy (brownish lanes, not pure black)
	outc += dust_color * dust_glow * clamp(D, 0.0, 1.5) * (band + 0.2 * halo + bulge * 2.0);
	return vec4(outc * backdrop_energy, T * Tn);
}
