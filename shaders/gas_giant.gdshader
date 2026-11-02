// Gas giant surface (Aurelion): latitude bands with turbulent flow (domain-warped simplex fbm,
// stretched along the bands, advected with alternating jets using two-phase flow blending so it
// never shears apart), a large oval storm vortex + small white ovals, soft terminator, limb
// darkening, ring shadow. The atmosphere rim/haze comes from an AtmosphereLayer child.
shader_type spatial;
render_mode unshaded, cull_back, fog_disabled;

#include "res://shaders/include/sun_globals.gdshaderinc"
#include "res://shaders/include/rings_common.gdshaderinc"

group_uniforms gas_giant;
uniform float gg_radius = 300000.0;
uniform float gg_seed = 0.0;
uniform float gg_band_scale = 1.0;           // more/less bands
uniform float gg_turbulence = 1.6;
uniform float gg_flow_speed = 1.0;           // animation speed multiplier
uniform int gg_octaves = 7;                  // quality knob (5 low .. 8 high)
uniform vec3 gg_col_zone : source_color = vec3(0.93, 0.86, 0.72);   // bright zones
uniform vec3 gg_col_belt : source_color = vec3(0.62, 0.42, 0.26);   // dark belts
uniform vec3 gg_col_mid : source_color = vec3(0.80, 0.64, 0.45);
uniform vec3 gg_col_polar : source_color = vec3(0.50, 0.52, 0.55);
uniform vec3 gg_col_accent : source_color = vec3(0.70, 0.30, 0.16);
uniform vec3 gg_storm_dir = vec3(0.6, -0.36, 0.71);   // local unit vector of the big storm
uniform vec2 gg_storm_size = vec2(0.20, 0.11);        // half-extent (rad) lon / lat
uniform vec3 gg_storm_color : source_color = vec3(0.78, 0.36, 0.20);
uniform float gg_ring_shadow = 0.0;           // 0 = no rings
uniform float gg_brightness = 1.0;
// wave 4: second storm, brown barges, equatorial festoons, polar cyclone rings, aurora
uniform vec3 gg_storm2_dir = vec3(-0.55, 0.40, -0.73);
uniform vec2 gg_storm2_size = vec2(0.085, 0.05);
uniform vec3 gg_storm2_color : source_color = vec3(0.55, 0.30, 0.20);
uniform float gg_detail = 1.0;                // fine band detail / festoon strength
uniform vec3 gg_aurora_color : source_color = vec3(0.25, 1.0, 0.55);
uniform float gg_aurora = 1.0;               // night-side polar aurora (0 = off)
group_uniforms;

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

// --- 3D simplex noise (Stefan Gustavson, MIT) ---
vec4 gg_perm(vec4 x) { return mod(((x * 34.0) + 1.0) * x, 289.0); }
float gg_snoise(vec3 v) {
	const vec2 C = vec2(1.0 / 6.0, 1.0 / 3.0);
	vec3 i = floor(v + dot(v, C.yyy));
	vec3 x0 = v - i + dot(i, C.xxx);
	vec3 g = step(x0.yzx, x0.xyz);
	vec3 l = 1.0 - g;
	vec3 i1 = min(g.xyz, l.zxy);
	vec3 i2 = max(g.xyz, l.zxy);
	vec3 x1 = x0 - i1 + C.xxx;
	vec3 x2 = x0 - i2 + 2.0 * C.xxx;
	vec3 x3 = x0 - 1.0 + 3.0 * C.xxx;
	i = mod(i, 289.0);
	vec4 p = gg_perm(gg_perm(gg_perm(i.z + vec4(0.0, i1.z, i2.z, 1.0))
		+ i.y + vec4(0.0, i1.y, i2.y, 1.0)) + i.x + vec4(0.0, i1.x, i2.x, 1.0));
	float n_ = 1.0 / 7.0;
	vec3 ns = n_ * vec3(2.0, 0.0, 1.0) - vec3(0.0, 1.0, 0.0);   // D.wyz - D.xzx
	vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
	vec4 x_ = floor(j * ns.z);
	vec4 y_ = floor(j - 7.0 * x_);
	vec4 x = x_ * ns.x + ns.yyyy;
	vec4 y = y_ * ns.x + ns.yyyy;
	vec4 h = 1.0 - abs(x) - abs(y);
	vec4 b0 = vec4(x.xy, y.xy);
	vec4 b1 = vec4(x.zw, y.zw);
	vec4 s0 = floor(b0) * 2.0 + 1.0;
	vec4 s1 = floor(b1) * 2.0 + 1.0;
	vec4 sh = -step(h, vec4(0.0));
	vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
	vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
	vec3 p0 = vec3(a0.xy, h.x);
	vec3 p1 = vec3(a0.zw, h.y);
	vec3 p2 = vec3(a1.xy, h.z);
	vec3 p3 = vec3(a1.zw, h.w);
	vec4 norm = 1.79284291400159 - 0.85373472095314 * vec4(dot(p0, p0), dot(p1, p1), dot(p2, p2), dot(p3, p3));
	p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
	vec4 m = max(0.6 - vec4(dot(x0, x0), dot(x1, x1), dot(x2, x2), dot(x3, x3)), 0.0);
	m = m * m;
	return 42.0 * dot(m * m, vec4(dot(p0, x0), dot(p1, x1), dot(p2, x2), dot(p3, x3)));
}

// fbm stretched along latitude (features elongated east-west)
float gg_fbm(vec3 p, int oct) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < oct; i++) {
		s += a * gg_snoise(p);
		p = p * 2.02 + vec3(1.7, -3.1, 2.3);
		a *= 0.5;
	}
	return s;
}

vec3 gg_rot_y(vec3 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}

vec3 gg_rot_axis(vec3 v, vec3 axis, float a) {
	float c = cos(a);
	float s = sin(a);
	return v * c + cross(axis, v) * s + axis * dot(axis, v) * (1.0 - c);
}

float gg_jet(float y) {
	// alternating zonal jets (sign changes with band)
	return sin(y * 9.0 * gg_band_scale) * 0.7 + sin(y * 23.0 * gg_band_scale + 1.3) * 0.3;
}

// band value 0..1 + turbulence for one flow phase
vec2 gg_pattern(vec3 n, float shift) {
	float y = n.y;
	vec3 p = gg_rot_y(n, gg_jet(y) * shift);
	vec3 seedv = vec3(gg_seed * 13.1, gg_seed * 7.3, gg_seed * 3.7);
	vec3 ps = vec3(p.x, p.y * 3.5, p.z) * 2.2 + seedv;
	// domain warp (two levels), stronger near belt edges
	vec3 w1 = vec3(gg_fbm(ps, 4), gg_fbm(ps + vec3(5.2, 1.3, 2.8), 4), 0.0);
	vec3 ps2 = vec3(p.x * 4.0, p.y * 22.0, p.z * 4.0) + vec3(w1.x, w1.y * 0.4, w1.x) * 1.6 + seedv;
	float t = gg_fbm(ps2, gg_octaves);
	float yb = y + (w1.x * 0.025 + t * 0.022) * gg_turbulence;
	float band = 0.5 + 0.5 * (sin(yb * 17.0 * gg_band_scale + 0.4) * 0.55
		+ sin(yb * 41.0 * gg_band_scale + 2.1) * 0.3 + sin(yb * 97.0 * gg_band_scale) * 0.15);
	return vec2(band, t);
}

void fragment() {
	vec3 n = normalize(v_local);      // planet-local direction (axis = +Y)
	float ft = TIME * 0.004 * gg_flow_speed;
	// two-phase flow: blend two advected copies so shear never accumulates
	float ph = fract(ft);
	float ph2 = fract(ft + 0.5);
	float wa = 1.0 - abs(ph * 2.0 - 1.0);

	// big storm: swirl the sampling domain around the storm centre (oval)
	vec3 S = normalize(gg_storm_dir);
	vec3 east = normalize(cross(vec3(0.0, 1.0, 0.0), S));
	vec3 north = cross(S, east);
	vec3 dv = n - S;
	vec2 e = vec2(dot(dv, east) / gg_storm_size.x, dot(dv, north) / gg_storm_size.y);
	float sr = length(e);
	vec3 ns = n;
	if (sr < 2.5) {
		float sw = exp(-sr * sr * 1.2);
		ns = normalize(gg_rot_axis(n, S, -sw * 5.0 - ft * 6.0 * sw));
	}
	// small white ovals in a southern band
	float ov = 0.0;
	for (int i = 0; i < 6; i++) {
		float fi = float(i);
		float lon = fi * 1.05 + 0.4 + gg_seed;
		vec3 c = normalize(vec3(cos(lon) * 0.82, -0.57, sin(lon) * 0.82));
		vec3 d = n - c;
		vec3 ce = normalize(cross(vec3(0.0, 1.0, 0.0), c));
		vec2 q = vec2(dot(d, ce) / 0.035, dot(d, cross(c, ce)) / 0.022);
		float r2 = dot(q, q);
		if (r2 < 6.0) {
			ns = normalize(gg_rot_axis(ns, c, exp(-r2) * 3.0));
			ov = max(ov, exp(-r2 * 1.5));
		}
	}

	// second (northern) storm: smaller dark red-brown anticyclone
	vec3 S2 = normalize(gg_storm2_dir);
	vec3 east2 = normalize(cross(vec3(0.0, 1.0, 0.0), S2));
	vec3 north2 = cross(S2, east2);
	vec3 dv2 = n - S2;
	vec2 e2 = vec2(dot(dv2, east2) / gg_storm2_size.x, dot(dv2, north2) / gg_storm2_size.y);
	float sr2 = length(e2);
	if (sr2 < 2.5) {
		float sw2 = exp(-sr2 * sr2 * 1.3);
		ns = normalize(gg_rot_axis(ns, S2, sw2 * 4.0 + ft * 5.0 * sw2));
	}
	// polar cyclone clusters: a ring of vortices around each pole + one at the pole
	float pc = 0.0;
	for (int i = 0; i < 9; i++) {
		float fi = float(i);
		float hemi = i < 5 ? 1.0 : -1.0;
		float lon = fi * 1.2566 + gg_seed * 0.7 + (hemi < 0.0 ? 0.6 : 0.0);
		float colat = (i == 0 || i == 5) ? 0.0 : 0.3;
		vec3 c = normalize(vec3(sin(colat) * cos(lon), hemi * cos(colat), sin(colat) * sin(lon)));
		float d2 = dot(n - c, n - c) / (0.07 * 0.07);
		if (d2 < 6.0) {
			ns = normalize(gg_rot_axis(ns, c, hemi * exp(-d2) * 4.0));
			pc = max(pc, exp(-d2 * 1.4));
		}
	}

	vec2 A = gg_pattern(ns, (ph - 0.5) * 0.35);
	vec2 B = gg_pattern(ns, (ph2 - 0.5) * 0.35);
	vec2 P = mix(B, A, wa);
	float band = P.x;
	float turb = P.y;

	// palette
	vec3 col = mix(gg_col_belt, gg_col_mid, smoothstep(0.2, 0.5, band));
	col = mix(col, gg_col_zone, smoothstep(0.5, 0.8, band));
	col = mix(col, gg_col_accent, smoothstep(0.15, 0.6, turb) * smoothstep(0.55, 0.3, band) * 0.35);
	col *= 0.88 + 0.3 * turb;
	float lat = abs(n.y);
	col = mix(col, gg_col_polar * (0.85 + 0.3 * turb), smoothstep(0.72, 0.93, lat));
	// storm colour: reddish oval with lighter collar
	float core = smoothstep(1.1, 0.35, sr);
	float collar = smoothstep(1.5, 1.05, sr) * (1.0 - core);
	col = mix(col, gg_col_zone * 1.05, collar * 0.6);
	col = mix(col, gg_storm_color * (0.85 + 0.35 * turb), core);
	col = mix(col, vec3(0.97, 0.95, 0.9), ov * 0.85);
	// storm 2 colour + bright rim
	float core2 = smoothstep(1.1, 0.4, sr2);
	col = mix(col, gg_col_zone * 1.08, smoothstep(1.45, 1.05, sr2) * (1.0 - core2) * 0.5);
	col = mix(col, gg_storm2_color * (0.85 + 0.3 * turb), core2);
	// fine streaks along the bands (Kelvin-Helmholtz detail) + equatorial festoons
	float fine = gg_snoise(vec3(ns.x * 34.0, ns.y * 190.0, ns.z * 34.0) + gg_seed * 3.1);
	col *= 1.0 + 0.07 * gg_detail * fine;
	float eq = exp(-pow((abs(n.y) - 0.075) / 0.028, 2.0));
	float fest = smoothstep(0.15, 0.7, gg_snoise(vec3(ns.x * 11.0, ns.y * 26.0, ns.z * 11.0) + vec3(gg_seed * 1.7)));
	col = mix(col, col * vec3(0.42, 0.48, 0.6), eq * fest * 0.6 * gg_detail);
	// brown barges in the northern belt
	for (int i = 0; i < 5; i++) {
		float fi = float(i);
		float lon = fi * 1.31 + 0.9 + gg_seed * 0.3;
		vec3 c = normalize(vec3(cos(lon) * 0.955, 0.295, sin(lon) * 0.955));
		vec3 ce = normalize(cross(vec3(0.0, 1.0, 0.0), c));
		vec3 d = n - c;
		vec2 q = vec2(dot(d, ce) / 0.05, dot(d, cross(c, ce)) / 0.014);
		float b = exp(-dot(q, q) * 1.2);
		col = mix(col, vec3(0.36, 0.2, 0.12), b * 0.75 * gg_detail);
	}
	// polar cyclones: slightly lighter cores, dark collars
	col = mix(col, col * vec3(1.15, 1.12, 1.08), pc * 0.5);

	// lighting (world space)
	vec3 Nw = normalize(mat3(MODEL_MATRIX) * n);
	vec3 L = sd_sun_dir();
	vec3 V = normalize(CAMERA_POSITION_WORLD - (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	float nl = dot(Nw, L);
	float nv = max(dot(Nw, V), 0.0);
	float diff = smoothstep(-0.06, 0.25, nl) * mix(0.35, 1.0, clamp(nl, 0.0, 1.0)) + max(nl, 0.0) * 0.0;
	diff *= pow(max(nl, 0.0) + 0.02, 0.15);              // slight limb/terminator darkening
	diff *= mix(0.75, 1.0, pow(nv, 0.3));                 // limb darkening
	// terminator reddening (light through the high haze)
	vec3 term = mix(vec3(1.0, 0.62, 0.38), vec3(1.0), smoothstep(0.0, 0.3, nl));
	// ring shadow
	float rs = 1.0;
	if (gg_ring_shadow > 0.0) {
		vec3 up = normalize(MODEL_MATRIX[1].xyz);
		vec3 pw = Nw * gg_radius;
		float lu = dot(L, up);
		if (abs(lu) > 1e-4) {
			float t = -dot(pw, up) / lu;
			if (t > 0.0) {
				vec3 hit = pw + L * t;
				float rr = length(hit);
				float fw = 0.002 * t + 50.0;
				rs = 1.0 - ring_density(rr, fw) * gg_ring_shadow;
			}
		}
	}
	vec3 lit = col * sun_color.rgb * sun_intensity * diff * term * rs * gg_brightness;
	// ringshine on the night side: hemisphere facing the sunlit face of the rings
	if (gg_ring_shadow > 0.0) {
		vec3 upr = normalize(MODEL_MATRIX[1].xyz);
		float lu = dot(L, upr);
		float face = max(dot(Nw, upr) * sign(lu), 0.0);
		lit += col * sun_color.rgb * sun_intensity * 0.05 * abs(lu) * sqrt(face) * (1.0 - smoothstep(-0.1, 0.2, nl)) * gg_brightness;
	}
	// aurora: thin auroral ovals around both (slightly tilted) magnetic poles, night side only
	if (gg_aurora > 0.0) {
		vec3 mp = normalize(vec3(0.12, 1.0, 0.05));
		float cn = abs(dot(n, mp));
		float ang = acos(clamp(cn, 0.0, 1.0));
		float oval = exp(-pow((ang - 0.21 - 0.02 * gg_snoise(n * 9.0 + vec3(TIME * 0.02))) / 0.018, 2.0));
		float curtain = 0.55 + 0.45 * gg_snoise(vec3(n.x * 60.0, TIME * 0.05, n.z * 60.0));
		float night = 1.0 - smoothstep(-0.12, 0.08, nl);
		vec3 aur = mix(gg_aurora_color, vec3(0.9, 0.25, 0.55), smoothstep(0.205, 0.17, ang) * 0.6);
		lit += aur * oval * curtain * night * gg_aurora * 0.06 * sun_intensity;
	}
	ALBEDO = lit;
}
