// Physically based single scattering (Rayleigh + Mie + ozone-like absorption) for a spherical
// planet atmosphere. Shared by atmosphere passes, clouds (aerial perspective), ocean (sky
// reflection, sun color) and any surface shader that wants sunlight transmittance.
//
// All positions are planet-centred, world-oriented, in metres (p = world_pos - planet_center).
// Light-ray optical depth is analytic (Chapman-function approximation) so each view sample
// costs only a couple of exp(): quality knob is the number of view samples.
#ifndef ATMO_COMMON_INC
#define ATMO_COMMON_INC

#include "res://shaders/include/sun_globals.gdshaderinc"

group_uniforms atmosphere;
uniform float atmo_planet_radius = 60000.0;  // density reference radius (sea level)
uniform float atmo_top_radius = 72000.0;     // shell where the march starts/ends
uniform float atmo_ground_radius = 60000.0;  // hard stop sphere (ocean / lowest terrain); <=0 off
uniform float atmo_rayleigh_height = 1500.0;
uniform float atmo_mie_height = 450.0;
uniform vec3 atmo_rayleigh = vec3(3.1e-5, 7.2e-5, 1.77e-4);   // scattering, 1/m at sea level
uniform vec3 atmo_mie = vec3(2.5e-5);                          // scattering, 1/m
uniform vec3 atmo_mie_absorb = vec3(2.5e-6);                   // absorption, 1/m
uniform vec3 atmo_ozone = vec3(3.5e-6, 1.0e-5, 4.5e-7);        // absorption on rayleigh profile
uniform float atmo_mie_g = 0.78;
uniform float atmo_intensity = 3.14159;      // sun irradiance multiplier (PI = physical)
uniform float atmo_multi_scatter = 0.35;     // cheap isotropic multiple-scattering term
uniform float atmo_shadow_soft = 0.6;        // planet shadow softness, in rayleigh heights
uniform float atmo_sun_path_scale = 2.2;     // >1 = redder sunsets (grazing sun paths only)
uniform int atmo_steps = 14;                 // view-ray samples (quality knob)
group_uniforms;

// Optical column (density-weighted length, density 1 at planet radius) from radius r toward
// direction with cos(zenith)=mu, to infinity. Chapman approximation with the grazing identity.
float atmo_chapman(float r, float mu, float H) {
	float x = r / H;
	float X = atmo_planet_radius / H;
	float c = sqrt(1.5707963 * x);
	if (mu >= 0.0) {
		return H * exp(X - x) / (mu + 1.0 / c);
	}
	float s = sqrt(max(1.0 - mu * mu, 0.0));
	float x0 = x * s;
	float c0 = sqrt(1.5707963 * x0);
	return H * (2.0 * c0 * exp(min(X - x0, 80.0)) - exp(X - x) / (-mu + 1.0 / c));
}

// Hard-ish planet shadow for a light ray leaving point p (radius r, cos zenith mus).
float atmo_planet_shadow(float r, float mus) {
	if (mus >= 0.0) return 1.0;
	float d = r * sqrt(max(1.0 - mus * mus, 0.0)); // closest approach to centre
	float w = atmo_rayleigh_height * atmo_shadow_soft;
	return smoothstep(atmo_planet_radius - w, atmo_planet_radius + w, d);
}

vec3 atmo_sun_optical_depth(float r, float mus) {
	float cr = min(atmo_chapman(r, mus, atmo_rayleigh_height), 1e9);
	float cm = min(atmo_chapman(r, mus, atmo_mie_height), 1e9);
	// artistic: compressed planets have short grazing paths; lengthen them near the horizon so
	// sunsets get Earth-like reddening without making the daytime sky denser
	float k = 1.0 + (atmo_sun_path_scale - 1.0) * (1.0 - clamp(mus * 3.0, 0.0, 1.0));
	return ((atmo_rayleigh + atmo_ozone) * cr + (atmo_mie + atmo_mie_absorb) * cm) * k;
}

// Transmittance of sunlight arriving at point p (planet-centred). Includes planet shadow.
vec3 atmo_sun_transmittance(vec3 p, vec3 L) {
	float r = length(p);
	float mus = dot(p, L) / r;
	return exp(-atmo_sun_optical_depth(r, mus)) * atmo_planet_shadow(r, mus);
}

// Sun irradiance (physical) reaching point p, i.e. what a surface there is lit with.
vec3 atmo_sun_irradiance(vec3 p, vec3 L) {
	return sun_color.rgb * sun_intensity * atmo_sun_transmittance(p, L);
}

float atmo_phase_rayleigh(float mu) {
	return 0.0596831 * (1.0 + mu * mu);
}

float atmo_phase_mie(float mu, float g) {
	// Cornette-Shanks
	float g2 = g * g;
	return 0.1193662 * (1.0 - g2) * (1.0 + mu * mu)
		/ ((2.0 + g2) * pow(max(1.0 + g2 - 2.0 * g * mu, 1e-4), 1.5));
}

// Clips the ray [0, t_max] to the atmosphere shell and ground sphere.
// Returns false if nothing to integrate.
bool atmo_ray_range(vec3 ro, vec3 rd, float t_max, out float t0, out float t1) {
	vec2 top = sd_ray_sphere(ro, rd, atmo_top_radius);
	t0 = max(top.x, 0.0);
	t1 = min(top.y, t_max);
	if (atmo_ground_radius > 0.0) {
		vec2 g = sd_ray_sphere(ro, rd, atmo_ground_radius);
		if (g.x > 0.0) t1 = min(t1, g.x);
	}
	return t1 > t0;
}

// Sample position along [t0, t0+len]: quadratic distribution when starting inside the
// atmosphere (more samples near the camera for aerial perspective).
void atmo_segment(int i, int n, float t0, float len, float k, float jitter, out float t, out float ds) {
	float u0 = float(i) / float(n);
	float u1 = float(i + 1) / float(n);
	float a = t0 + len * pow(u0, k);
	float b = t0 + len * pow(u1, k);
	ds = b - a;
	t = a + ds * jitter;
}

vec3 atmo_extinction(float r, out float dr, out float dm) {
	float h = r - atmo_planet_radius;
	dr = exp(-h / atmo_rayleigh_height);
	dm = exp(-h / atmo_mie_height);
	return dr * (atmo_rayleigh + atmo_ozone) + dm * (atmo_mie + atmo_mie_absorb);
}

// Single scattering along ro + rd*t, t in [0, t_max]. Returns in-scattered radiance (same
// units as surfaces lit by sun_intensity), T = view transmittance.
vec3 atmo_scatter(vec3 ro, vec3 rd, float t_max, int steps, float jitter, out vec3 T) {
	T = vec3(1.0);
	float t0, t1;
	if (!atmo_ray_range(ro, rd, t_max, t0, t1)) return vec3(0.0);
	vec3 L = sd_sun_dir();
	float len = t1 - t0;
	float k = (length(ro) < atmo_top_radius) ? 2.0 : 1.0;
	vec3 od = vec3(0.0);
	vec3 sum_r = vec3(0.0);
	vec3 sum_m = vec3(0.0);
	for (int i = 0; i < steps; i++) {
		float t, ds;
		atmo_segment(i, steps, t0, len, k, jitter, t, ds);
		vec3 p = ro + rd * t;
		float r = length(p);
		float dr, dm;
		vec3 ext = atmo_extinction(r, dr, dm);
		vec3 od_here = od + ext * (ds * jitter);
		od += ext * ds;
		float mus = dot(p, L) / r;
		vec3 tr = exp(-(od_here + atmo_sun_optical_depth(r, mus))) * atmo_planet_shadow(r, mus);
		sum_r += tr * (dr * ds);
		sum_m += tr * (dm * ds);
	}
	T = exp(-od);
	float mu = dot(rd, L);
	vec3 E_sun = sun_color.rgb * sun_intensity * atmo_intensity;
	vec3 sr = sum_r * atmo_rayleigh;
	vec3 sm = sum_m * atmo_mie;
	return E_sun * (sr * atmo_phase_rayleigh(mu) + sm * atmo_phase_mie(mu, atmo_mie_g)
		+ (sr + sm) * (atmo_multi_scatter * SD_INV_4PI));
}

// View transmittance only (cheap; no light term). Must use the same sampling as atmo_scatter.
vec3 atmo_transmittance(vec3 ro, vec3 rd, float t_max, int steps, float jitter) {
	float t0, t1;
	if (!atmo_ray_range(ro, rd, t_max, t0, t1)) return vec3(1.0);
	float len = t1 - t0;
	float k = (length(ro) < atmo_top_radius) ? 2.0 : 1.0;
	vec3 od = vec3(0.0);
	for (int i = 0; i < steps; i++) {
		float t, ds;
		atmo_segment(i, steps, t0, len, k, jitter, t, ds);
		float dr, dm;
		od += atmo_extinction(length(ro + rd * t), dr, dm) * ds;
	}
	return exp(-od);
}

// Quad sharing for the full-screen atmosphere passes: the 4 pixels of a 2x2 quad march half the
// samples each, at interleaved (randomly rotated) quarter offsets; atmo_quad_blend() then mixes in
// the horizontal and vertical neighbours (1/2 own + 1/4 + 1/4). Halves the march cost; the result
// is smooth anyway. Not across depth edges (sd jumps: terrain silhouettes).
uniform bool atmo_quad_share = true;

int atmo_quad_steps(int steps) {
	return atmo_quad_share ? max((steps + 1) / 2, 4) : steps;
}

float atmo_quad_jitter(vec2 frag, float jitter) {
	if (!atmo_quad_share) return jitter;
	float px = mod(floor(frag.x), 2.0);
	float py = mod(floor(frag.y), 2.0);
	float rot = floor(fract(sin(dot(floor(frag * 0.5), vec2(39.346, 11.135))) * 43758.5453) * 4.0);
	return (jitter + mod(px + 2.0 * py + rot, 4.0)) * 0.25;
}

// Must be called in uniform control flow (uses fine derivatives).
vec3 atmo_quad_blend(vec3 v, vec2 frag, float sd) {
	float okx = abs(dFdxFine(sd)) < max(0.02 * sd, 60.0) ? 1.0 : 0.0;
	float oky = abs(dFdyFine(sd)) < max(0.02 * sd, 60.0) ? 1.0 : 0.0;
	float hx = (mod(floor(frag.x), 2.0) < 0.5 ? 0.25 : -0.25) * okx;
	float hy = (mod(floor(frag.y), 2.0) < 0.5 ? 0.25 : -0.25) * oky;
	vec3 r = v + dFdxFine(v) * hx + dFdyFine(v) * hy;
	return atmo_quad_share ? r : v;
}

// Approximate sky irradiance (hemisphere around the local up) at point p, for ambient light
// on clouds / water / terrain. Uses one short zenith march.
vec3 atmo_sky_ambient(vec3 p) {
	vec3 up = normalize(p);
	vec3 T;
	vec3 zen = atmo_scatter(p, up, 1e30, 4, 0.5, T);
	vec3 hor = atmo_scatter(p, normalize(up * 0.25 + normalize(sd_sun_dir() - up * dot(sd_sun_dir(), up) + vec3(1e-4))), 1e30, 4, 0.5, T);
	return (zen + hor) * 0.5 * SD_PI;
}

#endif
