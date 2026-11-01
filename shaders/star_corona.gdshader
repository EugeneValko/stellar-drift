// Star corona + chromosphere rim on a camera-facing quad centred on the star.
// Brightness is a function of the true impact parameter b of each view ray (closest approach to
// the star centre), so the corona is correct from 15 000 km and from 600 km alike; the quad is
// just a canvas. Streamers / helmet petals are noise on the direction of closest approach,
// sampled with a log-radius coordinate so they stretch radially. Additive, HDR.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

#include "res://shaders/space_noise.gdshaderinc"

uniform vec3 star_color = vec3(1.0, 0.93, 0.84);
uniform float star_radius = 400000.0;
uniform float extent = 7.0;                  // quad half-size in radii
uniform float intensity : hint_range(0.0, 20.0) = 1.0;
uniform float time_scale = 1.0;
uniform int seed = 1;
uniform float inner_glow : hint_range(0.0, 10.0) = 2.2;
uniform float streamer_strength : hint_range(0.0, 4.0) = 1.0;
uniform float chromosphere : hint_range(0.0, 10.0) = 2.5;
uniform vec3 chromosphere_color = vec3(1.0, 0.32, 0.22);

varying vec3 v_world;

void vertex() {
	// spherical billboard, scaled to the corona extent
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	VERTEX *= star_radius * extent;
	v_world = (INV_VIEW_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0))).xyz;
}

void fragment() {
	float t = TIME * time_scale;
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 c = NODE_POSITION_WORLD;
	vec3 dir = normalize(v_world - cam);
	vec3 oc = c - cam;
	float tca = dot(oc, dir);
	vec3 qv = (cam + dir * tca) - c;
	float b = length(qv) / star_radius;
	if (tca < 0.0 || b < 0.995) {
		discard;
	}
	vec3 u = qv / max(length(qv), 1e-3);
	float h = b - 1.0;
	float lb = log(b);
	vec3 so = (sn_hash3i(ivec3(seed, 31, 9)) - 0.5) * 200.0;

	// slow drift of the whole pattern
	vec3 ud = u + vec3(sin(t * 0.013), 0.0, cos(t * 0.011)) * 0.05;

	// large helmet streamers (few broad petals)
	float helmet = sn_fbm(ud * 1.8 + so, 3, 0.5) * 0.5 + 0.5;
	helmet = pow(smoothstep(0.3, 0.85, helmet), 2.0);
	// radial streamer rays: angular noise, stretched along log-radius
	float rays = sn_fbm(ud * 9.0 + so + vec3(lb * 0.9, -lb * 0.6, t * 0.02), 5, 0.6) * 0.5 + 0.5;
	float fine = sn_fbm(ud * 38.0 + so + vec3(lb * 2.0, t * 0.05, -lb), 3, 0.55) * 0.5 + 0.5;
	float streak = mix(rays, fine, 0.35);
	streak = pow(streak, 2.2) * 2.4;

	// radial falloffs
	float k_inner = exp(-h / 0.045);
	float k_mid = exp(-h / 0.32);
	float k_out = pow(b, -3.0) * smoothstep(extent, extent * 0.55, b);

	float cor = inner_glow * k_inner * (0.7 + 0.3 * streak);
	cor += k_mid * (0.25 + 0.75 * streak) * (0.4 + 0.9 * helmet) * streamer_strength;
	cor += k_out * (0.2 + 1.6 * helmet * streak) * streamer_strength;

	// colour: warm white close to the limb, pearly / slightly cool further out
	vec3 col_in = star_color * vec3(1.0, 0.92, 0.80);
	vec3 col_out = vec3(0.85, 0.90, 1.0);
	vec3 col = mix(col_in, col_out, smoothstep(0.02, 0.8, h)) * cor;

	// chromosphere: thin pink-red rim with spicule texture
	float spic = sn_gnoise(ud * 260.0 + so + vec3(0.0, t * 0.3, 0.0)) * 0.5 + 0.5;
	float chrom = exp(-h / 0.006) * (0.6 + 0.8 * spic);
	col += chromosphere_color * chromosphere * chrom;

	// soft fade at the quad border
	float edge = 1.0 - smoothstep(extent * 0.75, extent, b);
	ALBEDO = col * intensity * edge;
}
