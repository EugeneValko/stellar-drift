// TEST-ONLY space background (the real sky is made by another system): sparse stars + sun disk.
shader_type sky;

uniform float star_brightness = 0.6;
uniform float sun_disk_radiance = 60.0;
uniform float sun_angular_radius = 0.008;

uint bg_hash(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
	return v.x ^ v.y ^ v.z;
}

vec3 stars(vec3 d, float scale, float thr) {
	vec3 p = d * scale;
	vec3 i = floor(p);
	uint h = bg_hash(uvec3(ivec3(i) + 100000));
	float hv = float(h & 65535u) / 65535.0;
	if (hv < thr) return vec3(0.0);
	vec3 sp = i + 0.5 + 0.35 * vec3(float((h >> 8u) & 255u), float((h >> 16u) & 255u), float((h >> 24u) & 255u)) / 255.0 - 0.175;
	float dist = length(p - sp);
	float b = pow((hv - thr) / (1.0 - thr), 3.0);
	float t = float((h >> 4u) & 15u) / 15.0;
	vec3 tint = mix(vec3(1.0, 0.75, 0.55), vec3(0.65, 0.8, 1.0), t);
	return tint * b * exp(-dist * dist * 40.0) * 6.0;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 col = stars(d, 300.0, 0.985) + stars(d, 900.0, 0.995) * 0.5;
	col *= star_brightness;
	// faint milky band
	float band = exp(-pow(dot(d, normalize(vec3(0.3, 0.9, -0.3))) / 0.25, 2.0));
	col += vec3(0.010, 0.010, 0.014) * band;
	if (LIGHT0_ENABLED) {
		float c = dot(d, LIGHT0_DIRECTION);
		float ang = acos(clamp(c, -1.0, 1.0));
		float disk = 1.0 - smoothstep(sun_angular_radius * 0.9, sun_angular_radius, ang);
		col += LIGHT0_COLOR * sun_disk_radiance * disk;
		col += LIGHT0_COLOR * 0.02 * exp(-ang * 30.0);
	}
	COLOR = col;
}
