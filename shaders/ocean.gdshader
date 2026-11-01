// Planet ocean: analytic ray/sphere surface at sea level (perfect curvature at any distance, no
// mesh LOD needed), drawn on back faces of a proxy sphere with depth test off and occluded by the
// opaque scene via the depth texture. Wave normals = sum of planet-local 3D lattice plane waves
// (tile seamlessly, camera-anchored for float precision) with footprint filtering that turns
// unresolved waves into roughness (correct glint size from orbit). Fresnel sky reflection uses
// the atmosphere model; sunlight is reddened by atmospheric transmittance; water colour depends
// on optical depth through the water (depth texture) with shoreline foam.
shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_mix, fog_disabled;

#include "res://shaders/include/atmosphere_common.gdshaderinc"
#include "res://shaders/include/clouds_common.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;

group_uniforms ocean;
uniform float ocean_radius = 60000.0;
uniform vec3 ocean_scatter_color : source_color = vec3(0.015, 0.06, 0.09);  // deep water body albedo
uniform vec3 ocean_shallow_tint : source_color = vec3(0.10, 0.55, 0.50);   // in-scatter in shallows
uniform vec3 ocean_absorption = vec3(0.35, 0.065, 0.045);                  // 1/m (red absorbed first)
uniform float ocean_turbidity = 0.08;           // extra scattering in shallows (1/m)
uniform float ocean_wave_length = 90.0;         // longest wave, m
uniform float ocean_wave_min = 0.3;             // shortest wave, m
uniform float ocean_steepness = 0.75;           // overall slope scale
uniform float ocean_base_roughness = 0.035;
uniform float ocean_time_scale = 1.0;
uniform int ocean_waves = 24;
uniform int ocean_sky_steps = 6;
uniform float ocean_foam_depth = 2.0;           // m of water depth where shore foam appears
uniform float ocean_foam_amount = 1.0;
uniform float ocean_refraction = 0.04;
uniform float ocean_sun_spec = 1.0;
uniform float ocean_tile = 4096.0;              // lattice period (m) of the wave field
uniform int ocean_debug = 0;
group_uniforms;

float o_hash(float n) { return fract(sin(n * 91.3458) * 47453.5453); }

// Returns tangential slope vector (planet-local) and accumulated unresolved slope variance.
vec3 ocean_slope(vec3 q, vec3 n, float footprint, out float var) {
	vec3 g = vec3(0.0);
	var = 0.0;
	float t = TIME * ocean_time_scale;
	float nw = float(ocean_waves);
	// three planet-fixed wind groups so that every point of the sphere has tangent-ish swell
	vec3 winds[3] = vec3[3](vec3(1.0, 0.15, 0.0), vec3(0.1, 0.2, 1.0), vec3(0.7, -0.6, -0.4));
	for (int i = 0; i < ocean_waves; i++) {
		float fi = float(i);
		float lam = ocean_wave_length * pow(ocean_wave_min / ocean_wave_length, fi / max(nw - 1.0, 1.0));
		vec3 rnd = vec3(o_hash(fi + 0.1), o_hash(fi + 3.7), o_hash(fi + 7.3)) * 2.0 - 1.0;
		vec3 d = normalize(normalize(winds[i % 3]) + rnd * 1.1);
		// integer lattice -> field tiles with period ocean_tile
		vec3 kq = floor(d * (ocean_tile / lam) + 0.5);
		vec3 k = kq * (6.2831853 / ocean_tile);
		float kl = length(k);
		vec3 kt = k - n * dot(k, n);          // tangential wavevector
		float s = ocean_steepness * mix(0.6, 1.0, o_hash(fi + 11.1)) * mix(0.3, 1.0, fi / max(nw - 1.0, 1.0)) / sqrt(nw);
		float omega = sqrt(9.81 * kl);
		float ph = dot(k, q) + omega * t + o_hash(fi + 5.5) * 6.2831853;
		float lam_t = 6.2831853 / max(length(kt), 1e-5);
		float res = clamp((lam_t / max(footprint, 1e-4) - 2.0) / 4.0, 0.0, 1.0);
		g += (kt / max(kl, 1e-6)) * s * cos(ph) * res;
		var += 0.5 * s * s * (1.0 - res * res) * dot(kt, kt) / max(kl * kl, 1e-9);
	}
	// irregular chop from tileable 3D noise (periods divide ocean_tile -> seamless anchoring)
	for (int o = 0; o < 2; o++) {
		float sc = o == 0 ? 32.0 : 8.0;
		float res = clamp((sc / max(footprint, 1e-4) - 2.0) / 4.0, 0.0, 1.0);
		float amp = ocean_steepness * 0.22;
		if (res > 0.0) {
			vec3 c = q / sc + vec3(t * 0.03, 0.0, t * 0.02) * (o == 0 ? 1.0 : 2.0);
			float e = 0.08;
			float n0 = texture(cloud_shape_tex, c).r;
			vec3 gd = vec3(texture(cloud_shape_tex, c + vec3(e, 0.0, 0.0)).r - n0,
				texture(cloud_shape_tex, c + vec3(0.0, e, 0.0)).r - n0,
				texture(cloud_shape_tex, c + vec3(0.0, 0.0, e)).r - n0) / e;
			gd -= n * dot(gd, n);
			g += gd * amp * res;
		}
		var += 0.5 * amp * amp * (1.0 - res * res);
	}
	return g;
}

float ggx_d(float nh, float a2) {
	float d = nh * nh * (a2 - 1.0) + 1.0;
	return a2 / (SD_PI * d * d);
}

void fragment() {
	vec3 rd = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	vec3 ro = CAMERA_POSITION_WORLD - NODE_POSITION_WORLD;
	if (length(ro) < ocean_radius) discard;    // underwater: not handled here
	vec2 hit = sd_ray_sphere(ro, rd, ocean_radius);
	if (hit.y < hit.x || hit.x <= 0.0) discard;
	float t = hit.x;
	float sd = sd_scene_distance(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX);
	if (sd < t) discard;                        // land in front of the water

	mat3 to_local = transpose(mat3(MODEL_MATRIX));
	vec3 p = ro + rd * t;                       // world-oriented, planet relative
	vec3 N = normalize(p);
	vec3 L = sun_direction;

	// ---- waves (planet-local, camera-anchored lattice for precision)
	vec3 ro_l = to_local * ro;
	vec3 rd_l = to_local * rd;
	vec3 anchor = floor(ro_l / ocean_tile + 0.5) * ocean_tile;
	vec3 q = (ro_l - anchor) + rd_l * t;
	vec3 N_l = to_local * N;
	float pix = 2.0 / (abs(PROJECTION_MATRIX[1][1]) * VIEWPORT_SIZE.y);
	float cosv = max(abs(dot(rd, N)), 0.08);
	float footprint = t * pix / cosv;
	float var;
	vec3 slope_l = ocean_slope(q, N_l, footprint, var);
	vec3 n = normalize(N - mat3(MODEL_MATRIX) * slope_l);
	float a2 = ocean_base_roughness * ocean_base_roughness + 2.0 * var;
	a2 = clamp(a2, 1e-4, 0.5);

	vec3 V = -rd;
	float nv = max(dot(n, V), 1e-3);
	float fres = 0.02 + 0.98 * pow(1.0 - nv, 5.0);
	// widen fresnel toward grazing with roughness (hides the hard horizon line)
	fres = mix(fres, 0.02 + 0.98 * pow(1.0 - max(dot(N, V), 0.0), 5.0), 0.3);

	// ---- light
	vec3 sun_t = atmo_sun_transmittance(p, L);
	float csh = cloud_shadow_local(to_local * p, to_local * L);
	vec3 Esun = sun_color.rgb * sun_intensity * SD_PI * sun_t * csh;   // physical irradiance

	// sky reflection
	vec3 R = reflect(rd, n);
	float rn = dot(R, N);
	if (rn < 0.02) R = normalize(R + N * (0.02 - rn));
	vec3 Tsky;
	vec3 sky = atmo_scatter(p + N * 2.0, R, 1e30, ocean_sky_steps, 0.5, Tsky);
	vec3 amb = atmo_scatter(p + N * 2.0, N, 1e30, 3, 0.5, Tsky) * SD_PI;

	// sun specular (GGX, sun as directional)
	vec3 H = normalize(L + V);
	float nh = max(dot(n, H), 0.0);
	float nl = max(dot(n, L), 0.0);
	float vh = max(dot(V, H), 0.0);
	float fs = 0.02 + 0.98 * pow(1.0 - vh, 5.0);
	float k = sqrt(a2) * 0.5;
	float vis = 1.0 / ((nl * (1.0 - k) + k) * (nv * (1.0 - k) + k));
	vec3 spec = Esun * (ggx_d(nh, a2) * fs * vis * 0.25 * nl) * ocean_sun_spec;
	spec *= smoothstep(-0.02, 0.05, dot(N, L));

	// ---- water body (up-welling light)
	float nlN = max(dot(N, L), 0.0);
	vec3 body = ocean_scatter_color * (Esun * (0.25 + 0.75 * nlN) / SD_PI + amb / SD_PI);

	// ---- shallows: see the bottom through the water
	float d_water = max(sd - t, 0.0);
	float vdepth = d_water * abs(dot(rd, N));
	vec3 under = body;
	if (sd < 1e29) {
		vec2 off = (VIEW_MATRIX * vec4(n - N, 0.0)).xy * ocean_refraction * clamp(vdepth / 4.0, 0.0, 1.0);
		vec3 bg = texture(screen_tex, SCREEN_UV + off).rgb;
		vec3 tw = exp(-(ocean_absorption + ocean_turbidity) * (d_water + vdepth));
		vec3 shallow = ocean_shallow_tint * (Esun * nlN / SD_PI + amb / SD_PI) * 0.08;
		vec3 inscat = mix(body, shallow, exp(-vdepth * 0.15));
		under = bg * tw + inscat * (1.0 - tw);
	}

	vec3 col = mix(under, sky, fres) + spec;

	// ---- shore foam
	if (ocean_foam_amount > 0.0 && sd < 1e29) {
		float fz = 1.0 - smoothstep(0.0, ocean_foam_depth, vdepth);
		float ft = TIME * ocean_time_scale;
		float c1 = texture(cloud_detail_tex, q / 8.0 + vec3(0.0, ft * 0.01, 0.0)).r;
		float c2 = texture(cloud_detail_tex, q / 4.0 - vec3(ft * 0.013, 0.0, 0.0)).r;
		float pattern = smoothstep(0.55, 0.85, c1 * 0.6 + c2 * 0.5 + fz * 0.45 - 0.05);
		float fade = clamp(1.0 - footprint / 12.0, 0.0, 1.0);
		float foam = fz * mix(0.5 * fz, pattern, fade) * ocean_foam_amount;
		vec3 foam_col = vec3(0.85) * (Esun * nlN / SD_PI + amb / SD_PI);
		col = mix(col, foam_col, clamp(foam, 0.0, 1.0));
	}
	ALBEDO = col;
	if (ocean_debug == 1) ALBEDO = spec;
	if (ocean_debug == 2) ALBEDO = sky * fres;
	if (ocean_debug == 3) ALBEDO = under;
	if (ocean_debug == 4) ALBEDO = vec3(sqrt(a2), d_water / 3000.0, 0.0);
	ALPHA = 1.0;
}
