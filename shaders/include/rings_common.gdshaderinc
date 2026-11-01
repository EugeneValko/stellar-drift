// Planetary ring profile shared by rings.gdshader (ring rendering) and gas_giant.gdshader
// (ring shadow on the planet). Ring plane = planet-local XZ plane, radius in metres.
#ifndef RINGS_COMMON_INC
#define RINGS_COMMON_INC

group_uniforms rings;
uniform float ring_inner = 390000.0;
uniform float ring_outer = 690000.0;
uniform float ring_seed = 0.0;
uniform float ring_opacity = 1.0;            // global opacity multiplier
uniform vec3 ring_color_a : source_color = vec3(0.78, 0.70, 0.58);
uniform vec3 ring_color_b : source_color = vec3(0.55, 0.47, 0.38);
uniform vec3 ring_color_c : source_color = vec3(0.86, 0.82, 0.76);
group_uniforms;

float rg_hash(float n) {
	return fract(sin(n * 12.9898 + ring_seed * 78.233) * 43758.5453);
}

// band-limited 1D value noise: fades out when a cell is smaller than the pixel footprint fw
float rg_noise(float x, float fw) {
	float i = floor(x);
	float f = x - i;
	f = f * f * (3.0 - 2.0 * f);
	float v = mix(rg_hash(i), rg_hash(i + 1.0), f);
	return mix(v, 0.5, smoothstep(0.25, 1.0, fw));
}

// Normal-incidence opacity (0..1) at ring radius r; fw = radial footprint (m) for filtering.
float ring_density(float r, float fw) {
	float u = (r - ring_inner) / (ring_outer - ring_inner);
	if (u <= 0.0 || u >= 1.0) return 0.0;
	float fu = fw / (ring_outer - ring_inner);
	// major structure: faint inner C ring, dense B ring, Cassini division, A ring with gaps
	float d = 0.12 + 0.18 * smoothstep(0.02, 0.26, u);
	d = mix(d, 0.85, smoothstep(0.26, 0.30, u) * (1.0 - smoothstep(0.60, 0.615, u)));
	d = mix(d, 0.06, smoothstep(0.605, 0.62, u) * (1.0 - smoothstep(0.66, 0.675, u)));
	d = mix(d, 0.62, smoothstep(0.665, 0.68, u) * (1.0 - smoothstep(0.93, 0.95, u)));
	d *= 1.0 - 0.9 * smoothstep(0.004, 0.0, abs(u - 0.875) - 0.002);   // Encke-like gap
	d = mix(d, 0.0, smoothstep(0.945, 0.955, u));
	d += 0.5 * smoothstep(0.004, 0.0, abs(u - 0.975));                  // thin F ring
	// fine ringlets at several scales (band-limited)
	float f1 = rg_noise(u * 60.0, fu * 60.0);
	float f2 = rg_noise(u * 230.0 + 17.0, fu * 230.0);
	float f3 = rg_noise(u * 900.0 + 41.0, fu * 900.0);
	float f4 = rg_noise(u * 3100.0 + 97.0, fu * 3100.0);
	float fine = f1 * 0.35 + f2 * 0.3 + f3 * 0.2 + f4 * 0.15;
	d *= mix(0.12, 1.7, fine * fine * 1.3);
	// soft edges
	d *= smoothstep(0.0, 0.01, u) * smoothstep(1.0, 0.99, u);
	return clamp(d * ring_opacity, 0.0, 0.98);
}

vec3 ring_albedo(float r, float fw) {
	float u = clamp((r - ring_inner) / (ring_outer - ring_inner), 0.0, 1.0);
	float fu = fw / (ring_outer - ring_inner);
	float t = rg_noise(u * 40.0 + 3.0, fu * 40.0) * 0.5 + rg_noise(u * 400.0 + 9.0, fu * 400.0) * 0.3
		+ rg_noise(u * 1500.0 + 5.0, fu * 1500.0) * 0.2;
	float tint = rg_noise(u * 17.0 + 21.0, fu * 17.0);
	vec3 c = mix(ring_color_b, ring_color_a, smoothstep(0.15, 0.4, u));
	c = mix(c, ring_color_c, smoothstep(0.66, 0.8, u) * 0.6);
	c = mix(c, c * vec3(1.08, 0.9, 0.78), smoothstep(0.4, 0.8, tint));   // rusty bands
	c = mix(c, c * vec3(0.85, 0.88, 0.92), smoothstep(0.6, 0.2, tint) * 0.6); // greyish bands
	return c * mix(0.55, 1.3, t);
}

#endif
