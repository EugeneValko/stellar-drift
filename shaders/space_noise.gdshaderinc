// Shared hashing / noise helpers for space shaders (sky, bake, star).
// Integer hashes (pcg3d) -> deterministic on every GPU, no sin()-hash banding.

uvec3 sn_pcg3d(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> uvec3(16u);
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v;
}

// Hash of an integer lattice point -> 3 floats in [0,1).
vec3 sn_hash3i(ivec3 p) {
	return vec3(sn_pcg3d(uvec3(p))) * (1.0 / 4294967296.0);
}

vec3 sn_hash3(vec3 p) {
	return sn_hash3i(ivec3(floor(p)));
}

// 3D gradient noise, quintic fade. Range ~[-1, 1].
float sn_gnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = p - i;
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	ivec3 ii = ivec3(i);
	vec3 g000 = sn_hash3i(ii) * 2.0 - 1.0;
	vec3 g100 = sn_hash3i(ii + ivec3(1, 0, 0)) * 2.0 - 1.0;
	vec3 g010 = sn_hash3i(ii + ivec3(0, 1, 0)) * 2.0 - 1.0;
	vec3 g110 = sn_hash3i(ii + ivec3(1, 1, 0)) * 2.0 - 1.0;
	vec3 g001 = sn_hash3i(ii + ivec3(0, 0, 1)) * 2.0 - 1.0;
	vec3 g101 = sn_hash3i(ii + ivec3(1, 0, 1)) * 2.0 - 1.0;
	vec3 g011 = sn_hash3i(ii + ivec3(0, 1, 1)) * 2.0 - 1.0;
	vec3 g111 = sn_hash3i(ii + ivec3(1, 1, 1)) * 2.0 - 1.0;
	float n000 = dot(g000, f);
	float n100 = dot(g100, f - vec3(1, 0, 0));
	float n010 = dot(g010, f - vec3(0, 1, 0));
	float n110 = dot(g110, f - vec3(1, 1, 0));
	float n001 = dot(g001, f - vec3(0, 0, 1));
	float n101 = dot(g101, f - vec3(1, 0, 1));
	float n011 = dot(g011, f - vec3(0, 1, 1));
	float n111 = dot(g111, f - vec3(1, 1, 1));
	float nx00 = mix(n000, n100, u.x);
	float nx10 = mix(n010, n110, u.x);
	float nx01 = mix(n001, n101, u.x);
	float nx11 = mix(n011, n111, u.x);
	return 1.6 * mix(mix(nx00, nx10, u.y), mix(nx01, nx11, u.y), u.z);
}

// Rotation applied between fbm octaves (kills lattice alignment).
const mat3 SN_ROT = mat3(
	vec3(0.00, 0.80, 0.60),
	vec3(-0.80, 0.36, -0.48),
	vec3(-0.60, -0.48, 0.64));

// fbm in [-1,1]-ish.
float sn_fbm(vec3 p, int octaves, float gain) {
	float a = 0.5;
	float s = 0.0;
	float n = 0.0;
	for (int i = 0; i < octaves; i++) {
		s += a * sn_gnoise(p);
		n += a;
		p = SN_ROT * p * 2.03;
		a *= gain;
	}
	return s / n;
}

// Ridged fbm in [0,1]: thin bright filaments where noise crosses zero.
float sn_ridged(vec3 p, int octaves, float gain) {
	float a = 0.5;
	float s = 0.0;
	float n = 0.0;
	float prev = 1.0;
	for (int i = 0; i < octaves; i++) {
		float r = 1.0 - abs(sn_gnoise(p));
		r *= r;
		s += a * r * prev;
		n += a;
		prev = clamp(r * 1.5, 0.0, 1.0);
		p = SN_ROT * p * 2.07;
		a *= gain;
	}
	return s / n;
}

// 3D Voronoi: returns (F1, F2) distances. Feature points jitter with `t` (animation).
vec2 sn_voronoi(vec3 p, float t) {
	vec3 i = floor(p);
	vec3 f = p - i;
	float f1 = 8.0;
	float f2 = 8.0;
	ivec3 ii = ivec3(i);
	for (int z = -1; z <= 1; z++)
	for (int y = -1; y <= 1; y++)
	for (int x = -1; x <= 1; x++) {
		ivec3 c = ivec3(x, y, z);
		vec3 h = sn_hash3i(ii + c);
		vec3 o = 0.5 + 0.38 * sin(t * (0.6 + h.yzx) + 6.2831 * h);
		vec3 r = vec3(c) + o - f;
		float d = dot(r, r);
		if (d < f1) { f2 = f1; f1 = d; } else if (d < f2) { f2 = d; }
	}
	return sqrt(vec2(f1, f2));
}

// ---- Cube-face parameterisation (equi-angular) shared by sky + bake ----
// face basis: dir = N + u*U + v*V, u,v in [-1,1] (gnomonic); stored s = atan(u)*4/pi.
void sn_face_basis(int face, out vec3 N, out vec3 U, out vec3 V) {
	if (face == 0) { N = vec3(1, 0, 0); U = vec3(0, 0, -1); V = vec3(0, 1, 0); }
	else if (face == 1) { N = vec3(-1, 0, 0); U = vec3(0, 0, 1); V = vec3(0, 1, 0); }
	else if (face == 2) { N = vec3(0, 1, 0); U = vec3(1, 0, 0); V = vec3(0, 0, -1); }
	else if (face == 3) { N = vec3(0, -1, 0); U = vec3(1, 0, 0); V = vec3(0, 0, 1); }
	else if (face == 4) { N = vec3(0, 0, 1); U = vec3(1, 0, 0); V = vec3(0, 1, 0); }
	else { N = vec3(0, 0, -1); U = vec3(-1, 0, 0); V = vec3(0, 1, 0); }
}

// Direction -> face index + equi-angular coords in [-1,1].
int sn_dir_to_face(vec3 d, out vec2 st) {
	vec3 a = abs(d);
	int face;
	if (a.x >= a.y && a.x >= a.z) { face = d.x > 0.0 ? 0 : 1; }
	else if (a.y >= a.z) { face = d.y > 0.0 ? 2 : 3; }
	else { face = d.z > 0.0 ? 4 : 5; }
	vec3 N; vec3 U; vec3 V;
	sn_face_basis(face, N, U, V);
	float dn = dot(d, N);
	vec2 uv = vec2(dot(d, U), dot(d, V)) / dn;
	st = atan(uv) * (4.0 / PI);
	return face;
}

vec3 sn_face_to_dir(int face, vec2 st) {
	vec3 N; vec3 U; vec3 V;
	sn_face_basis(face, N, U, V);
	vec2 uv = tan(st * (PI / 4.0));
	return normalize(N + uv.x * U + uv.y * V);
}

// Approximate black-body colour (linear sRGB, max channel = 1) for 1000K..40000K.
vec3 sn_blackbody(float k) {
	float t = clamp(k, 1000.0, 40000.0) / 100.0;
	vec3 c;
	if (t <= 66.0) {
		c.r = 1.0;
		c.g = clamp(0.39008158 * log(t) - 0.63184144, 0.0, 1.0);
		c.b = t <= 19.0 ? 0.0 : clamp(0.54320679 * log(t - 10.0) - 1.19625409, 0.0, 1.0);
	} else {
		c.r = clamp(1.29293619 * pow(t - 60.0, -0.1332047592), 0.0, 1.0);
		c.g = clamp(1.12989086 * pow(t - 60.0, -0.0755148492), 0.0, 1.0);
		c.b = 1.0;
	}
	// Tanner-Helland fit is in sRGB space -> convert to linear.
	c = pow(c, vec3(2.2));
	return c / max(max(c.r, c.g), max(c.b, 1e-4));
}
