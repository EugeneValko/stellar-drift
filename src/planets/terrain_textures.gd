class_name TerrainTextures
extends RefCounted
## Procedural, seamless detail textures for the terrain shader (generated once, cached).
##
##   noise  (RGBA8): r = fbm, g = cellular F1 (pebbles/cracks), b = ridged fbm, a = fine fbm
##   normal (RGBA8): normal map of a soft fbm (soil, snow, sand)
##   rock   (RGBA8): normal map of ridged+cellular (rock, cliffs)
## All tiles are seamless; the shader samples them at power-of-two tile sizes so they repeat
## exactly inside TerrainGenerator.DETAIL_PERIOD (precision-safe detail coordinates).

const SIZE := 512

static var _cache: Dictionary = {}


static func get_textures() -> Dictionary:
	if _cache.is_empty():
		var t0 := Time.get_ticks_msec()
		_cache = _build()
		print("[terrain] detail textures generated in %d ms" % (Time.get_ticks_msec() - t0))
	return _cache


static func _noise(sd: int, type: FastNoiseLite.NoiseType, freq: float, octaves: int,
		fractal := FastNoiseLite.FRACTAL_FBM) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = sd
	n.noise_type = type
	n.frequency = freq
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	n.fractal_gain = 0.5
	n.fractal_lacunarity = 2.0
	return n


static func _gray(n: FastNoiseLite) -> PackedByteArray:
	var img := n.get_seamless_image(SIZE, SIZE, false, false, 0.15, true)
	img.convert(Image.FORMAT_L8)
	return img.get_data()


static func _build() -> Dictionary:
	var fbm := _gray(_noise(11, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1.0 / 96.0, 6))
	var cell_n := _noise(12, FastNoiseLite.TYPE_CELLULAR, 1.0 / 40.0, 2)
	cell_n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	var cell := _gray(cell_n)
	var ridged := _gray(_noise(13, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1.0 / 128.0, 6,
		FastNoiseLite.FRACTAL_RIDGED))
	var fine := _gray(_noise(14, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1.0 / 24.0, 4))
	var soft := _gray(_noise(15, FastNoiseLite.TYPE_SIMPLEX_SMOOTH, 1.0 / 64.0, 7))

	var px := SIZE * SIZE
	var rgba := PackedByteArray()
	rgba.resize(px * 4)
	var rock_h := PackedFloat32Array()
	rock_h.resize(px)
	var soft_h := PackedFloat32Array()
	soft_h.resize(px)
	for i in px:
		var q := i * 4
		rgba[q] = fbm[i]
		rgba[q + 1] = cell[i]
		rgba[q + 2] = ridged[i]
		rgba[q + 3] = fine[i]
		rock_h[i] = float(ridged[i]) * 0.75 + float(fbm[i]) * 0.3 + float(fine[i]) * 0.3
		soft_h[i] = float(soft[i]) * 0.8 + float(fine[i]) * 0.35
	var noise_img := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, rgba)
	noise_img.generate_mipmaps()
	return {
		"noise": ImageTexture.create_from_image(noise_img),
		"normal": ImageTexture.create_from_image(_normal_map(soft_h, 3.0 / 255.0)),
		"rock": ImageTexture.create_from_image(_normal_map(rock_h, 4.0 / 255.0)),
	}


## Wrapping central-difference normal map (tangent space, +Z up), with mipmaps.
static func _normal_map(h: PackedFloat32Array, strength: float) -> Image:
	var data := PackedByteArray()
	data.resize(SIZE * SIZE * 4)
	var m := SIZE - 1
	for y in SIZE:
		var yu := ((y + 1) & m) * SIZE
		var yd := ((y - 1) & m) * SIZE
		var yr := y * SIZE
		for x in SIZE:
			var dx := (h[yr + ((x + 1) & m)] - h[yr + ((x - 1) & m)]) * strength
			var dy := (h[yu + x] - h[yd + x]) * strength
			var inv := 1.0 / sqrt(dx * dx + dy * dy + 1.0)
			var q := (yr + x) * 4
			data[q] = int((-dx * inv * 0.5 + 0.5) * 255.0)
			data[q + 1] = int((-dy * inv * 0.5 + 0.5) * 255.0)
			data[q + 2] = int((inv * 0.5 + 0.5) * 255.0)
			data[q + 3] = 255
	var img := Image.create_from_data(SIZE, SIZE, false, Image.FORMAT_RGBA8, data)
	img.generate_mipmaps()
	return img
