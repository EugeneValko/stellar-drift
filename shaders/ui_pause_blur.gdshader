shader_type canvas_item;
// Pause menu backdrop: frosted (mip-blurred) and darkened game view, darker toward the left
// where the menu column sits, soft vignette.
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 1.0;
uniform float lod = 3.2;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 c = textureLod(screen_tex, uv, lod * amount).rgb * 0.6
		+ textureLod(screen_tex, uv + vec2(0.004, 0.003), lod * amount + 0.6).rgb * 0.4;
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(lum) * vec3(0.85, 0.95, 1.1), 0.35 * amount);
	float left = 1.0 - smoothstep(0.0, 0.62, uv.x);
	float vig = smoothstep(1.25, 0.35, length((uv - 0.5) * vec2(1.6, 1.0)));
	c *= mix(1.0, 0.38 + 0.25 * vig - 0.18 * left, amount);
	COLOR = vec4(c, 1.0);
}
