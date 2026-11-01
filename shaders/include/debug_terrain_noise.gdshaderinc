// Placeholder terrain height (value-noise fbm with analytic derivatives) used ONLY by the
// test scenes of the atmosphere stage. Mirrored in GDScript by scenes/test/placeholder_body.gd
// (height only) so cameras can be placed above the ground. Real terrain lives elsewhere.
#ifndef DEBUG_TERRAIN_NOISE_INC
#define DEBUG_TERRAIN_NOISE_INC

uint dt_hash(ivec3 iv) {
	uvec3 v = uvec3(iv) * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v.x ^ v.y ^ v.z;
}

float dt_h(ivec3 i) {
	return float(dt_hash(i) & 16777215u) / 16777215.0;
}

// value + gradient, value in [-1, 1]
vec4 dt_noised(vec3 x) {
	vec3 fi = floor(x);
	vec3 f = x - fi;
	ivec3 i = ivec3(fi);
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float a = dt_h(i);
	float b = dt_h(i + ivec3(1, 0, 0));
	float c = dt_h(i + ivec3(0, 1, 0));
	float d = dt_h(i + ivec3(1, 1, 0));
	float e = dt_h(i + ivec3(0, 0, 1));
	float ff = dt_h(i + ivec3(1, 0, 1));
	float g = dt_h(i + ivec3(0, 1, 1));
	float h = dt_h(i + ivec3(1, 1, 1));
	float k0 = a, k1 = b - a, k2 = c - a, k3 = e - a, k4 = a - b - c + d;
	float k5 = a - c - e + g, k6 = a - b - e + ff, k7 = -a + b + c - d + e - ff - g + h;
	float v = k0 + k1 * u.x + k2 * u.y + k3 * u.z + k4 * u.x * u.y + k5 * u.y * u.z + k6 * u.z * u.x + k7 * u.x * u.y * u.z;
	vec3 dv = du * vec3(
		k1 + k4 * u.y + k6 * u.z + k7 * u.y * u.z,
		k2 + k5 * u.z + k4 * u.x + k7 * u.z * u.x,
		k3 + k6 * u.x + k5 * u.y + k7 * u.x * u.y);
	return vec4(v * 2.0 - 1.0, dv * 2.0);
}

// fbm with derivative w.r.t. x
vec4 dt_fbm(vec3 x, int oct) {
	vec4 s = vec4(0.0);
	float amp = 0.5;
	float fr = 1.0;
	float norm = 0.0;
	for (int o = 0; o < oct; o++) {
		vec4 n = dt_noised(x * fr + vec3(float(o) * 17.13, float(o) * -9.71, float(o) * 5.37));
		s.x += amp * n.x;
		s.yzw += amp * fr * n.yzw;
		norm += amp;
		amp *= 0.5;
		fr *= 2.03;
	}
	return s / norm;
}

// ridged fbm, value in [0, 1]
vec4 dt_ridged(vec3 x, int oct) {
	vec4 s = vec4(0.0);
	float amp = 0.5;
	float fr = 1.0;
	float norm = 0.0;
	float w = 1.0;
	for (int o = 0; o < oct; o++) {
		vec4 n = dt_noised(x * fr + vec3(float(o) * 31.7, float(o) * 11.3, float(o) * -7.9));
		float sg = n.x >= 0.0 ? 1.0 : -1.0;
		float r = 1.0 - abs(n.x);
		float v = r * r;
		s.x += amp * v * w;
		s.yzw += amp * w * fr * (-2.0 * r * sg) * n.yzw;
		norm += amp;
		w = clamp(0.35 + v, 0.0, 1.0);   // detail stronger on ridges (derivative of w ignored)
		amp *= 0.5;
		fr *= 2.1;
	}
	return s / norm;
}

vec2 dt_smooth_d(float a, float b, float x) {
	float t = clamp((x - a) / (b - a), 0.0, 1.0);
	return vec2(t * t * (3.0 - 2.0 * t), 6.0 * t * (1.0 - t) / (b - a));
}

uniform int dt_style = 0;          // 0 earth-like, 1 moon (grey, craters)
uniform float dt_seed = 0.0;
uniform float dt_scale = 1.0;      // horizontal feature scale multiplier
uniform float dt_amp = 1.0;        // height multiplier

// Height (m) above radius and gradient w.r.t. planet-local position P (m).
// detail: number of octaves for the small-scale layers (LOD).
vec4 dt_terrain(vec3 P, int detail) {
	vec3 Q = P / dt_scale + vec3(dt_seed * 1000.0);
	float s1 = 1.0 / 22000.0;
	vec4 c = dt_fbm(Q * s1, 5);
	c.yzw *= s1;
	vec4 land = vec4(c.x * 1.7 - 0.06, c.yzw * 1.7);
	vec4 hgt = vec4(land.x * 2000.0, land.yzw * 2000.0);
	if (dt_style == 1) {
		hgt = vec4(land.x * 900.0, land.yzw * 900.0);
	}
	// mountain regions
	float s2 = 1.0 / 7000.0;
	vec4 r = dt_ridged(Q * s2, 4 + detail);
	r.yzw *= s2;
	float s3 = 1.0 / 30000.0;
	vec4 reg = dt_noised(Q * s3 + vec3(5.2, 1.3, 7.7));
	reg.yzw *= s3;
	vec2 mk = dt_smooth_d(0.03, 0.4, land.x + reg.x * 0.25);
	vec3 dmk = mk.y * (land.yzw + reg.yzw * 0.25);
	float mamp = 3400.0;
	if (dt_style == 1) {
		mk = vec2(0.6, 0.0);
		dmk = vec3(0.0);
		mamp = 1200.0;
	}
	hgt.x += mk.x * r.x * mamp;
	hgt.yzw += (dmk * r.x + mk.x * r.yzw) * mamp;
	// hills / detail on land
	float s4 = 1.0 / 1300.0;
	vec4 hl = dt_fbm(Q * s4, 2 + detail);
	hl.yzw *= s4;
	vec2 lm = dt_smooth_d(-0.02, 0.08, land.x);
	if (dt_style == 1) lm = vec2(1.0, 0.0);
	hgt.x += hl.x * 140.0 * lm.x;
	hgt.yzw += (hl.yzw * lm.x + hl.x * lm.y * land.yzw) * 140.0;
	return vec4(hgt.x * dt_amp, hgt.yzw * dt_amp);
}

#endif
