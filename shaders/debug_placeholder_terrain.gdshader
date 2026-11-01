// PLACEHOLDER terrain for the atmosphere/ocean/cloud test scene only (the real terrain is made
// elsewhere). A polar grid centred under the camera is projected onto the sphere in the vertex
// shader; normals are evaluated per pixel from the analytic height gradient.
// Sunlight is attenuated per pixel by the atmosphere (atmo_sun_transmittance) and cloud shadows,
// the DirectionalLight3D therefore carries the UNATTENUATED star color.
shader_type spatial;
render_mode cull_back, diffuse_lambert, specular_disabled;

#include "res://shaders/include/atmosphere_common.gdshaderinc"
#include "res://shaders/include/clouds_common.gdshaderinc"
#include "res://shaders/include/debug_terrain_noise.gdshaderinc"

uniform float dt_radius = 60000.0;
uniform vec3 grid_up = vec3(0.0, 1.0, 0.0);
uniform vec3 grid_t1 = vec3(1.0, 0.0, 0.0);
uniform vec3 grid_t2 = vec3(0.0, 0.0, 1.0);
uniform bool use_atmosphere = true;
uniform float ambient_scale = 1.0;

varying vec3 v_n;
varying vec3 v_sun_tint;

void vertex() {
	float th = VERTEX.x;
	float ph = VERTEX.y;
	vec3 n = normalize(cos(th) * grid_up + sin(th) * (cos(ph) * grid_t1 + sin(ph) * grid_t2));
	vec4 h = dt_terrain(n * dt_radius, 3);
	VERTEX = n * (dt_radius + h.x);
	NORMAL = n;
	v_n = n;
}

void fragment() {
	vec3 n = normalize(v_n);
	vec3 P = n * dt_radius;
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist = length(VERTEX);
	// LOD: fewer detail octaves far away
	int det = dist < 3000.0 ? 5 : (dist < 15000.0 ? 4 : (dist < 60000.0 ? 2 : 1));
	vec4 t = dt_terrain(P, det);
	float h = t.x;
	vec3 g = t.yzw - dot(t.yzw, n) * n;
	vec3 nrm = normalize(n - g);
	float slope = 1.0 - dot(nrm, n);
	float lat = abs(dot(n, vec3(0.0, 1.0, 0.0)));
	vec4 var = dt_noised(P / 900.0 + vec3(3.1));
	vec4 var2 = dt_noised(P / 9000.0 + vec3(-7.3));

	vec3 col;
	if (dt_style == 1) {
		col = vec3(0.30, 0.29, 0.28) * (0.8 + 0.25 * var.x + 0.15 * var2.x);
		col = mix(col, vec3(0.42, 0.40, 0.37), smoothstep(0.1, 0.4, slope) * 0.5);
	} else {
		vec3 sand = vec3(0.62, 0.55, 0.40);
		vec3 grass = mix(vec3(0.13, 0.22, 0.06), vec3(0.24, 0.27, 0.10), 0.5 + 0.5 * var2.x);
		vec3 forest = vec3(0.05, 0.11, 0.035);
		vec3 dry = vec3(0.42, 0.34, 0.20);
		vec3 rock = mix(vec3(0.30, 0.27, 0.24), vec3(0.42, 0.38, 0.33), 0.5 + 0.5 * var.x);
		vec3 snow = vec3(0.85, 0.88, 0.92);
		vec3 seabed = vec3(0.45, 0.42, 0.33);
		float aridity = smoothstep(0.1, 0.5, var2.x * 0.6 + (0.35 - abs(lat - 0.3)) * 0.8);
		col = mix(grass, forest, smoothstep(-0.2, 0.4, var.x + var2.x * 0.5));
		col = mix(col, dry, aridity * 0.8);
		col = mix(col, rock, smoothstep(1400.0, 2600.0, h + var.x * 300.0));
		col = mix(col, rock, smoothstep(0.10, 0.25, slope));
		col = mix(sand, col, smoothstep(8.0, 40.0, h + var.x * 10.0));
		col = mix(seabed, col, step(0.0, h));
		float snowline = mix(3000.0, 300.0, smoothstep(0.55, 0.9, lat));
		float sn = smoothstep(snowline - 200.0, snowline + 200.0, h + var.x * 250.0) * (1.0 - smoothstep(0.25, 0.45, slope));
		sn = max(sn, smoothstep(0.88, 0.93, lat + var2.x * 0.04));
		col = mix(col, snow, sn);
	}
	ALBEDO = col;
	ROUGHNESS = 0.95;
	NORMAL = normalize((VIEW_MATRIX * vec4(nrm, 0.0)).xyz);

	vec3 p_rel = wpos - NODE_POSITION_WORLD;
	vec3 L = sd_sun_dir();
	if (use_atmosphere) {
		v_sun_tint = atmo_sun_transmittance(p_rel, L);
		vec3 amb = atmo_sky_ambient(p_rel) * (0.6 + 0.4 * dot(nrm, n));
		EMISSION = col * amb * ambient_scale;
	} else {
		v_sun_tint = vec3(1.0);
		EMISSION = col * vec3(0.004, 0.005, 0.007);
	}
	v_sun_tint *= cloud_shadow_m(mat3(MODEL_MATRIX), p_rel, L);
}

void light() {
	float ndl = max(dot(NORMAL, LIGHT), 0.0);
	DIFFUSE_LIGHT += ndl * ATTENUATION * LIGHT_COLOR / PI * v_sun_tint;
}
