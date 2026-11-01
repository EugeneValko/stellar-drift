// Full-screen star glare: occlusion-aware god rays (radial blur of the star's bright pixels
// toward the star), starburst, anamorphic streak, lens ghosts and halo ring.
// Drawn by a ColorRect on a CanvasLayer (src/space/star.gd) over the tonemapped 3D image.
// Visibility is measured from the screen itself: taps inside the projected star disc -> if a
// planet / ship covers the disc, or the star leaves the frame, everything fades out smoothly.
shader_type canvas_item;
render_mode unshaded, blend_add;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform vec2 star_uv = vec2(0.5);          // projected centre (may be off-screen)
uniform float star_radius_px = 20.0;       // projected disc radius in pixels
uniform float in_front = 1.0;              // 0 when the star is behind the camera
uniform float intensity : hint_range(0.0, 4.0) = 1.0;
uniform vec3 tint = vec3(1.0, 0.93, 0.82);
uniform float time = 0.0;

group_uniforms god_rays;
uniform int ray_samples : hint_range(8, 128) = 40;
uniform float ray_strength : hint_range(0.0, 4.0) = 0.55;
uniform float ray_length : hint_range(0.05, 1.0) = 0.55;   // fraction of the way to the star
uniform float ray_decay : hint_range(0.8, 1.0) = 0.965;
uniform float ray_threshold : hint_range(0.0, 1.0) = 0.72;
uniform float ray_source_radius : hint_range(1.0, 8.0) = 2.4; // in star radii: only the star feeds rays

group_uniforms lens;
uniform float starburst_strength : hint_range(0.0, 4.0) = 0.7;
uniform float streak_strength : hint_range(0.0, 4.0) = 0.35;
uniform float ghost_strength : hint_range(0.0, 4.0) = 0.7;
uniform float halo_strength : hint_range(0.0, 4.0) = 0.18;
uniform float glare_strength : hint_range(0.0, 4.0) = 0.5;
group_uniforms;

float lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

float hash11(float x) { return fract(sin(x * 127.1) * 43758.5453); }

// angular noise for the starburst: sum of random thin spikes
float burst(float ang, float r_norm) {
	float s = 0.0;
	for (int i = 0; i < 3; i++) {
		float k = float(i);
		float n = 24.0 + 16.0 * k;
		float a = ang / 6.2831853 * n + time * 0.01 * (k + 1.0);
		float id = floor(a);
		float f = fract(a) - 0.5;
		float h = hash11(id + 17.0 * k);
		float w = mix(0.04, 0.16, h);
		s += exp(-f * f / (w * w)) * mix(0.3, 1.0, hash11(id * 3.1 + k)) / (1.0 + k);
	}
	return s;
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = res.x / res.y;
	vec2 uv = SCREEN_UV;
	vec2 S = star_uv;
	float rpx = max(star_radius_px, 1.5);

	// ---- visibility of the star disc (same value for every pixel)
	float vis = 0.0;
	float wsum = 0.0;
	for (int i = 0; i < 13; i++) {
		vec2 o = vec2(0.0);
		if (i > 0) {
			float ring = i <= 6 ? 0.38 : 0.72;
			float ang = float(i) * 1.0471976 + (i > 6 ? 0.5236 : 0.0);
			o = vec2(cos(ang), sin(ang)) * ring * rpx;
		}
		vec2 suv = S + o * SCREEN_PIXEL_SIZE;
		float inside = step(0.0, suv.x) * step(suv.x, 1.0) * step(0.0, suv.y) * step(suv.y, 1.0);
		float l = lum(textureLod(screen_tex, clamp(suv, 0.0, 1.0), 0.0).rgb);
		vis += inside * smoothstep(0.55, 0.9, l);
		wsum += 1.0;
	}
	vis = vis / wsum * in_front;
	// big disc (close-up) -> the whole screen is the star; glare would only wash it out
	float size_fade = 1.0 - smoothstep(0.025, 0.16, rpx / res.y);
	float amount = vis * intensity;
	if (amount < 0.002) {
		COLOR = vec4(0.0);
	} else {
		vec2 d = uv - S;
		vec2 dp = d * res;                     // pixels from star
		float r = length(dp);
		float rn = r / res.y;

		// ---- god rays: march from the pixel toward the star, gather bright star pixels
		vec3 rays = vec3(0.0);
		{
			vec2 stepv = -d * ray_length / float(ray_samples);
			vec2 p = uv;
			float w = 1.0;
			float jitter = fract(sin(dot(uv * res, vec2(12.9898, 78.233))) * 43758.5453);
			p += stepv * jitter;
			for (int i = 0; i < ray_samples; i++) {
				p += stepv;
				vec3 c = textureLod(screen_tex, p, 0.0).rgb;
				float src = exp(-pow(length((p - S) * res) / (rpx * ray_source_radius), 2.0));
				rays += max(c - ray_threshold, vec3(0.0)) * src * w;
				w *= ray_decay;
			}
			rays *= ray_strength * 4.0 / float(ray_samples);
		}

		// ---- glare around the star: soft core + starburst spikes
		float ang = atan(dp.y, dp.x);
		float rr = r / (rpx * 3.0 + res.y * 0.01);
		float glare = exp(-rr * 1.2) * 0.35 + exp(-rn * 9.0) * 0.12;
		float sb = burst(ang, rn) * exp(-rn * 5.5) * (1.0 - exp(-rr * 2.0));
		vec3 col = tint * (glare * glare_strength + sb * starburst_strength * 0.35);

		// ---- anamorphic horizontal streak
		float sy = dp.y / res.y;
		float sx = dp.x / res.y;
		float streak = exp(-abs(sy) * 260.0) * exp(-abs(sx) * 2.2);
		col += vec3(0.55, 0.7, 1.0) * streak * streak_strength;

		// ---- lens ghosts along the axis star -> screen centre -> mirror
		vec2 axis = vec2(0.5) - S;
		float edge_boost = 0.6 + 0.8 * clamp(length(axis) * 2.0, 0.0, 1.0);
		vec3 ghosts = vec3(0.0);
		for (int i = 0; i < 6; i++) {
			float fi = float(i);
			float k = fi == 0.0 ? 0.35 : (fi == 1.0 ? 0.62 : (fi == 2.0 ? 1.18 : (fi == 3.0 ? 1.45 : (fi == 4.0 ? 1.9 : 2.35))));
			float gr = (fi == 0.0 ? 0.035 : (fi == 1.0 ? 0.06 : (fi == 2.0 ? 0.022 : (fi == 3.0 ? 0.09 : (fi == 4.0 ? 0.045 : 0.13)))));
			vec2 gp = S + axis * k;
			vec2 gd = (uv - gp) * vec2(aspect, 1.0);
			// hexagonal aperture shape
			vec2 ag = abs(gd);
			float hexd = max(ag.x * 0.866 + ag.y * 0.5, ag.y);
			float disc = 1.0 - smoothstep(gr * 0.82, gr, hexd);
			float ringv = smoothstep(gr * 0.7, gr * 0.95, hexd) * (1.0 - smoothstep(gr * 0.95, gr * 1.05, hexd));
			vec3 gc = fi == 0.0 ? vec3(0.4, 1.0, 0.6) : (fi == 1.0 ? vec3(1.0, 0.55, 0.25) : (fi == 2.0 ? vec3(0.5, 0.6, 1.0) : (fi == 3.0 ? vec3(0.9, 0.4, 1.0) : (fi == 4.0 ? vec3(0.3, 0.9, 1.0) : vec3(1.0, 0.8, 0.4)))));
			float gi = (fi == 3.0 || fi == 5.0) ? 0.35 : 1.0;
			ghosts += gc * (disc * 0.06 + ringv * 0.05) * gi;
		}
		col += ghosts * ghost_strength * edge_boost;

		// ---- halo ring around the star with chromatic fringes
		float hr = 0.42;
		float hd = length(d * vec2(aspect, 1.0));
		vec3 halo = vec3(
			exp(-pow((hd - hr * 1.00) / 0.012, 2.0)),
			exp(-pow((hd - hr * 0.985) / 0.012, 2.0)),
			exp(-pow((hd - hr * 0.97) / 0.012, 2.0)));
		col += halo * halo_strength * 0.12;

		col = col * size_fade + rays * mix(0.12, 1.0, size_fade);
		COLOR = vec4(col * amount, 1.0);
	}
}
