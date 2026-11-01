class_name CloudNoise
extends RefCounted
## Procedural tileable 3D noise textures shared by clouds, ocean foam etc. Generated once
## (FastNoiseLite, ~0.4 s total) and cached for the whole session.

static var _shape: ImageTexture3D
static var _detail: ImageTexture3D


## 128^3 Perlin fbm (cloud shapes, weather). Tiles with period 1 in texture space.
static func shape() -> ImageTexture3D:
	if _shape == null:
		var n := FastNoiseLite.new()
		n.seed = 1337
		n.noise_type = FastNoiseLite.TYPE_PERLIN
		n.frequency = 1.0 / 20.0
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = 4
		n.fractal_gain = 0.5
		_shape = _make(n, 128, false)
	return _shape


## 64^3 inverted cellular (billowy cloud detail, foam cells).
static func detail() -> ImageTexture3D:
	if _detail == null:
		var n := FastNoiseLite.new()
		n.seed = 4242
		n.noise_type = FastNoiseLite.TYPE_CELLULAR
		n.frequency = 1.0 / 10.0
		n.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
		n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = 2
		_detail = _make(n, 64, true)
	return _detail


static func _make(n: FastNoiseLite, size: int, invert: bool) -> ImageTexture3D:
	var imgs: Array[Image] = n.get_seamless_image_3d(size, size, size, invert, 0.1, true)
	var tex := ImageTexture3D.new()
	tex.create(imgs[0].get_format(), size, size, size, false, imgs)
	return tex
