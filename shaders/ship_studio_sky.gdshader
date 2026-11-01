shader_type sky;

// Stand-alone sky for the ship test scene (the real space sky lives in src/space). Gives metal something
// to reflect: dark space gradient, soft nebula lobes, star specks, a sun disk/halo along LIGHT0.
// mode 0 = space, 1 = planet surface (dusk atmosphere).
uniform int mode = 0;
uniform vec3 space_top : source_color = vec3(0.004, 0.006, 0.012);
uniform vec3 space_bottom : source_color = vec3(0.010, 0.008, 0.014);
uniform vec3 neb_a : source_color = vec3(0.10, 0.22, 0.45);
uniform vec3 neb_b : source_color = vec3(0.45, 0.16, 0.30);
uniform float nebula = 1.0;
uniform float stars = 1.0;
uniform vec3 atmo_zenith : source_color = vec3(0.10, 0.20, 0.42);
uniform vec3 atmo_horizon : source_color = vec3(0.95, 0.55, 0.32);
uniform vec3 ground_col : source_color = vec3(0.10, 0.08, 0.07);
uniform float sun_energy = 30.0;

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x), mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x), mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		s += a * vnoise(p);
		p = p * 2.07 + vec3(3.1, 1.7, 5.3);
		a *= 0.5;
	}
	return s;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 sd = LIGHT0_DIRECTION;
	float sun_dot = max(dot(d, sd), 0.0);
	vec3 col;
	if (mode == 0) {
		col = mix(space_bottom, space_top, d.y * 0.5 + 0.5);
		// nebula lobes
		float n1 = fbm(d * 2.2 + vec3(4.0));
		float n2 = fbm(d * 3.7 + vec3(11.0));
		float band = exp(-pow(dot(d, normalize(vec3(0.3, 0.85, -0.4))) * 2.2, 2.0));
		float lobe = smoothstep(0.35, 0.8, n1) * (0.35 + band);
		col += neb_a * lobe * 0.55 * nebula;
		col += neb_b * smoothstep(0.5, 0.85, n2) * band * 0.4 * nebula;
		col += vec3(0.02, 0.03, 0.05) * band;
		// stars
		if (!AT_CUBEMAP_PASS) {
			vec3 sp = d * 420.0;
			vec3 cell = floor(sp);
			float h = hash13(cell);
			vec3 fp = fract(sp) - 0.5;
			float st = smoothstep(0.12, 0.0, length(fp)) * step(0.985, h) * stars;
			col += vec3(0.8, 0.85, 1.0) * st * (h - 0.985) * 260.0;
		}
		// sun glare
		col += vec3(1.0, 0.92, 0.8) * (pow(sun_dot, 900.0) * sun_energy + pow(sun_dot, 40.0) * 0.25 + pow(sun_dot, 6.0) * 0.04);
	} else {
		float h = d.y;
		vec3 sky = mix(atmo_horizon, atmo_zenith, pow(clamp(h, 0.0, 1.0), 0.45));
		sky += vec3(1.0, 0.6, 0.35) * pow(sun_dot, 8.0) * 0.6;
		vec3 gnd = ground_col * (0.6 + 0.4 * smoothstep(-0.3, 0.0, h));
		col = mix(gnd, sky, smoothstep(-0.02, 0.01, h));
		col += vec3(1.0, 0.85, 0.65) * pow(sun_dot, 1200.0) * sun_energy;
	}
	COLOR = col;
}
