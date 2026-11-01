// Bakes the planetary weather map (equirect: u = longitude, v = colatitude) once into a
// SubViewport texture: R = coverage, G = cloud type/height. See clouds_common.gdshaderinc.
shader_type canvas_item;
render_mode unshaded;

#include "res://shaders/include/clouds_common.gdshaderinc"

void fragment() {
	float lon = (UV.x - 0.5) * 6.2831853;
	float colat = UV.y * 3.14159265;
	vec3 dir = vec3(sin(colat) * cos(lon), cos(colat), sin(colat) * sin(lon));
	vec2 w = cloud_weather_procedural(dir);
	COLOR = vec4(w, 0.0, 1.0);
}
