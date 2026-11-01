// Bakes the expensive low-frequency space backdrop into a 3x2 cube atlas (equi-angular faces).
// Rendered once at startup into an HDR SubViewport by src/space/space_sky.gd, then sampled by
// shaders/space_sky.gdshader. Texel centres on tile borders lie exactly on the cube edges, so
// bilinear filtering is seamless across faces (no border padding needed).
shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://shaders/space_noise.gdshaderinc"
#include "res://shaders/space_backdrop.gdshaderinc"

uniform float face_size = 1024.0;

void fragment() {
	vec2 px = UV * vec2(3.0, 2.0) * face_size;
	vec2 tile = clamp(floor(px / face_size), vec2(0.0), vec2(2.0, 1.0));
	vec2 local = px - tile * face_size;
	int face = int(tile.x) + int(tile.y) * 3;
	vec2 st = clamp((local - 0.5) / (face_size - 1.0) * 2.0 - 1.0, -1.0, 1.0);
	vec3 d = sn_face_to_dir(face, st);
	float texel_cells = faint_star_grid / (face_size - 1.0);
	COLOR = sb_backdrop(d, face, st, texel_cells);
}
