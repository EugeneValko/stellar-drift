// Star photosphere: animated convection granulation (3D Voronoi), supergranulation mottling,
// sunspots with umbra/penumbra, faculae near the limb, per-channel limb darkening.
// HDR unshaded output so the disc blooms. Detail octaves fade out by pixel footprint (no
// shimmering from far away). Driven by src/space/star.gd.
shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled, fog_disabled;

#include "res://shaders/space_noise.gdshaderinc"

uniform vec3 star_color = vec3(1.0, 0.93, 0.84);   // linear, from temperature
uniform float intensity : hint_range(0.0, 100.0) = 7.0;
uniform float time_scale = 1.0;
uniform int seed = 1;
uniform float granule_scale = 110.0;          // granules per radius (approx.)
uniform float meso_scale = 34.0;              // mesogranulation (visible from ~2000 km)
uniform float color_saturation : hint_range(0.5, 10.0) = 6.0; // pushes the disc toward yellow-orange
uniform float granule_contrast : hint_range(0.0, 2.0) = 0.7;
uniform float supergranule_scale = 18.0;
uniform float mottling : hint_range(0.0, 1.0) = 0.35;
uniform float spot_amount : hint_range(0.0, 1.0) = 0.55;
uniform float spot_scale = 2.4;
uniform float rotation_speed = 0.004;       // rad/s
uniform vec3 limb_darkening = vec3(0.60, 0.74, 0.88);  // per-channel linear coefficient (r,g,b)
uniform float limb_darkening2 = 0.18;

varying vec3 v_dir;

// Voronoi returning (F1, F2, hash of the nearest cell) - per-granule brightness variation.
vec3 cells(vec3 p, float t) {
	vec3 i = floor(p);
	vec3 f = p - i;
	float f1 = 8.0;
	float f2 = 8.0;
	float id = 0.0;
	ivec3 ii = ivec3(i);
	for (int z = -1; z <= 1; z++)
	for (int y = -1; y <= 1; y++)
	for (int x = -1; x <= 1; x++) {
		ivec3 c = ivec3(x, y, z);
		vec3 h = sn_hash3i(ii + c);
		vec3 o = 0.5 + 0.4 * sin(t * (0.5 + h.yzx) + 6.2831 * h);
		vec3 r = vec3(c) + o - f;
		float d = dot(r, r);
		if (d < f1) { f2 = f1; f1 = d; id = h.z; } else if (d < f2) { f2 = d; }
	}
	return vec3(sqrt(f1), sqrt(f2), id);
}

void vertex() {
	v_dir = normalize(VERTEX);
}

vec3 rot_y(vec3 p, float a) {
	float c = cos(a), s = sin(a);
	return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

void fragment() {
	float t = TIME * time_scale;
	vec3 n0 = normalize(v_dir);
	vec3 n = rot_y(n0, t * rotation_speed);
	vec3 so = (sn_hash3i(ivec3(seed, 77, 5)) - 0.5) * 300.0;
	// surface footprint of one pixel in units of the radius
	float fw = max(length(fwidth(n0)), 1e-6);

	// --- granulation: bright convection cells, dark inter-granular lanes
	float g_fade = 1.0 - smoothstep(0.25, 0.6, fw * granule_scale);
	float gran = 0.0;
	if (g_fade > 0.0) {
		vec3 gp = n * granule_scale + so;
		// wave 4: domain-warped cells -> organic, irregular granules (not a Voronoi mosaic)
		vec3 gw = gp * 0.42 + vec3(0.0, t * 0.03, 0.0);
		gp += vec3(sn_gnoise(gw), sn_gnoise(gw + 17.3), sn_gnoise(gw + 41.7)) * 0.55;
		vec3 v = cells(gp, t * 0.35);
		float lw = 0.18 + 0.22 * fract(v.z * 13.7);           // narrow lanes, width varies per granule
		float lane = smoothstep(0.0, lw, v.y - v.x);
		float cellb = 1.0 - smoothstep(0.0, 0.9, v.x);
		cellb *= cellb;                                        // soft, domed granule tops
		// some large "exploding" granules with a darker centre
		float expl = smoothstep(0.82, 0.95, v.z) * (1.0 - smoothstep(0.0, 0.35, v.x)) * 0.4;
		gran = (lane * 0.45 + cellb * 0.55 - expl) * (0.7 + 0.6 * v.z) - 0.55;
		// organic modulation (no visible mosaic)
		gran *= 0.75 + 0.5 * (sn_gnoise(gp * 0.27 + 9.1) * 0.5 + 0.5);
		// fine sub-granular texture
		float fine_fade = 1.0 - smoothstep(0.25, 0.6, fw * granule_scale * 3.0);
		gran += 0.18 * fine_fade * sn_gnoise(gp * 3.0 + vec3(0.0, t * 0.2, 0.0));
		gran *= g_fade;
	}

	// --- mesogranulation: larger convection cells that read from ~2000 km
	float m_fade = 1.0 - smoothstep(0.3, 0.7, fw * meso_scale);
	vec3 mv = cells(n * meso_scale + so * 0.7, t * 0.12);
	// wave 4: meso cells only modulate brightness softly (their lanes read as a net)
	float meso = ((1.0 - smoothstep(0.0, 1.2, mv.x)) * (0.5 + mv.z) * 0.8 - 0.42) * m_fade * 0.55;

	// --- supergranulation / mottling (always resolvable)
	vec3 sp = n * supergranule_scale + so * 0.5;
	vec2 sv = sn_voronoi(sp, t * 0.04);
	float sg = smoothstep(0.0, 0.25, sv.y - sv.x);   // network lanes slightly brighter (chromospheric network)
	float mott = sn_fbm(n * 7.0 + so + vec3(t * 0.01), 5, 0.55);
	float bright = 1.0 + granule_contrast * gran + 0.6 * meso + mottling * (0.45 * mott - 0.12 * sg);

	// --- sunspots in active latitude belts
	float lat = abs(n.y);
	float belt = smoothstep(0.08, 0.2, lat) * (1.0 - smoothstep(0.45, 0.62, lat));
	float sn1 = sn_fbm(n * spot_scale + so * 1.3, 4, 0.5);
	float sn2 = sn_fbm(n * spot_scale * 4.0 + so, 4, 0.5);
	float act = belt * spot_amount;
	float spot_f = (sn1 * 0.8 + sn2 * 0.35) - (0.44 - 0.30 * act);
	// wave 4: soft, wide penumbra and a gradual umbra edge
	float pen = smoothstep(-0.045, 0.03, spot_f) * step(0.001, act);
	float umb = smoothstep(0.065, 0.13, spot_f) * step(0.001, act);
	float fil = 0.5;
	if (pen > 0.001) {
		// filaments run radially out of the spot: streak noise aligned with the gradient of the
		// spot field (finite differences on the sphere)
		vec3 e1 = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
		vec3 e2 = cross(n, e1);
		float h = 0.004;
		vec3 n1 = normalize(n + e1 * h);
		vec3 n2 = normalize(n + e2 * h);
		float f1 = sn_fbm(n1 * spot_scale + so * 1.3, 4, 0.5) * 0.8 + sn_fbm(n1 * spot_scale * 4.0 + so, 4, 0.5) * 0.35;
		float f2 = sn_fbm(n2 * spot_scale + so * 1.3, 4, 0.5) * 0.8 + sn_fbm(n2 * spot_scale * 4.0 + so, 4, 0.5) * 0.35;
		vec2 g = vec2(f1 - (sn1 * 0.8 + sn2 * 0.35), f2 - (sn1 * 0.8 + sn2 * 0.35));
		// direction to the spot centre (gradient) as an angle on a smooth frame -> radial streaks
		vec2 gd = g / max(length(g), 1e-6);
		fil = sn_gnoise(vec3(gd * 9.0, spot_f * 14.0 + float(seed))) * 0.5 + 0.5;
		fil = fil * 0.6 + (sn_gnoise(vec3(gd * 23.0, spot_f * 30.0 + 3.0)) * 0.5 + 0.5) * 0.4;
		fil = mix(fil, sn_gnoise(n * spot_scale * 90.0 + so) * 0.5 + 0.5, 0.25);
	}
	float spot_mul = mix(1.0, mix(0.5, 0.85, fil), pen);
	spot_mul = mix(spot_mul, 0.1, umb);
	// faculae: bright plage around active regions, much more visible toward the limb
	float plage = smoothstep(-0.12, -0.02, spot_f) * (1.0 - pen) * act;

	// --- limb darkening (view space)
	float mu = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float om = 1.0 - mu;
	vec3 ld = 1.0 - limb_darkening * om - limb_darkening2 * om * om;
	ld = max(ld, vec3(0.02));
	float fac = plage * smoothstep(0.3, 0.95, om) * 0.6;

	vec3 base_col = pow(star_color, vec3(color_saturation));
	vec3 col = base_col * intensity * bright * spot_mul * ld;
	col *= 1.0 + fac;
	// cooler lanes / spots are slightly redder, hot granule tops whiter
	col *= mix(vec3(1.0, 0.82, 0.62), vec3(1.0), clamp(bright * spot_mul, 0.0, 1.0));
	ALBEDO = col;
}
