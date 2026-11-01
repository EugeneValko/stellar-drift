// Stellar Drift space sky.
//  * Low-frequency backdrop (Milky Way, dust, nebulae, hero galaxy, faint star dust) comes from a
//    cube atlas baked once at startup (src/space/space_sky.gd). Without a bake (editor preview)
//    it is evaluated live - identical result, just expensive.
//  * Resolved stars and small distant galaxies are computed per pixel as analytic, pixel-footprint
//    aware Gaussian splats: constant energy regardless of sub-pixel position -> no flicker or
//    shimmering when the camera rotates. Bright stars get screen-aligned diffraction spikes + halo.
//  * Nothing depends on TIME, so the radiance cubemap is only rebuilt when parameters change.
shader_type sky;
render_mode use_debanding;

#include "res://shaders/space_noise.gdshaderinc"
#include "res://shaders/space_backdrop.gdshaderinc"

group_uniforms sky;
uniform float sky_energy : hint_range(0.0, 8.0) = 1.0;
uniform bool use_baked = false;
uniform sampler2D baked_sky : filter_linear, repeat_disable;
uniform float baked_face_size = 1024.0;
uniform float bake_version = 0.0;

group_uniforms stars;
uniform float star_brightness : hint_range(0.0, 8.0) = 1.0;
uniform float star_density : hint_range(0.0, 3.0) = 1.0;
uniform float star_saturation : hint_range(0.0, 2.0) = 0.85;
uniform float star_psf_pixels : hint_range(0.5, 2.0) = 0.72;
uniform float milky_way_star_boost : hint_range(0.0, 4.0) = 1.4;
uniform float spike_strength : hint_range(0.0, 4.0) = 1.0;
uniform float spike_length : hint_range(0.0, 4.0) = 1.0;
uniform float spike_angle : hint_range(0.0, 1.57) = 0.0;
uniform float halo_strength : hint_range(0.0, 4.0) = 1.0;

group_uniforms galaxies;
uniform float galaxy_density : hint_range(0.0, 1.0) = 0.5;
uniform float galaxy_brightness : hint_range(0.0, 4.0) = 1.0;
group_uniforms;

vec4 sample_baked(int face, vec2 st) {
	float n = baked_face_size;
	vec2 local = (st * 0.5 + 0.5) * (n - 1.0) + 0.5;
	vec2 tile = vec2(float(face % 3), float(face / 3));
	vec2 uv = (tile * n + local) / vec2(3.0 * n, 2.0 * n);
	return textureLod(baked_sky, uv, 0.0);
}

vec3 star_color(float h) {
	// Rough main-sequence population: many K/M (orange), some G/F, few hot A/B (blue).
	float temp;
	if (h < 0.45) temp = mix(2900.0, 4600.0, h / 0.45);
	else if (h < 0.80) temp = mix(4600.0, 7200.0, (h - 0.45) / 0.35);
	else temp = mix(7200.0, 26000.0, pow((h - 0.80) / 0.20, 1.5));
	vec3 c = sn_blackbody(temp);
	float l = dot(c, vec3(0.2126, 0.7152, 0.0722));
	c = mix(vec3(l), c, star_saturation);
	return c / max(l, 0.05) * 0.8;
}

// One layer of resolved stars on an equi-angular cube grid of `n` cells per face edge.
// px_x / px_y: world-space direction delta per screen pixel (from derivatives).
vec3 star_layer(int face, vec2 st, vec3 d, vec3 px_x, vec3 px_y, float n, float prob,
		float fmin, float fmax, float fpow, int lid, bool fancy, float band) {
	vec2 g = (st * 0.5 + 0.5) * n;
	vec2 base = fancy ? floor(g) - 1.0 : floor(g - 0.5);
	int cnt = fancy ? 3 : 2;
	float ixx = 1.0 / max(dot(px_x, px_x), 1e-14);
	float iyy = 1.0 / max(dot(px_y, px_y), 1e-14);
	float sig = star_psf_pixels;
	float inv2s2 = 1.0 / (2.0 * sig * sig);
	float norm = 1.0 / (6.2831853 * sig * sig);
	float p = clamp(prob * star_density * (1.0 + milky_way_star_boost * band), 0.0, 1.0);
	float ca = cos(spike_angle), sa = sin(spike_angle);
	vec3 acc = vec3(0.0);
	for (int j = 0; j < cnt; j++)
	for (int i = 0; i < cnt; i++) {
		vec2 cell = base + vec2(float(i), float(j));
		if (cell.x < 0.0 || cell.y < 0.0 || cell.x >= n || cell.y >= n) continue;
		vec3 h = sn_hash3i(ivec3(int(cell.x), int(cell.y), face * 7919 + seed * 131 + lid * 1009));
		if (h.x > p) continue;
		vec3 h2 = sn_hash3i(ivec3(int(cell.x), int(cell.y), face * 7919 + seed * 131 + lid * 1009 + 577));
		vec2 sst = (cell + 0.1 + 0.8 * h.yz) / n * 2.0 - 1.0;
		vec3 sd = sn_face_to_dir(face, sst);
		vec3 off = sd - d;
		vec2 q = vec2(dot(off, px_x) * ixx, dot(off, px_y) * iyy); // offset in pixels
		float r2 = dot(q, q);
		float flux = mix(fmin, fmax, pow(h2.x, fpow));
		vec3 c = star_color(h2.y);
		float v = exp(-r2 * inv2s2) * norm;
		if (fancy) {
			float r = sqrt(r2);
			// soft halo
			v += halo_strength * 0.002 * exp(-r / (2.0 + 0.5 * sqrt(flux)));
			// diffraction spikes for the brightest ones (screen aligned)
			float sk = smoothstep(6.0, 16.0, flux);
			if (sk > 0.0) {
				vec2 rq = vec2(ca * q.x - sa * q.y, sa * q.x + ca * q.y);
				float len = spike_length * (2.5 + 2.2 * sqrt(flux));
				float w2 = 1.0 / (2.0 * 0.55 * 0.55);
				float s = exp(-abs(rq.x) / len) * exp(-rq.y * rq.y * w2)
						+ exp(-abs(rq.y) / len) * exp(-rq.x * rq.x * w2);
				// faint diagonal secondary spikes
				vec2 dq = vec2(rq.x + rq.y, rq.x - rq.y) * 0.7071;
				s += 0.25 * (exp(-abs(dq.x) / (len * 0.5)) * exp(-dq.y * dq.y * w2)
						+ exp(-abs(dq.y) / (len * 0.5)) * exp(-dq.x * dq.x * w2));
				v += spike_strength * 0.006 * sk * s;
			}
		}
		acc += c * flux * v;
	}
	return acc;
}

// Small distant galaxies: one candidate per coarse cell, smooth analytic profile.
vec3 galaxy_layer(int face, vec2 st, vec3 d, vec3 px_x, vec3 px_y) {
	float n = 5.0;
	vec2 g = (st * 0.5 + 0.5) * n;
	vec2 cell = floor(g);
	vec3 h = sn_hash3i(ivec3(int(cell.x), int(cell.y), face * 7919 + seed * 131 + 40001));
	if (h.x > galaxy_density) return vec3(0.0);
	vec3 h2 = sn_hash3i(ivec3(int(cell.x), int(cell.y), face * 7919 + seed * 131 + 40503));
	vec2 sst = (cell + 0.25 + 0.5 * h.yz) / n * 2.0 - 1.0;
	vec3 gd = sn_face_to_dir(face, sst);
	float size = mix(0.0018, 0.0085, h2.x * h2.x);
	vec3 off = d - gd;
	if (dot(off, off) > size * size * 16.0) return vec3(0.0);
	vec3 t1 = normalize(cross(gd, abs(gd.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0)));
	vec3 t2 = cross(gd, t1);
	vec2 p = vec2(dot(off, t1), dot(off, t2)) / size;
	float a = h2.y * 6.2831;
	p = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * p;
	float incl = mix(0.18, 1.0, h2.z);
	p.y /= incl;
	float r = length(p);
	// pixel footprint in galaxy units -> keeps the core from aliasing
	float pix = length(px_x) / size;
	float rc = max(0.06, pix * 0.7);
	bool spiral = h.z > 0.35;
	vec3 col;
	if (spiral) {
		float th = atan(p.y, p.x);
		float arms = pow(0.5 + 0.5 * cos(2.0 * th - 5.0 * log(max(r, 0.03))), 2.0);
		arms = mix(0.5, arms, smoothstep(pix * 3.0, pix * 6.0, 0.25));
		col = vec3(1.0, 0.85, 0.65) * exp(-r / rc) * 1.2 + vec3(0.6, 0.72, 1.0) * exp(-r / 0.35) * (0.25 + 0.9 * arms);
	} else {
		col = vec3(1.0, 0.82, 0.62) * (exp(-r / rc) + 0.5 * exp(-r / 0.3));
	}
	float bright = galaxy_brightness * mix(0.02, 0.09, h.x / max(galaxy_density, 1e-3));
	return col * bright * smoothstep(4.0, 2.0, r);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 px_x = dFdx(EYEDIR);
	vec3 px_y = dFdy(EYEDIR);
	vec2 st;
	int face = sn_dir_to_face(d, st);
	vec4 bd;
	if (use_baked) {
		bd = sample_baked(face, st);
	} else {
		bd = sb_backdrop(d, face, st, faint_star_grid / 1023.0);
	}
	vec3 col = bd.rgb;
	if (!AT_CUBEMAP_PASS) {
		float band = sb_band_density(d);
		vec3 stars = vec3(0.0);
		stars += star_layer(face, st, d, px_x, px_y, 200.0, 0.06, 0.08, 1.0, 3.0, 1, false, band * 3.0);
		stars += star_layer(face, st, d, px_x, px_y, 72.0, 0.12, 0.3, 3.0, 3.5, 2, false, band * 1.2);
		stars += star_layer(face, st, d, px_x, px_y, 18.0, 0.32, 1.5, 30.0, 5.0, 3, true, band * 0.3);
		col += stars * star_brightness * bd.a;
		col += galaxy_layer(face, st, d, px_x, px_y) * bd.a;
	}
	COLOR = col * sky_energy;
}
