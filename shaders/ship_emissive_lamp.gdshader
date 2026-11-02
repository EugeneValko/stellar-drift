shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_schlick_ggx;

// Lamp lenses (Lamp slot): floodlights, deck/bay lamps, landing light. `lit` (0..1, driven by ShipVisual from
// the gear state) scales the HDR emission; a faceted reflector pattern keeps the lens readable when dim.
uniform vec3 color : source_color = vec3(1.0, 0.92, 0.80);
uniform float energy = 6.0;
uniform float lit : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	float nv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float core = 0.35 + 0.65 * pow(nv, 2.0);
	ALBEDO = color * 0.35;
	ROUGHNESS = 0.08;
	METALLIC = 0.0;
	SPECULAR = 0.8;
	EMISSION = color * energy * core * mix(0.05, 1.0, lit);
}
