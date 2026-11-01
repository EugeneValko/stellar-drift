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
uniform float atmo_sun_path_window = 3.0;    // path scale fades out above mus = 1 / window
uniform int atmo_steps = 14;                 // view-ray samples (quality knob)
// wave 4 (beauty): ozone on its own, taller profile (absorbs the long grazing twilight paths high
// up -> blue hour / purple twilight instead of olive); <= 0 = on the Rayleigh profile (old look)
uniform float atmo_ozone_height = 0.0;
// multiple scattering: light that reached the air from the whole lit sky (not only straight from
// the sun). Brighter, bluer horizon by day; survives a few degrees after sunset (twilight glow).
// Colour = the column's own scattering (1 - exp(-tau_vertical)); `lift` softens / extends it past
// the terminator (cos of the extra sun elevation the diffuse light behaves as if it had).
uniform float atmo_ms_strength = 0.0;        // 0 = old isotropic term only (atmo_multi_scatter)
uniform float atmo_ms_lift = 0.07;
uniform float atmo_ms_path = 0.55;           // optical depth scale of the diffuse sun paths
uniform vec3 atmo_ground_albedo = vec3(0.12, 0.13, 0.12);
// art direction: per-channel gain on the in-scattered light of a low sun (saturated sunsets,
// pink Belt of Venus) and an overall day-sky gain; 1 = physical
uniform vec3 atmo_twilight_tint = vec3(1.0);       // Rayleigh (sky colour)
uniform vec3 atmo_twilight_tint_mie = vec3(1.0);   // Mie (glow around the sun, haze)
uniform float atmo_sky_gain = 1.0;
// planet identities: ice-crystal halos (22 / 46 deg rings around the sun, strength relative to
// the Mie phase) and a self-lit haze (volcanic glow of the lower dust, radiance per unit Mie
// density per metre; visible mostly at night)
uniform float atmo_halo = 0.0;
uniform vec3 atmo_emission = vec3(0.0);
// night-side sky light for the ambient of terrain / clouds (starlight, airglow, planetshine):
// irradiance-like radiance added to atmo_sky_ambient() when the sun is below the horizon
uniform vec3 atmo_night_light = vec3(0.0);
group_uniforms;

float atmo_ozone_h() {
	return atmo_ozone_height > 0.0 ? atmo_ozone_height : atmo_rayleigh_height;
}

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
	float co = atmo_ozone_height > 0.0 ? min(atmo_chapman(r, mus, atmo_ozone_height), 1e9) : cr;
	// artistic: compressed planets have short grazing paths; lengthen them near the horizon so
	// sunsets get Earth-like reddening without making the daytime sky denser
	float k = 1.0 + (atmo_sun_path_scale - 1.0) * (1.0 - clamp(mus * atmo_sun_path_window, 0.0, 1.0));
	return (atmo_rayleigh * cr + atmo_ozone * co + (atmo_mie + atmo_mie_absorb) * cm) * k;
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
	float dz = atmo_ozone_height > 0.0 ? exp(-h / atmo_ozone_height) : dr;
	return dr * atmo_rayleigh + dz * atmo_ozone + dm * (atmo_mie + atmo_mie_absorb);
}

// Sun elevation raised by atmo_ms_lift (radians): direction the diffuse (multiply scattered)
// sky light behaves as coming from.
float atmo_ms_mus(float mus) {
	float c = cos(atmo_ms_lift);
	float s = sin(atmo_ms_lift);
	return max(mus, mus * c + sqrt(max(1.0 - mus * mus, 0.0)) * s);
}

// Soft planet shadow for the diffuse light (wider penumbra than the direct sun).
float atmo_planet_shadow_ms(float r, float mus) {
	if (mus >= 0.0) return 1.0;
	float d = r * sqrt(max(1.0 - mus * mus, 0.0));
	float w = atmo_rayleigh_height * (atmo_shadow_soft + 1.2);
	return smoothstep(atmo_planet_radius - w, atmo_planet_radius + w * 0.5, d);
}

// Isotropic multiple-scattering source (per unit sun irradiance and per unit scattering
// coefficient) for a sample at radius r with cos(sun zenith) mus. Colour: the scattering of the
// whole column (bluish by day), lit by diffuse sun paths; plus a little ground bounce.
vec3 atmo_ms_source(float r, float mus) {
	float m2 = atmo_ms_mus(mus);
	vec3 T = exp(-atmo_sun_optical_depth(r, m2) * atmo_ms_path) * atmo_planet_shadow_ms(r, m2);
	vec3 tau_col = atmo_rayleigh * atmo_rayleigh_height + atmo_mie * atmo_mie_height;
	vec3 sky = 1.0 - exp(-tau_col);
	return T * (sky * 2.0 + atmo_ground_albedo * max(m2, 0.0));
}

// Art-directed weight of a low sun at a sample (1 = sun on the horizon, 0 = high sun).
float atmo_low_sun(float mus) {
	return 1.0 - smoothstep(-0.02, 0.2, mus);
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
	vec3 ms_r = vec3(0.0);
	vec3 ms_m = vec3(0.0);
	vec3 em = vec3(0.0);
	bool ms = atmo_ms_strength > 0.0;
	bool emit = dot(atmo_emission, atmo_emission) > 0.0;
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
		float lo = atmo_low_sun(mus);
		vec3 gr = mix(vec3(1.0), atmo_twilight_tint, lo);
		vec3 tv = exp(-od_here) * gr;
		vec3 tr = exp(-(od_here + atmo_sun_optical_depth(r, mus))) * atmo_planet_shadow(r, mus);
#ifdef ATMO_CLOUD_SHADOWS
		// volumetric cloud shadows in the air (crepuscular rays, dim air under overcast); the
		// planet is not rotated, so world-oriented == planet-local here
		if (r < cloud_top) tr *= cloud_shadow_air(p, L);
#endif
		sum_r += tr * gr * (dr * ds);
		sum_m += tr * mix(vec3(1.0), atmo_twilight_tint_mie, lo) * (dm * ds);
		if (emit) em += exp(-od_here) * atmo_emission * (dm * ds);
		if (ms) {
			vec3 src = tv * atmo_ms_source(r, mus);
			ms_r += src * (dr * ds);
			ms_m += src * (dm * ds);
		}
	}
	T = exp(-od);
	float mu = dot(rd, L);
	vec3 E_sun = sun_color.rgb * sun_intensity * atmo_intensity * atmo_sky_gain;
	vec3 sr = sum_r * atmo_rayleigh;
	vec3 sm = sum_m * atmo_mie;
	vec3 ph_m = vec3(atmo_phase_mie(mu, atmo_mie_g));
	if (atmo_halo > 0.0) {
		// ice crystals: 22 deg halo (reddish sharp inner edge, bluish-white outer fade) + faint
		// 46 deg ring, relative to the Mie phase
		float ang = acos(clamp(mu, -1.0, 1.0)) * 57.29578;
		vec3 h22 = vec3(1.0, 0.85, 0.7) * exp(-pow((ang - 22.3) / 0.7, 2.0))
			+ vec3(0.75, 0.9, 1.0) * exp(-max(ang - 22.6, 0.0) / 3.5) * step(22.0, ang) * 0.35;
		vec3 h46 = vec3(0.9, 0.95, 1.0) * exp(-pow((ang - 46.0) / 1.2, 2.0)) * 0.3;
		ph_m += (h22 + h46) * atmo_halo * 0.08;
	}
	vec3 Lms = (ms_r * atmo_rayleigh + ms_m * atmo_mie) * (atmo_ms_strength * SD_INV_4PI);
	return E_sun * (sr * atmo_phase_rayleigh(mu) + sm * ph_m
		+ (sr + sm) * (atmo_multi_scatter * SD_INV_4PI) + Lms) + em;
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
	// wave 4: the low sample looks across the sun azimuth (90 deg off), not into the sunset glow:
	// representative of the whole sky dome (sunset ambient was the glow colour only)
	vec3 sh = sd_sun_dir() - up * dot(sd_sun_dir(), up);
	vec3 side = normalize(cross(up, sh + vec3(1e-4, 2e-4, 0.0)));
	vec3 hor = atmo_scatter(p, normalize(up * 0.3 + side + normalize(sh + vec3(1e-4)) * 0.35), 1e30, 4, 0.5, T);
	float night = 1.0 - smoothstep(-0.25, 0.0, dot(up, sd_sun_dir()));
	return (zen + hor) * 0.5 * SD_PI + atmo_night_light * night;
}

#endif
