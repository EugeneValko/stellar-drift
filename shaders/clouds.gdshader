// Volumetric cloud shell (raymarched between cloud_bottom and cloud_top radii). Drawn on back
// faces of a proxy sphere with depth test off -> works from space, inside and below the layer;
// stops at the opaque scene depth and the ocean sphere. Lighting: short light march toward the
// sun + multi-octave scattering approximation (silver lining / forward scattering), powder
// darkening, sky ambient, atmospheric sun colour (sunsets) and aerial perspective in front of
// the cloud. Output is premultiplied (alpha = 1 - transmittance).
shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_premul_alpha, fog_disabled;

#include "res://shaders/include/atmosphere_common.gdshaderinc"
#include "res://shaders/include/clouds_common.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;

group_uniforms cloud_render;
uniform int cloud_steps = 40;
uniform int cloud_light_steps = 4;
uniform float cloud_light_step = 120.0;      // first light step (m), doubles each step
uniform float cloud_max_distance = 70000.0;
uniform float cloud_brightness = 1.0;
uniform vec3 cloud_albedo : source_color = vec3(1.0);
uniform float cloud_ambient = 1.0;
uniform float cloud_ocean_radius = 0.0;       // >0: rays stop at the ocean sphere
uniform float cloud_detail_distance = 25000.0; // beyond: no detail erosion
// performance (docs/reports/perf_gpu.md)
uniform bool cloud_quad_share = true;          // 2x2 pixel quads split the march (see fragment)
uniform float cloud_bicubic_distance = 30000.0; // beyond: 1-tap bilinear weather
uniform float cloud_light_far = 30000.0;       // beyond: one light step fewer, first step doubled
uniform int cloud_ap_steps = 6;
uniform int cloud_debug = 0;
uniform bool cloud_temporal_jitter = false;   // enable with TAA/FSR to resolve noise over frames
uniform float cirrus_opacity = 0.4;           // 0 = no cirrus sheet
uniform float cirrus_altitude = 3500.0;       // above cloud_top, m
uniform float cirrus_scale = 1.0;
group_uniforms;

void fragment() {
	vec3 rd = normalize((INV_VIEW_MATRIX * vec4(normalize(VERTEX), 0.0)).xyz);
	float S = sd_node_scale(MODEL_MATRIX);   // scaled-space proxy: work in body units
	vec3 ro = (CAMERA_POSITION_WORLD - NODE_POSITION_WORLD) / S;
	float r0 = length(ro);
	vec2 top = sd_ray_sphere(ro, rd, cloud_top);
	bool has_cu = !(top.y < top.x || top.y <= 0.0);
	vec2 bot = sd_ray_sphere(ro, rd, cloud_bottom);
	bool bot_hit = bot.y >= bot.x;
	float t0;
	float t1;
	if (r0 > cloud_top) {
		t0 = top.x;
		t1 = (bot_hit && bot.x > 0.0) ? bot.x : top.y;
	} else if (r0 >= cloud_bottom) {
		t0 = 0.0;
		t1 = (bot_hit && bot.x > 0.0) ? bot.x : top.y;
	} else {
		t0 = max(bot.y, 0.0);
		t1 = top.y;
	}
	float sd = sd_scene_distance(texture(depth_tex, SCREEN_UV).r, SCREEN_UV, INV_PROJECTION_MATRIX) / S;
	t1 = min(t1, sd);
	if (cloud_ocean_radius > 0.0) {
		vec2 o = sd_ray_sphere(ro, rd, cloud_ocean_radius);
		if (o.y >= o.x && o.x > 0.0) t1 = min(t1, o.x);
	}
	t1 = min(t1, t0 + cloud_max_distance);
	if (t1 <= t0) has_cu = false;

	mat3 to_local = transpose(mat3(MODEL_MATRIX)) / S;
	vec3 ro_l = to_local * ro;
	vec3 rd_l = to_local * rd;
	vec3 L = sd_sun_dir();
	vec3 L_l = to_local * L;
	float mu = dot(rd, L);

	// per-pixel lighting terms (sun colour at entry/exit, sky ambient)
	vec3 pa = ro + rd * t0;
	vec3 pb = ro + rd * t1;
	vec3 sun_a = vec3(0.0);
	vec3 sun_b = vec3(0.0);
	vec3 sky_amb = vec3(0.0);
	if (has_cu) {
		sun_a = atmo_sun_transmittance(pa, L);
		sun_b = atmo_sun_transmittance(pb, L);
	}
	vec3 Esun = sun_color.rgb * sun_intensity * atmo_intensity * cloud_brightness;
	vec3 pm = ro + rd * mix(t0, t1, 0.3);
	if (has_cu) sky_amb = atmo_sky_ambient(pm) / SD_PI;
	float upl = max(dot(normalize(pm), L), 0.0);
	vec3 ground_amb = vec3(0.12, 0.13, 0.12) * sun_color.rgb * sun_intensity * upl * 0.5;

	// phase (dual-lobe HG, multi-octave)
	float ph0 = mix(sd_hg(mu, 0.8), sd_hg(mu, -0.25), 0.25);
	float ph1 = mix(sd_hg(mu, 0.4), sd_hg(mu, -0.12), 0.3);
	float ph2 = SD_INV_4PI;

	float len = t1 - t0;
	float k = len > 6000.0 ? 1.8 : 1.0;
	// white-noise jitter (grain instead of structured banding); temporal variant for TAA
	// Quad sharing: the 4 pixels of a 2x2 quad march half as many (twice as long) cells, each in
	// its own quarter of the cell (random position inside it), and blend in their neighbours'
	// results after the loop: ~half the march cost per pixel, slightly softer cloud image.
	float px = mod(floor(FRAGCOORD.x), 2.0);
	float py = mod(floor(FRAGCOORD.y), 2.0);
	// R2 low-discrepancy jitter (wave 4): evenly spread offsets read as fine, even grain instead
	// of white-noise clumps
	float jit = sd_ign(FRAGCOORD.xy * vec2(0.5, 0.5) + vec2(px * 37.0, py * 61.0));
	if (cloud_temporal_jitter) jit = fract(jit + TIME * 7.3123);
	// quarter per pixel, rotated randomly per quad: a fixed assignment shows up as a regular
	// row/column pattern (the quarters are biased differently inside the doubled cells)
	float qrot = floor(fract(sin(dot(floor(FRAGCOORD.xy * 0.5), vec2(39.346, 11.135))) * 43758.5453) * 4.0);
	if (cloud_quad_share) jit = (jit + mod(px + 2.0 * py + qrot, 4.0)) * 0.25;
	vec3 col = vec3(0.0);
	float T = 1.0;
	float t_acc = 0.0;
	float w_acc = 0.0;
	int n = (cloud_debug == 1 || !has_cu) ? 0 : clamp(int(len / 80.0), 12, cloud_steps);
	if (cloud_quad_share) n = (n + 1) / 2;
	for (int i = 0; i < n; i++) {
		float u0 = float(i) / float(n);
		float u1 = float(i + 1) / float(n);
		float a = t0 + len * pow(u0, k);
		float b = t0 + len * pow(u1, k);
		float ds = b - a;
		float t = a + ds * jit;
		vec3 pl = ro_l + rd_l * t;
		float r = length(pl);
		vec2 wuv = cloud_weather_uv(pl / r);
		vec2 w = t < cloud_bicubic_distance ? cloud_weather_bicubic_uv(wuv) : cloud_weather_fast_uv(wuv);
		if (w.x <= 0.01) continue;
		int lod = t < cloud_detail_distance ? 0 : 1;
		float d = cloud_density_at(pl, r, w, lod);
		if (d <= 0.001) continue;
		float sig = d * cloud_density;
		// light march toward the sun (far samples: one step fewer, first step doubled)
		bool far_l = t > cloud_light_far;
		int ls = far_l ? max(cloud_light_steps - 1, 1) : cloud_light_steps;
		float od = 0.0;
		float dl = far_l ? cloud_light_step * 2.0 : cloud_light_step;
		vec3 q = pl;
		for (int j = 0; j < ls; j++) {
			q += L_l * dl;
			float rq = length(q);
			od += cloud_density_at(q, rq, cloud_weather_fast(q / rq), 1) * dl;
			dl *= 2.0;
		}
		od *= cloud_density;
		float f = (t - t0) / max(len, 1.0);
		vec3 sunc = mix(sun_a, sun_b, f);
		float powder = 1.0 - 0.6 * exp(-sig * 250.0);
		vec3 S_sun = Esun * sunc * powder * (ph0 * exp(-od) + 0.5 * ph1 * exp(-od * 0.3) + 0.25 * ph2 * exp(-od * 0.1));
		float hh = clamp((r - cloud_bottom) / (cloud_top - cloud_bottom), 0.0, 1.0);
		vec3 S_amb = (sky_amb * mix(0.45, 1.0, hh) + ground_amb * (1.0 - hh)) * cloud_ambient;
		vec3 S = (S_sun + S_amb) * cloud_albedo;
		float tr = exp(-sig * ds);
		col += T * S * (1.0 - tr);
		t_acc += T * (1.0 - tr) * t;
		w_acc += T * (1.0 - tr);
		T *= tr;
		if (T < 0.01) break;
	}
	// quad sharing (uniform control flow here: fine derivatives give the neighbours' values):
	// own result 1/2 + horizontal and vertical neighbour 1/4 each (no 2x2 blocks, each pixel keeps
	// its own detail). Not across depth edges (terrain silhouettes in front of / inside the
	// clouds): there the pixel keeps its own result in that direction.
	if (cloud_quad_share) {
		float okx = (abs(dFdxFine(t0)) < max(0.02 * t0, 60.0) && abs(dFdxFine(t1)) < max(0.02 * t1, 60.0)) ? 1.0 : 0.0;
		float oky = (abs(dFdyFine(t0)) < max(0.02 * t0, 60.0) && abs(dFdyFine(t1)) < max(0.02 * t1, 60.0)) ? 1.0 : 0.0;
		vec4 a0 = vec4(col, T);
		vec2 b0 = vec2(t_acc, w_acc);
		float hx = (px < 0.5 ? 0.25 : -0.25) * okx;
		float hy = (py < 0.5 ? 0.25 : -0.25) * oky;
		vec4 a1 = a0 + dFdxFine(a0) * hx + dFdyFine(a0) * hy;
		vec2 b1 = b0 + dFdxFine(b0) * hx + dFdyFine(b0) * hy;
		col = a1.rgb;
		T = a1.a;
		t_acc = b1.x;
		w_acc = b1.y;
	}
	float alpha = 1.0 - T;
	if (cloud_debug == 1) { vec2 wd = cloud_weather(normalize(to_local * pa)); col = vec3(wd.x, wd.y, 0.0); T = 0.0; alpha = 1.0; }
	if (alpha > 0.002) {
		// aerial perspective between camera and the cloud
		float tm = t_acc / max(w_acc, 1e-5);
		vec3 Tap;
		vec3 Lap = atmo_scatter(ro, rd, tm, cloud_ap_steps, jit, Tap);
		col = col * Tap + Lap * alpha;
	}

	// ---- thin high cirrus sheet (2D, one sample): wispy streaks seen from orbit and the ground
	if (cirrus_opacity > 0.0) {
		float rc = cloud_top + cirrus_altitude;
		vec2 hc = sd_ray_sphere(ro, rd, rc);
		bool above = r0 > rc;
		float tc = above ? hc.x : hc.y;
		bool hit_c = hc.y >= hc.x && tc > 0.0 && tc < sd;
		if (hit_c && cloud_ocean_radius > 0.0) {
			vec2 o = sd_ray_sphere(ro, rd, cloud_ocean_radius);
			if (o.y >= o.x && o.x > 0.0 && o.x < tc) hit_c = false;
		}
		if (hit_c) {
			vec3 pcw = ro + rd * tc;
			vec3 dcw = normalize(pcw);
			vec3 dc = normalize(to_local * pcw);
			vec3 drift = vec3(TIME * 0.00004, 0.0, TIME * 0.00002);
			// streaks stretched east-west (compressed latitude frequency), patchy mask
			vec3 sq = dc * cirrus_scale + drift;
			float s1 = cl_tex(vec3(sq.x * 5.0, sq.y * 22.0, sq.z * 5.0));
			float s2 = cl_tex(vec3(sq.x * 13.0, sq.y * 55.0, sq.z * 13.0) + vec3(0.3));
			float s3 = texture(cloud_detail_tex, dc * cirrus_scale * 40.0).r;
			float mask = smoothstep(0.5, 0.72, cl_tex(sq * 1.7 + vec3(0.4)));
			float dens = smoothstep(0.55, 0.9, s1 * 0.65 + s2 * 0.35 + s3 * 0.15) * mask;
			float cosv = max(abs(dot(rd, dcw)), 0.3);
			float ca = (1.0 - exp(-dens * 0.25 / cosv)) * cirrus_opacity;
			if (ca > 0.001) {
				vec3 sc = atmo_sun_transmittance(pcw, L);
				vec3 Tc = atmo_transmittance(ro, rd, tc, 4, 0.5);
				float phc = sd_hg(mu, 0.6) * 0.7 + SD_INV_4PI * 0.3;
				// sky ambient: reuse the cumulus value (same column, a few km lower) when we have it
				vec3 amb_c = has_cu ? sky_amb : atmo_sky_ambient(pcw) / SD_PI;
				vec3 cc = (Esun * sc * phc * 2.0 + amb_c * 0.6) * Tc;
				if (above) {
					col = cc * ca + col * (1.0 - ca);    // cirrus in front of the cumulus
					alpha = ca + alpha * (1.0 - ca);
				} else {
					col = col + cc * ca * (1.0 - alpha); // cumulus in front of the cirrus
					alpha = alpha + ca * (1.0 - alpha);
				}
			}
		}
	}
	if (alpha < 0.002) discard;
	ALBEDO = col;
	ALPHA = alpha;
}
