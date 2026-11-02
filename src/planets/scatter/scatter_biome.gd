class_name ScatterBiome
extends RefCounted
## CPU mirror of the biome logic in shaders/planet_terrain.gdshader, so scatter placement agrees with
## what the terrain paints (forest where the ground is forest-dark, no grass on snow / rock / beach).
##
## The shader mixes vertex data (height, moisture, rock mask) with the procedural detail textures from
## TerrainTextures; the orbit-scale "macro" and the 2 km "n2" noise are reproduced here by sampling the
## same noise image on the CPU. Distance-banded terms (n1, nband) are not reproducible (they depend on
## camera distance) and are treated as their mean.
##
## Thread-safety: read-only after construction (generator + packed image data) -> evaluate() may run on
## WorkerThreadPool tasks concurrently.

const ATTRS: Array[String] = ["height", "slope", "moist", "forest", "snow", "rock", "desert", "beach",
	"lava", "ice", "lat", "river", "temp", "savanna", "tundra", "alien_b", "alien_c", "scree"]
const A_HEIGHT := 0
const A_SLOPE := 1
const A_MOIST := 2
const A_FOREST := 3
const A_SNOW := 4
const A_ROCK := 5
const A_DESERT := 6
const A_BEACH := 7
const A_LAVA := 8
const A_ICE := 9
const A_LAT := 10
const A_RIVER := 11
const A_TEMP := 12
const A_SAVANNA := 13
const A_TUNDRA := 14
const A_ALIEN_B := 15
const A_ALIEN_C := 16
const A_SCREE := 17
const COUNT := 18

var gen: TerrainGenerator
var radius := 1.0
var base_level := 0.0
var has_ocean := false
var snow_line := 4000.0
var polar_snow := 0.75
var beach_width := 25.0
var is_ice := false
var has_lava := false
var alien_forest := 0.0
var earthlike := true

var _tex := PackedByteArray()
var _size := 512


func _init(generator: TerrainGenerator, cfg: PlanetConfig) -> void:
	gen = generator
	radius = cfg.radius
	base_level = cfg.get_base_level()
	has_ocean = cfg.has_ocean_surface()
	snow_line = cfg.snow_line
	polar_snow = cfg.polar_snow
	beach_width = cfg.beach_width
	is_ice = cfg.surface_style == 3 or cfg.type == PlanetConfig.PlanetType.ICE
	has_lava = cfg.lava_intensity > 0.0
	alien_forest = cfg.alien_forest
	earthlike = cfg.surface_style == 0
	_tex = _noise_data()


static var _noise_cache := PackedByteArray()


## RGBA8 level-0 pixels of TerrainTextures "noise" (r = fbm, g = cellular, b = ridged, a = fine).
static func _noise_data() -> PackedByteArray:
	if _noise_cache.is_empty():
		var img: Image = TerrainTextures.get_textures()["noise"].get_image()
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.clear_mipmaps()
		img.convert(Image.FORMAT_RGBA8)
		_noise_cache = img.get_data()
	return _noise_cache


## Bilinear, wrapping texture lookup like texture(tex_noise, uv) (channel 0..3).
func tex(u: float, v: float, ch: int) -> float:
	var s := _size
	var x := u * s - 0.5
	var y := v * s - 0.5
	var fx := floorf(x)
	var fy := floorf(y)
	var tx := x - fx
	var ty := y - fy
	var m := s - 1
	var x0 := int(fx) & m
	var y0 := int(fy) & m
	var x1 := (x0 + 1) & m
	var y1 := (y0 + 1) & m
	var a := _tex[(y0 * s + x0) * 4 + ch]
	var b := _tex[(y0 * s + x1) * 4 + ch]
	var c := _tex[(y1 * s + x0) * 4 + ch]
	var d := _tex[(y1 * s + x1) * 4 + ch]
	return (lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty)) / 255.0


static func tri_w(n: Vector3) -> Vector3:
	var w := Vector3(pow(absf(n.x), 8.0), pow(absf(n.y), 8.0), pow(absf(n.z), 8.0))
	return w / (w.x + w.y + w.z)


## Triplanar lookup like tri() in the terrain shader.
func tri(p: Vector3, w: Vector3, ch: int) -> float:
	var r := 0.0
	if w.x > 0.01:
		r += tex(p.z, p.y, ch) * w.x
	if w.y > 0.01:
		r += tex(p.x, p.z, ch) * w.y
	if w.z > 0.01:
		r += tex(p.x, p.y, ch) * w.z
	return r


## Biome attributes for a unit direction `d`, terrain height `h` (m above radius, as returned by
## TerrainGenerator.sample().x), rock / lava masks from sample(), and the surface normal `n`.
## Writes COUNT values into `out` at `offset`.
func evaluate_into(out: PackedFloat32Array, offset: int, d: Vector3, h: float, rock_mask: float,
		lava_mask: float, n: Vector3) -> void:
	var hb := h - base_level
	var lat := absf(d.y)
	var slope := 1.0 - clampf(n.dot(d), 0.0, 1.0)
	var wd := tri_w(d)
	var pm1 := d * (radius / 24000.0)
	var pm2 := d * (radius / 90000.0)
	var macro := tri(pm1, wd, 0) * 0.6 + tri(pm2, wd, 0) * 0.4 - 0.5
	var p := d * (radius + h) / 2048.0
	var w := tri_w(n)
	var n2 := tri(p, w, 0) - 0.5
	var moist := clampf(gen.moisture(d) + macro * 0.35 + n2 * 0.25, 0.0, 1.0)

	var snow_h := snow_line * (1.0 - polar_snow * lat * lat) + (macro + n2) * snow_line * 0.15
	var snow_in := hb - slope * 900.0
	var snow := smoothstep(snow_h - 180.0, snow_h + 180.0, snow_in)
	var rock_slope := smoothstep(0.13, 0.3, slope + n2 * 0.1)
	var alpine := smoothstep(snow_h * 0.5, snow_h * 0.75, hb + n2 * 400.0)
	var rock := maxf(rock_slope, smoothstep(0.35, 0.85, rock_mask + n2 * 0.4) * (1.0 - snow * 0.7))
	rock = maxf(rock, alpine * smoothstep(0.35, 0.65, 0.5 + slope * 2.0) * (1.0 - snow))
	snow *= 1.0 - smoothstep(0.2, 0.36, slope)
	if polar_snow > 0.01:
		var cap := smoothstep(0.9, 0.95, lat + macro * 0.12 + n2 * 0.06)
		snow = maxf(snow, cap * (1.0 - rock_slope * 0.6))
	var temp := 1.0 - lat * lat * 1.3 - maxf(hb, 0.0) / maxf(snow_line, 1.0) * 0.6 + macro * 0.3 + n2 * 0.15
	var desert := smoothstep(0.32, 0.12, moist + n2 * 0.1)
	var savanna := smoothstep(0.2, 0.32, moist + n2 * 0.1) * smoothstep(0.5, 0.38, moist + n2 * 0.1) \
		* smoothstep(0.45, 0.65, temp)
	var tundra := smoothstep(0.4, 0.2, temp) * (1.0 - snow)
	if not earthlike:
		savanna = 0.0   # Earth-like climate zones only (shader: surface_style != 0)
		tundra = 0.0
	var forest := smoothstep(0.5, 0.7, moist + macro * 0.2) \
		* (1.0 - smoothstep(snow_h * 0.45, snow_h * 0.7, hb)) * (1.0 - smoothstep(0.25, 0.4, slope))
	forest *= 1.0 - tundra * 0.65
	var alien_b := 0.0
	var alien_c := 0.0
	if alien_forest > 0.0:
		alien_b = smoothstep(0.72, 0.8, tri(pm1, wd, 2) + n2 * 0.1) * alien_forest
		alien_c = smoothstep(0.36, 0.28, tri(pm2, wd, 3) + n2 * 0.1) * alien_forest * (1.0 - alien_b)
	# scree aprons (mean of the shader's noise-broken mask; curvature is not known here)
	var scree := smoothstep(0.06, 0.14, slope) * (1.0 - rock_slope) \
		* clampf(alpine * 1.2 + rock_mask * 1.4, 0.0, 1.0) * (1.0 - snow)
	var beach := 0.0
	if has_ocean:
		var bw := beach_width * (1.0 + n2 * 1.2)
		beach = (1.0 - smoothstep(bw * 0.6, bw * 1.4, hb)) * (1.0 - smoothstep(0.15, 0.3, slope))
		if hb < 0.0:
			beach = 1.0
	var ice := 0.0
	if is_ice:
		ice = smoothstep(0.05, 0.6, tri(p, w, 2) + macro) * (1.0 - rock) * (1.0 - smoothstep(0.1, 0.25, slope))
	out[offset] = hb
	out[offset + 1] = slope
	out[offset + 2] = moist
	out[offset + 3] = forest
	out[offset + 4] = snow
	out[offset + 5] = rock
	out[offset + 6] = desert
	out[offset + 7] = beach
	out[offset + 8] = lava_mask if has_lava else 0.0
	out[offset + 9] = ice
	out[offset + 10] = lat
	out[offset + 11] = 0.0 if has_lava else lava_mask
	out[offset + 12] = temp
	out[offset + 13] = savanna
	out[offset + 14] = tundra
	out[offset + 15] = alien_b
	out[offset + 16] = alien_c
	out[offset + 17] = scree


## Convenience (main thread / tools): attributes at a direction, normal from 3 height samples.
func evaluate(d: Vector3, e := 2.0) -> Dictionary:
	d = d.normalized()
	var s := gen.sample(d, 0.4)
	var t1 := d.cross(Vector3.UP if absf(d.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := d.cross(t1)
	var da := (d + t1 * (e / radius)).normalized()
	var db := (d + t2 * (e / radius)).normalized()
	var p0 := d * (radius + s.x)
	var pa := da * (radius + gen.get_height(da))
	var pb := db * (radius + gen.get_height(db))
	var n := (pa - p0).cross(pb - p0).normalized()
	if n.dot(d) < 0.0:
		n = -n
	var out := PackedFloat32Array()
	out.resize(COUNT)
	evaluate_into(out, 0, d, s.x, s.y, s.z, n)
	var res := {}
	for i in COUNT:
		res[ATTRS[i]] = out[i]
	return res
