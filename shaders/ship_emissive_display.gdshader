shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;

// Cockpit displays (Display slot). Each screen quad has UV.x in [id, id+1] (screen id) and UV.y in [0, 1]
// (see tools/blender/ship.py build_cockpit_interior). Procedural flight-UI content per id:
//   0 = radar sweep, 1 = attitude / horizon, 2 = systems bars + trend graph, 4..7 = side consoles (text/map).
uniform vec3 ui_color : source_color = vec3(0.30, 0.85, 1.0);
uniform vec3 accent : source_color = vec3(1.0, 0.62, 0.18);
uniform vec3 bg_color : source_color = vec3(0.006, 0.018, 0.03);
uniform float energy = 2.2;
uniform float time_override = -1.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float line_mask(float d, float w) {
	float aa = max(fwidth(d), 1e-4);
	return 1.0 - smoothstep(w, w + aa * 1.5, abs(d));
}

float box_frame(vec2 uv, float w) {
	vec2 d = min(uv, 1.0 - uv);
	return line_mask(min(d.x, d.y), w);
}

// pseudo text rows: dashes of random length on a baseline grid
float text_rows(vec2 uv, float rows, float seed) {
	float r = floor(uv.y * rows);
	float fy = fract(uv.y * rows);
	float cols = 22.0;
	float c = floor(uv.x * cols);
	float fx = fract(uv.x * cols);
	float len = 4.0 + floor(hash12(vec2(r, seed)) * 14.0);
	float on = step(c, len) * step(0.18, fx) * step(fx, 0.86) * step(0.3, fy) * step(fy, 0.72);
	on *= step(0.25, hash12(vec2(c, r + seed * 3.1)));
	return on;
}

void fragment() {
	float t = time_override >= 0.0 ? time_override : TIME;
	float id = floor(UV.x + 1e-4);
	vec2 uv = vec2(fract(UV.x), UV.y);
	vec3 col = bg_color;
	float m = 0.0;     // ui colour mask
	float a = 0.0;     // accent mask
	m += box_frame(uv, 0.006) * 0.8;
	vec2 c = uv - 0.5;
	if (id < 0.5) {
		// radar: rings, cross, sweep, blips
		vec2 p = c * vec2(1.25, 1.0);
		float r = length(p);
		float ang = atan(p.y, p.x);
		for (int i = 1; i <= 3; i++) {
			m += line_mask(r - 0.14 * float(i), 0.003) * 0.6;
		}
		m += (line_mask(p.x, 0.002) + line_mask(p.y, 0.002)) * step(r, 0.42) * 0.4;
		float sw = fract((ang / 6.2831853) - t * 0.25);
		m += smoothstep(0.85, 1.0, sw) * step(r, 0.42) * 0.6;
		for (int i = 0; i < 6; i++) {
			vec2 b = vec2(hash12(vec2(float(i), 1.0)), hash12(vec2(float(i), 2.0))) * 0.6 - 0.3;
			a += smoothstep(0.018, 0.008, length(p - b));
		}
	} else if (id < 1.5) {
		// attitude: horizon line (slight bank), pitch ladder, velocity vector
		float bank = 0.08 * sin(t * 0.3);
		vec2 q = vec2(c.x * cos(bank) - c.y * sin(bank), c.x * sin(bank) + c.y * cos(bank));
		float hz = q.y + 0.05;
		col = mix(col, vec3(0.01, 0.035, 0.06), step(0.0, hz));
		m += line_mask(hz, 0.004) * 1.2;
		for (int i = -3; i <= 3; i++) {
			if (i == 0) continue;
			float yy = hz - float(i) * 0.11;
			m += line_mask(yy, 0.002) * step(abs(q.x), 0.12 - 0.04 * step(0.0, float(i)) * 0.0) * step(0.04, abs(q.x)) * 0.7;
		}
		vec2 v = c - vec2(0.0, 0.02);
		a += line_mask(length(v) - 0.03, 0.004) + line_mask(v.y, 0.003) * step(0.03, abs(v.x)) * step(abs(v.x), 0.08);
		// heading tape
		float tick = fract(uv.x * 18.0 + t * 0.05);
		m += step(0.88, uv.y) * step(uv.y, 0.93) * line_mask(tick - 0.5, 0.02) * 0.8;
	} else if (id < 2.5) {
		// systems: vertical bars + trend graph
		for (int i = 0; i < 5; i++) {
			float x0 = 0.08 + float(i) * 0.08;
			float h = 0.25 + 0.5 * hash12(vec2(float(i), 7.0)) + 0.05 * sin(t * 1.3 + float(i));
			float inb = step(x0, uv.x) * step(uv.x, x0 + 0.05) * step(0.1, uv.y) * step(uv.y, 0.1 + h * 0.75);
			if (i == 3) a += inb; else m += inb * 0.75;
		}
		float gx = (uv.x - 0.5) / 0.44;
		float g = 0.45 + 0.18 * sin(gx * 9.0 + t) + 0.08 * sin(gx * 23.0 - t * 2.0);
		m += line_mask(uv.y - g, 0.004) * step(0.5, uv.x) * step(uv.x, 0.94);
		m += line_mask(uv.y - 0.2, 0.002) * step(0.5, uv.x) * step(uv.x, 0.94) * 0.5;
		m += text_rows(vec2(uv.x * 2.0 - 1.0, uv.y * 0.25 + 0.75), 4.0, id) * step(0.5, uv.x) * step(0.82, uv.y) * 0.8;
	} else {
		// side consoles: text panels + a small map grid
		float tr = text_rows(uv * vec2(1.0, 1.0), 9.0, id);
		if (mod(id, 2.0) < 0.5) {
			m += tr * 0.7 * step(uv.x, 0.6);
			vec2 g = fract(uv * vec2(6.0, 5.0));
			m += (line_mask(g.x - 0.5, 0.01) + line_mask(g.y - 0.5, 0.01)) * step(0.62, uv.x) * 0.25;
			a += smoothstep(0.03, 0.015, length(uv - vec2(0.78 + 0.05 * sin(t * 0.4), 0.55)));
		} else {
			m += tr * 0.7;
			a += tr * step(0.66, uv.y) * step(uv.y, 0.78);
		}
	}
	// scanlines + vignette
	float scan = 0.85 + 0.15 * sin(uv.y * 240.0);
	float vig = smoothstep(0.75, 0.3, length(c));
	vec3 e = col + (ui_color * clamp(m, 0.0, 1.5) + accent * clamp(a, 0.0, 1.0)) * scan;
	e *= 0.55 + 0.45 * vig;
	ALBEDO = vec3(0.02);
	ROUGHNESS = 0.12;
	SPECULAR = 0.5;
	EMISSION = e * energy;
}
