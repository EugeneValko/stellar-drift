// Planetary rings on a flat annulus (planet-local XZ plane). Procedural radial bands/gaps with
// band-limited ringlets, view-dependent optical depth, lit side vs. back-lit forward scattering,
// soft planet shadow. Transparent, double-sided.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled;

#include "res://shaders/include/sun_globals.gdshaderinc"
#include "res://shaders/include/rings_common.gdshaderinc"

uniform float ring_planet_radius = 300000.0;
uniform float ring_brightness = 1.0;
uniform float ring_forward_scatter = 1.0;

varying vec3 v_local;

void vertex() {
	v_local = VERTEX;
}

void fragment() {
	float r = length(v_local.xz);
	float fw = max(fwidth(r), 1e-3);
	float tau_n = ring_density(r, fw);
	if (tau_n <= 0.001) discard;
	vec3 albedo = ring_albedo(r, fw);

	vec3 center = NODE_POSITION_WORLD;
	vec3 up = normalize(MODEL_MATRIX[1].xyz);
	vec3 wpos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 p = (wpos - center) / sd_node_scale(MODEL_MATRIX);   // body units (scaled space)
	vec3 V = normalize(CAMERA_POSITION_WORLD - wpos);
	vec3 L = sd_sun_dir();
	float nv = abs(dot(up, V));
	float nl = dot(up, L);

	// view-dependent opacity (slant optical depth)
	float tau = -log(1.0 - tau_n);
	float alpha = 1.0 - exp(-tau / max(nv, 0.02));

	// planet shadow (soft): sun ray from p against the planet sphere
	float b = dot(p, L);
	float sh = 1.0;
	if (b < 0.0) {
		float dperp = length(p - b * L);
		sh = smoothstep(ring_planet_radius * 0.985, ring_planet_radius * 1.01, dperp);
	}
	// sun illuminates the ring side facing it; light diffuses through thin parts
	float lit_side = sign(dot(up, V)) * sign(nl);   // +1 viewer on lit side
	float mu0 = abs(nl);
	vec3 Esun = sun_color.rgb * sun_intensity;
	float refl = mu0 / (mu0 + nv + 0.05) * 2.0;                 // Lommel-Seeliger-ish
	vec3 c_front = albedo * refl * (1.0 - exp(-tau / max(mu0, 0.02)));
	// back side: diffuse transmission + strong forward scattering of small particles
	float mu = dot(-V, L);
	float fwd = sd_hg(mu, 0.75) * 4.0 * SD_PI;
	vec3 c_back = albedo * (exp(-tau) * (1.0 - exp(-tau)) * 2.2) * (0.3 + fwd * ring_forward_scatter * 0.35 * exp(-tau))
		* mix(vec3(1.0), vec3(1.0, 0.92, 0.8), 0.5);
	vec3 col = (lit_side > 0.0 ? c_front : c_back) * Esun * sh * ring_brightness;
	// faint planetshine/ambient on the dark side
	col += albedo * 0.004;
	// wave 4: fine dust (thin rings, gaps, the F ring) forward-scatters strongly when the sun is
	// behind the rings: a narrow bright halo that makes the faint parts glow. Added as light
	// (divided by alpha so the mix blend does not hide it in the transparent parts).
	float dusty = 1.0 - smoothstep(0.05, 0.6, tau_n);
	// dense rings (big particles, opaque) stay dark when back-lit; dusty thin parts glow
	float glow_a = (1.0 - exp(-tau * 0.8 / max(nv, 0.03))) * (0.02 + dusty * dusty);
	vec3 dust = vec3(1.0, 0.9, 0.78) * sd_hg(mu, 0.9) * 4.0 * SD_PI * 0.12 * glow_a
		* ring_forward_scatter * Esun * sh * ring_brightness;
	float a_out = max(alpha, 0.02);
	col = (col * alpha + dust) / max(a_out, 1e-3);
	ALBEDO = col;
	ALPHA = a_out;
}
