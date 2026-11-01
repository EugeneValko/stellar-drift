shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Ship hull material (Hull / HullDark / Trim slots with different parameters), ship v2 "SD-9 Halcyon".
// Everything is procedural in ship space (Godot axes: +X right, +Y up, -Z forward, meters):
//  - triplanar panel lines + rivets + per-panel tint/roughness/clearcoat variation, bump-mapped grooves
//  - edge wear from baked vertex color R (convexity), grime from G (cavity) and B (ambient visibility)
//  - livery (markings = 1): twin dorsal stripes, spine walkway, pod bands, hull number, radiator panels,
//    anti-glare panel, hazard frames around the gear bays and the ramp, flank pinstripe
//  - titanium heat tint near the nozzles (Trim), light exhaust soot
// Separate parts (gear, doors, hatch, canopy) set `part_offset` = their rest origin in ship space so the
// patterns line up with the hull. Layout constants match tools/blender/ship.py.

uniform vec3 base_color : source_color = vec3(0.80, 0.80, 0.78);
uniform vec3 base_color_alt : source_color = vec3(0.72, 0.73, 0.74);
uniform float alt_panel_ratio : hint_range(0.0, 1.0) = 0.22;
uniform float panel_tone_var : hint_range(0.0, 0.3) = 0.07;
uniform float metallic : hint_range(0.0, 1.0) = 0.1;
uniform float roughness : hint_range(0.0, 1.0) = 0.38;
uniform float roughness_var : hint_range(0.0, 0.5) = 0.10;
uniform float specular : hint_range(0.0, 1.0) = 0.5;
uniform float clearcoat : hint_range(0.0, 1.0) = 0.0;
uniform float clearcoat_roughness : hint_range(0.0, 1.0) = 0.25;

uniform float panel_scale = 1.0;
uniform float panel_line_width = 0.012;
uniform float panel_line_dark : hint_range(0.0, 1.0) = 0.6;
uniform float panel_groove_depth = 0.003;
uniform float rivet_amount : hint_range(0.0, 1.0) = 0.35;

uniform float edge_wear : hint_range(0.0, 1.0) = 0.6;
uniform vec3 wear_color : source_color = vec3(0.62, 0.63, 0.65);
uniform float edge_highlight : hint_range(0.0, 1.0) = 0.12;
uniform float grime : hint_range(0.0, 1.0) = 0.5;
uniform vec3 grime_color : source_color = vec3(0.20, 0.18, 0.16);
uniform float ao_strength : hint_range(0.0, 1.0) = 0.85;
uniform float soot : hint_range(0.0, 1.0) = 0.3;

uniform float belly_amount : hint_range(0.0, 1.0) = 0.0; // two-tone: darker underside
uniform vec3 belly_color : source_color = vec3(0.20, 0.21, 0.23);
uniform float belly_metallic : hint_range(0.0, 1.0) = 0.35;
uniform float markings : hint_range(0.0, 1.0) = 0.0;
uniform vec3 accent_color : source_color = vec3(0.96, 0.40, 0.07);
uniform vec3 marking_dark : source_color = vec3(0.07, 0.075, 0.085);
uniform vec3 hazard_color : source_color = vec3(0.95, 0.72, 0.10);
uniform vec3 number_color : source_color = vec3(0.10, 0.11, 0.12);
uniform vec3 radiator_color : source_color = vec3(0.17, 0.19, 0.22);

uniform float brushed : hint_range(0.0, 1.0) = 0.0;
uniform float heat_tint : hint_range(0.0, 1.0) = 0.0;
uniform float heat_z0 = 8.3;
uniform float heat_z1 = 9.7;

// ship layout (tools/blender/ship.py, Godot axes)
uniform float pod_x = 3.9;
uniform float pod_top = 1.36;
uniform vec2 rad_root = vec2(4.42, 0.98);
uniform float rad_dihedral = 38.0;
uniform float rad_span = 2.75;
uniform vec2 rad_le = vec2(1.6, 4.85);      // leading edge z at root / tip
uniform vec3 bay_front = vec3(0.0, -6.35, 0.5);  // x, z, half size
uniform vec3 bay_rear = vec3(3.9, 5.0, 0.6);
uniform vec4 ramp = vec4(0.72, -3.55, -0.35, 0.0);  // half width, z0, z1

instance uniform vec3 part_offset = vec3(0.0);

varying vec3 v_pos;
varying vec3 v_nrm;

void vertex() {
	v_pos = VERTEX + part_offset;
	v_nrm = NORMAL;
}

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = hash13(i);
	float n100 = hash13(i + vec3(1, 0, 0));
	float n010 = hash13(i + vec3(0, 1, 0));
	float n110 = hash13(i + vec3(1, 1, 0));
	float n001 = hash13(i + vec3(0, 0, 1));
	float n101 = hash13(i + vec3(1, 0, 1));
	float n011 = hash13(i + vec3(0, 1, 1));
	float n111 = hash13(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
			mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float a = 0.5;
	float s = 0.0;
	for (int i = 0; i < 4; i++) {
		s += a * vnoise(p);
		p = p * 2.03 + vec3(1.7, 9.2, 3.1);
		a *= 0.5;
	}
	return s;
}

// Irregular plating: staggered rows, randomly split cells.
// returns x = distance to nearest seam (m), y = panel id hash, z = rivet mask
vec3 panels(vec2 p, vec2 cell) {
	cell *= panel_scale;
	float row = floor(p.x / cell.x);
	p.y += hash12(vec2(row, 7.13)) * cell.y;
	vec2 id = floor(p / cell);
	vec2 f = p / cell - id;
	vec2 sz = cell;
	float h = hash12(id);
	float h2 = hash12(id + 17.31);
	float h3 = hash12(id + 41.7);
	if (h > 0.42) {
		float s = 0.32 + 0.36 * h2;
		if (f.x < s) { f.x /= s; sz.x *= s; id.x += 0.31; }
		else { f.x = (f.x - s) / (1.0 - s); sz.x *= (1.0 - s); id.x += 0.67; }
	}
	if (h < 0.28 || h > 0.83) {
		float s = 0.35 + 0.3 * h3;
		if (f.y < s) { f.y /= s; sz.y *= s; id.y += 0.29; }
		else { f.y = (f.y - s) / (1.0 - s); sz.y *= (1.0 - s); id.y += 0.71; }
	}
	vec2 dm = min(f, 1.0 - f) * sz;
	float d = min(dm.x, dm.y);
	float sp = 0.11;
	float along = f.x * sz.x;
	vec2 rq = vec2((fract(along / sp) - 0.5) * sp, dm.y - 0.04);
	float rv = smoothstep(0.0075, 0.004, length(rq)) * step(0.05, dm.x);
	return vec3(d, hash12(id * 1.37 + 3.3), rv * step(0.5, hash12(id + 5.5)));
}

// 7-segment digit mask in a [-0.5,0.5]x[-1,1] box
float seg_box(vec2 p, vec2 c, vec2 hs) {
	vec2 d = abs(p - c) - hs;
	return step(max(d.x, d.y), 0.0);
}

float digit(vec2 p, int n) {
	float t = 0.12;
	float m = 0.0;
	bool a = n != 1 && n != 4;
	bool b = n != 5 && n != 6;
	bool c = n != 2;
	bool d = n != 1 && n != 4 && n != 7;
	bool e = n == 0 || n == 2 || n == 6 || n == 8;
	bool f = n != 1 && n != 2 && n != 3 && n != 7;
	bool g = n != 0 && n != 1 && n != 7;
	if (a) m = max(m, seg_box(p, vec2(0.0, 0.9), vec2(0.42, t)));
	if (g) m = max(m, seg_box(p, vec2(0.0, 0.0), vec2(0.42, t)));
	if (d) m = max(m, seg_box(p, vec2(0.0, -0.9), vec2(0.42, t)));
	if (b) m = max(m, seg_box(p, vec2(0.42, 0.45), vec2(t, 0.52)));
	if (c) m = max(m, seg_box(p, vec2(0.42, -0.45), vec2(t, 0.52)));
	if (f) m = max(m, seg_box(p, vec2(-0.42, 0.45), vec2(t, 0.52)));
	if (e) m = max(m, seg_box(p, vec2(-0.42, -0.45), vec2(t, 0.52)));
	return m;
}

float band(float v, float a, float b) {
	float w = max(fwidth(v), 1e-5);
	return smoothstep(a - w, a + w, v) * (1.0 - smoothstep(b - w, b + w, v));
}

vec3 bump_normal(vec3 N, vec3 P, float h) {
	vec3 dpdx = dFdx(P);
	vec3 dpdy = dFdy(P);
	float dhx = dFdx(h);
	float dhy = dFdy(h);
	vec3 r1 = cross(dpdy, N);
	vec3 r2 = cross(N, dpdx);
	float det = dot(dpdx, r1);
	vec3 g = sign(det) * (dhx * r1 + dhy * r2);
	vec3 nn = abs(det) * N - g;
	float l = length(nn);
	return (l > 1e-12 && abs(det) > 1e-14) ? nn / l : N;
}

// hazard frame around a rounded-square opening on the belly
float bay_frame(vec2 q, vec2 c, float hs) {
	vec2 d = abs(q - c);
	float r = max(d.x, d.y) - hs;
	return band(r, 0.03, 0.13);
}

void fragment() {
	vec3 p = v_pos;
	vec3 n = v_nrm / max(length(v_nrm), 1e-6);
	vec3 an = abs(n);
	vec3 w = pow(an, vec3(10.0)) + 1e-6;
	w /= (w.x + w.y + w.z);

	// --- panels (triplanar) ---
	vec3 px = panels(vec2(p.z, p.y), vec2(1.9, 1.05));
	vec3 py = panels(vec2(p.z, p.x + 0.37), vec2(1.9, 1.2));
	vec3 pz = panels(vec2(p.x, p.y), vec2(1.1, 0.8));
	float d = px.x * w.x + py.x * w.y + pz.x * w.z;
	float pid = px.y * w.x + py.y * w.y + pz.y * w.z;
	float rivet = (px.z * w.x + py.z * w.y + pz.z * w.z) * rivet_amount;
	float aa = max(fwidth(d), 1e-5);
	float hw = panel_line_width * 0.5;
	float line = 1.0 - smoothstep(hw, hw + aa * 1.2, d);
	float vis = clamp(panel_line_width / (aa * 3.0), 0.0, 1.0); // fade sub-pixel seams
	line *= vis;
	float lip = (smoothstep(hw, hw + 0.004, d) - smoothstep(hw + 0.006, hw + 0.016, d)) * vis;

	// --- vertex data ---
	float edge = COLOR.r;
	float cavity = COLOR.g;
	float ao = COLOR.b;

	// --- base color: panel patchwork that survives distance (tone + gloss per panel) ---
	float alt = step(1.0 - alt_panel_ratio, pid);
	vec3 col = mix(base_color, base_color_alt, alt);
	col *= 1.0 - panel_tone_var * 0.5 + panel_tone_var * hash12(vec2(pid * 91.0, 1.0));
	float rough = roughness + (pid - 0.5) * 2.0 * roughness_var;
	float metal = metallic;
	float coat = clearcoat * (0.6 + 0.4 * hash12(vec2(pid * 13.0, 4.0)));
	float bel = smoothstep(-0.16, -0.30, n.y) * belly_amount;
	col = mix(col, belly_color * (0.92 + 0.16 * pid), bel);
	metal = mix(metal, belly_metallic, bel);
	rough = mix(rough, rough + 0.08, bel);
	coat *= 1.0 - bel * 0.6;

	// brushed metal (trim)
	if (brushed > 0.0) {
		float br = vnoise(vec3(p.x * 40.0, p.y * 40.0, p.z * 1.5)) * 0.6 + vnoise(vec3(p.x * 120.0, p.y * 120.0, p.z * 4.0)) * 0.4;
		col *= mix(1.0, 0.9 + 0.2 * br, brushed);
		rough += (br - 0.5) * 0.12 * brushed;
	}

	// --- livery ---
	float mk = markings;
	if (mk > 0.0) {
		float ax = abs(p.x);
		float side = sign(p.x);
		float up = smoothstep(0.55, 0.8, n.y);

		// radiator wings: dark anodized panels, white leading-edge band, orange tip blocks
		float ca = cos(radians(rad_dihedral));
		float sa = sin(radians(rad_dihedral));
		vec2 rq = vec2(ax, p.y) - rad_root;
		float rs = rq.x * ca + rq.y * sa;            // along span
		float rn = -rq.x * sa + rq.y * ca;           // off the mid plane
		float on_wing = step(abs(rn), 0.22) * step(0.30, rs) * step(rs, rad_span + 0.3);
		float tt = clamp(rs / rad_span, 0.0, 1.0);
		float zle = mix(rad_le.x, rad_le.y, tt);
		float le_band = 1.0 - smoothstep(0.42, 0.46, p.z - zle);
		float panel = on_wing * (1.0 - le_band) * step(rs, rad_span - 0.08);
		col = mix(col, radiator_color * (0.9 + 0.2 * pid), panel);
		metal = mix(metal, 0.55, panel);
		rough = mix(rough, 0.32, panel);
		float tipb = on_wing * step(rad_span - 0.12, rs);
		col = mix(col, accent_color, tipb);
		// thin orange stripe at the root fairing of the wing
		col = mix(col, accent_color, on_wing * band(rs, 0.42, 0.52) * (1.0 - le_band));

		// twin dorsal stripes (aft deck, both sides of the spine) with an angled front cut
		float st = band(ax, 1.48, 1.80) + band(ax, 1.90, 1.98);
		st *= step(-1.4 + (ax - 1.48) * 1.6, p.z) * step(p.z, 8.12) * up * step(1.0, p.y);
		col = mix(col, accent_color, clamp(st, 0.0, 1.0));

		// spine: dark walkway band with orange pinstripes, from the canopy rear to the tail
		float spine_top = step(1.72, p.y) * smoothstep(0.75, 0.9, n.y) * step(-2.6, p.z);
		col = mix(col, marking_dark * (0.95 + 0.1 * pid), spine_top * (1.0 - step(0.30, ax)));
		metal = mix(metal, 0.3, spine_top * (1.0 - step(0.30, ax)));
		col = mix(col, accent_color, spine_top * band(ax, 0.36, 0.41));

		// pods: dorsal band near the rear + hull number "09" on the outer flanks
		float on_pod = step(abs(ax - pod_x), 1.05) * step(-1.0, p.z);
		float podtop = on_pod * smoothstep(0.7, 0.9, n.y) * step(pod_top - 0.12, p.y) * step(p.y, pod_top + 0.1);
		col = mix(col, accent_color, podtop * (band(p.z, 6.3, 6.85) + band(p.z, 7.0, 7.12)));
		col = mix(col, marking_dark, podtop * band(p.z, 6.85, 7.0));
		if (ax > pod_x + 0.85 && n.x * side > 0.8 && p.y > -0.6 && p.y < 1.1) {
			vec2 uv = vec2(-(p.z - 4.2) * side, p.y - 0.30) / 0.30;
			uv.x += uv.y * 0.15;
			float num = digit(uv - vec2(-0.62, 0.0), 0) + digit(uv - vec2(0.62, 0.0), 9);
			col = mix(col, number_color, clamp(num, 0.0, 1.0));
			// small orange tag under the number
			col = mix(col, accent_color, band(uv.y, -1.55, -1.3) * band(uv.x, -1.05, 1.05));
		}

		// anti-glare panel ahead of the canopy + nose tip
		float ag = step(-9.6, p.z) * step(p.z, -7.75) * step(ax, 0.30 - (-p.z - 7.75) * 0.12) * smoothstep(0.5, 0.7, n.y);
		col = mix(col, marking_dark, ag);

		// flank pinstripe (upper hull facets, nose to shoulder)
		float flank = smoothstep(0.35, 0.6, an.x) * step(n.y, 0.85) * step(ax, 3.6) * step(-0.2, n.y);
		float pin = band(p.y, 0.50, 0.56) + band(p.y, 0.62, 0.65);
		pin *= step(-9.2, p.z) * step(p.z, -0.6);
		col = mix(col, accent_color, clamp(pin, 0.0, 1.0) * flank);

		// hazard frames on the belly: gear bays and the boarding ramp
		float belly = smoothstep(0.6, 0.85, -n.y);
		vec2 q = vec2(p.x, p.z);
		float hz = bay_frame(q, bay_front.xy, bay_front.z) + bay_frame(vec2(ax, p.z), bay_rear.xy, bay_rear.z);
		float rz = band(ax, ramp.x + 0.04, ramp.x + 0.14) * band(p.z, ramp.y - 0.12, ramp.z + 0.12)
				+ band(p.z, ramp.y - 0.14, ramp.y - 0.04) * step(ax, ramp.x + 0.14);
		float diag = step(0.5, fract((p.z + p.x) * 3.0));
		col = mix(col, mix(marking_dark, hazard_color, diag), clamp(hz + rz, 0.0, 1.0) * belly);

		// rear bulkhead: hazard chevrons framing the aux engine
		float rear = smoothstep(0.7, 0.9, n.z) * step(8.0, p.z);
		float rb = band(abs(p.x), 0.95, 1.05) * band(p.y, -0.25, 0.5);
		col = mix(col, mix(marking_dark, hazard_color, step(0.5, fract((p.y + abs(p.x)) * 4.0))), rb * rear);
	}

	// --- heat tint (titanium discoloration) ---
	if (heat_tint > 0.0) {
		float ht = smoothstep(heat_z0, heat_z1, p.z) * heat_tint;
		float k = ht + (vnoise(p * 3.0) - 0.5) * 0.25;
		vec3 straw = vec3(0.80, 0.62, 0.34);
		vec3 purple = vec3(0.42, 0.26, 0.55);
		vec3 blue = vec3(0.22, 0.34, 0.62);
		vec3 hc = mix(mix(col, straw, smoothstep(0.1, 0.4, k)), purple, smoothstep(0.4, 0.65, k));
		hc = mix(hc, blue, smoothstep(0.65, 0.9, k));
		col = mix(col, hc * (1.0 - 0.25 * smoothstep(0.85, 1.0, k)), clamp(ht * 1.4, 0.0, 1.0));
	}

	// --- wear on convex edges ---
	float wn = fbm(p * 6.0);
	float wear = smoothstep(0.35, 0.75, edge + (wn - 0.5) * 0.8) * edge_wear;
	col = mix(col, wear_color, wear);
	rough = mix(rough, 0.3, wear);
	metal = mix(metal, 1.0, wear * 0.8);
	coat *= 1.0 - wear;
	col += edge * edge_highlight * vec3(1.0);

	// --- grime ---
	float gn = fbm(p * 1.3 + vec3(0.0, 3.0, 0.0));
	float streak = vnoise(vec3(p.x * 9.0, p.y * 0.8, p.z * 9.0));
	float gm = clamp((1.0 - ao) * 1.4 + cavity * 0.9, 0.0, 1.0) * (0.55 + 0.45 * gn);
	gm += smoothstep(0.62, 0.95, streak) * 0.35 * smoothstep(0.3, -0.3, n.y) * gn;
	gm += smoothstep(0.55, 0.9, gn) * 0.10;
	gm = clamp(gm * grime, 0.0, 1.0);
	col = mix(col, col * grime_color * 2.2, gm);
	rough = mix(rough, 0.75, gm * 0.6);
	coat *= 1.0 - gm;
	// exhaust soot: only right at the engine exits
	float st = smoothstep(7.9, 8.6, p.z) * soot * (0.5 + 0.5 * fbm(p * 2.5)) * (1.0 - smoothstep(0.2, 0.7, n.y));
	col = mix(col, vec3(0.05), st * 0.6);
	rough = mix(rough, 0.7, st * 0.5);

	// --- panel seams ---
	col *= 1.0 - line * panel_line_dark;
	col *= 1.0 + lip * 0.06;
	col *= 1.0 - rivet * 0.35;
	rough = mix(rough, 0.8, line * 0.6);

	ALBEDO = clamp(col, 0.0, 1.0);
	METALLIC = clamp(metal, 0.0, 1.0);
	ROUGHNESS = clamp(rough, 0.04, 1.0);
	SPECULAR = specular;
	CLEARCOAT = clamp(coat, 0.0, 1.0);
	CLEARCOAT_ROUGHNESS = clearcoat_roughness;
	AO = mix(1.0, ao, ao_strength);
	AO_LIGHT_AFFECT = 0.3;

	float h = -line * panel_groove_depth + rivet * 0.0015;
	NORMAL = mix(NORMAL, bump_normal(NORMAL, VERTEX, h), vis);
}
