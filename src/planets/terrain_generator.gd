class_name TerrainGenerator
extends RefCounted
## Deterministic planet height function + chunk mesh builder.
##
## Thread-safety: after construction the generator is read-only; `sample()` and
## `build_chunk()` may be called from any number of WorkerThreadPool tasks at once
## (FastNoiseLite::get_noise_* is const).
##
## Vertex layout produced by build_chunk() (consumed by shaders/planet_terrain.gdshader):
##   VERTEX   position relative to the chunk origin (planet-local orientation)
##   NORMAL   smooth normal (computed from a 1-sample apron, so it is continuous across chunks)
##   COLOR    r = rock exposure, g = lava mask (river / water mask on planets without lava),
##            b = crater ejecta + bright rays, a = curvature (0.5 = flat)
##   CUSTOM0  xyz = detail coords (planet-local position mod DETAIL_PERIOD, continuous inside
##            a chunk and periodic across chunks), w = height above radius (m)
##   CUSTOM1  xyz = unit direction from planet centre, w = moisture (0..1)
##   CUSTOM2  xyz = morph delta for odd edge vertices, w = edge id + 1 (0 = not an edge)

const GRID := 65                    ## vertices per chunk side (64 quads)
const DETAIL_PERIOD := 4096.0       ## m; every shader detail texture tiles an integer number of times in this

## Cube faces: normal, u axis, v axis (u x v == normal).
const FACE_N: Array[Vector3] = [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
const FACE_U: Array[Vector3] = [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(1, 0, 0),
		Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(-1, 0, 0)]
const FACE_V: Array[Vector3] = [Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3(0, 0, -1),
		Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(0, 1, 0)]

static var _indices: PackedInt32Array
static var _grid_index_count := 0

var cfg: PlanetConfig
var radius := 1.0
var base_level := 0.0

var n_cont: FastNoiseLite
var n_mmask: FastNoiseLite
var n_ridge: FastNoiseLite
var n_gully: FastNoiseLite
var n_hills: FastNoiseLite
var n_rough: FastNoiseLite
var n_detail: FastNoiseLite
var n_canyon: FastNoiseLite
var n_moist: FastNoiseLite
var n_volc_d: FastNoiseLite
var n_volc_v: FastNoiseLite
var n_crater_d: Array[FastNoiseLite] = []
var n_crater_v: Array[FastNoiseLite] = []
## Same cells as n_crater_d/_v, RETURN_DISTANCE2_SUB (gap between the nearest and second-nearest
## feature point, 0 on a Voronoi border): fades each crater to zero before its cell border, so
## the height field is continuous where the nearest cell (and its random radius / threshold)
## switches. Same for volcanoes.
var n_crater_g: Array[FastNoiseLite] = []
## Gap (cell units, d2 - d1) over which a crater / volcano fades out toward its cell border.
const BORDER_FADE := 0.35
var n_volc_g: FastNoiseLite
var crater_cell: PackedFloat64Array = []
var n_river: FastNoiseLite
var n_river_m: FastNoiseLite
var n_cliff: FastNoiseLite
var n_isl: FastNoiseLite
var n_ray: FastNoiseLite
## Young ray craters: unit centre, tangent frame, radius (m) per crater.
var ray_c: PackedVector3Array = []
var ray_e1: PackedVector3Array = []
var ray_e2: PackedVector3Array = []
var ray_r: PackedFloat64Array = []

# cached config values (hot path)
var _ocean := false
var _cont_bias := 0.0
var _cont_h := 0.0
var _ocean_d := 0.0
var _coast_w := 0.04
var _m_h := 0.0
var _m_sharp := 1.0
var _m_cov := 0.0
var _m_plateau := 0.0
var _gully := 0.0
var _hills_h := 0.0
var _rough_h := 0.0
var _rough_scale := 1.0
var _detail_h := 0.0
var _detail_scale := 1.0
var _canyon := false
var _canyon_d := 0.0
var _canyon_w := 0.1
var _terrace := 0.0
var _terrace_s := 0.0
var _floor := -1e9
var _volc := false
var _volc_h := 0.0
var _volc_thr := 0.0
var _crater_depth := 0.2
var _crater_thr := 0.0
var _maria := 0.0
var _desert_belt := 0.0
var _moist_bias := 0.0
var _river := false
var _river_d := 0.0
var _river_w := 0.012
var _cliff_h := 0.0
var _berm := 0.0
var _isl := 0.0
var _water_mask := false   # river mask goes into the lava channel (planets without lava)


func _init(config: PlanetConfig) -> void:
	cfg = config
	radius = cfg.radius
	base_level = cfg.get_base_level()
	var s := cfg.seed
	n_cont = _mk(s + 1, cfg.continent_scale, cfg.continent_octaves)
	_warp(n_cont, cfg.warp_strength, cfg.warp_scale, 3)
	n_mmask = _mk(s + 2, cfg.mountain_mask_scale, 3)
	n_ridge = _mk(s + 3, cfg.mountain_scale, cfg.mountain_octaves, FastNoiseLite.FRACTAL_RIDGED)
	n_ridge.fractal_gain = 0.48
	n_ridge.fractal_weighted_strength = 0.6
	if cfg.warp_strength > 0.0:
		_warp(n_ridge, cfg.mountain_scale * 0.35, cfg.mountain_scale * 2.0, 2)
	n_gully = _mk(s + 4, cfg.gully_scale, 4, FastNoiseLite.FRACTAL_RIDGED)
	n_hills = _mk(s + 5, cfg.hills_scale, 5)
	n_rough = _mk(s + 6, cfg.rough_scale, 4)
	n_detail = _mk(s + 7, cfg.detail_scale, 3)
	n_moist = _mk(s + 8, cfg.moisture_scale, 4)
	if cfg.canyon_scale > 0.0:
		n_canyon = _mk(s + 9, cfg.canyon_scale, 4)
		n_canyon.fractal_gain = 0.45
		_warp(n_canyon, cfg.canyon_scale * 0.25, cfg.canyon_scale, 2)
	if cfg.volcano_scale > 0.0:
		n_volc_d = _mk_cell(s + 10, cfg.volcano_scale, FastNoiseLite.RETURN_DISTANCE)
		n_volc_v = _mk_cell(s + 10, cfg.volcano_scale, FastNoiseLite.RETURN_CELL_VALUE)
		n_volc_g = _mk_cell(s + 10, cfg.volcano_scale, FastNoiseLite.RETURN_DISTANCE2_SUB)
	if cfg.river_scale > 0.0 and cfg.river_depth > 0.0:
		n_river = _mk(s + 31, cfg.river_scale, 3)
		n_river.fractal_gain = 0.42
		_warp(n_river, cfg.river_scale * 0.18, cfg.river_scale * 0.7, 2)
		n_river_m = _mk(s + 32, cfg.river_scale * 2.5, 2)
	if cfg.coast_cliff_height > 0.0:
		n_cliff = _mk(s + 33, 9000.0, 3)
	if cfg.island_amount > 0.0:
		n_isl = _mk(s + 34, cfg.island_scale, 4)
	if cfg.ray_craters > 0:
		n_ray = _mk(s + 35, 1.0, 3)
		var rr := RandomNumberGenerator.new()
		rr.seed = s * 7 + 3
		for k in cfg.ray_craters:
			var c := Vector3(rr.randf_range(-1, 1), rr.randf_range(-1, 1), rr.randf_range(-1, 1))
			if c.length() < 0.05:
				c = Vector3.UP
			c = c.normalized()
			var e1 := c.cross(Vector3.UP if absf(c.y) < 0.9 else Vector3.RIGHT).normalized()
			ray_c.append(c)
			ray_e1.append(e1)
			ray_e2.append(c.cross(e1))
			ray_r.append(rr.randf_range(cfg.ray_crater_radius.x, cfg.ray_crater_radius.y))
	for i in cfg.crater_layers:
		var cell := cfg.crater_scale / pow(2.6, i)
		crater_cell.append(cell)
		n_crater_d.append(_mk_cell(s + 20 + i, cell, FastNoiseLite.RETURN_DISTANCE))
		n_crater_v.append(_mk_cell(s + 20 + i, cell, FastNoiseLite.RETURN_CELL_VALUE))
		n_crater_g.append(_mk_cell(s + 20 + i, cell, FastNoiseLite.RETURN_DISTANCE2_SUB))

	_ocean = cfg.has_ocean_surface()
	_cont_bias = cfg.continent_bias
	_cont_h = cfg.continent_height
	_ocean_d = cfg.ocean_depth
	_coast_w = maxf(cfg.coast_width, 0.001)
	_m_h = cfg.mountain_height
	_m_sharp = cfg.mountain_sharpness
	_m_cov = cfg.mountain_coverage
	_m_plateau = cfg.mountain_plateau
	_gully = cfg.gully_strength
	_hills_h = cfg.hills_height
	_rough_h = cfg.rough_height
	_rough_scale = cfg.rough_scale
	_detail_h = cfg.detail_height
	_detail_scale = cfg.detail_scale
	_canyon = n_canyon != null
	_canyon_d = cfg.canyon_depth
	_canyon_w = cfg.canyon_width
	_terrace = cfg.terrace_step
	_terrace_s = cfg.terrace_strength
	_floor = cfg.floor_level
	_volc = n_volc_d != null
	_volc_h = cfg.volcano_height
	_volc_thr = 1.0 - 2.0 * cfg.volcano_density
	_crater_depth = cfg.crater_depth
	_crater_thr = 1.0 - 2.0 * cfg.crater_density
	_maria = cfg.maria_strength
	_desert_belt = cfg.desert_belt
	_moist_bias = cfg.moisture_bias
	_river = n_river != null
	_river_d = cfg.river_depth
	_river_w = cfg.river_width
	_cliff_h = cfg.coast_cliff_height
	_berm = cfg.coast_berm
	_isl = cfg.island_amount
	_water_mask = cfg.lava_intensity <= 0.0
	if _indices.is_empty():
		_build_indices()


func _mk(sd: int, wavelength: float, octaves: int,
		fractal := FastNoiseLite.FRACTAL_FBM) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = sd
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 1.0 / wavelength
	n.fractal_type = fractal
	n.fractal_octaves = octaves
	n.fractal_lacunarity = 2.03
	n.fractal_gain = 0.5
	return n


## Domain warp with sane fractal settings (FastNoiseLite defaults use lacunarity 6 and
## 5 octaves, which produces metre-scale jitter of hundreds of metres).
static func _warp(n: FastNoiseLite, amplitude: float, wavelength: float, octaves: int) -> void:
	n.domain_warp_enabled = amplitude > 0.0
	n.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
	n.domain_warp_amplitude = amplitude
	n.domain_warp_frequency = 1.0 / wavelength
	n.domain_warp_fractal_type = FastNoiseLite.DOMAIN_WARP_FRACTAL_PROGRESSIVE
	n.domain_warp_fractal_octaves = octaves
	n.domain_warp_fractal_lacunarity = 2.0
	n.domain_warp_fractal_gain = 0.45


func _mk_cell(sd: int, cell: float, ret: FastNoiseLite.CellularReturnType) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = sd
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.frequency = 1.0 / cell
	n.fractal_type = FastNoiseLite.FRACTAL_NONE
	n.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	n.cellular_return_type = ret
	n.cellular_jitter = 0.85
	return n


# ---------------------------------------------------------------------------
# Height function
# ---------------------------------------------------------------------------

## Full-detail height (m above radius) for a unit direction. Same function the meshes use.
func get_height(dir: Vector3) -> float:
	return sample(dir.normalized(), 0.0).x


## Returns Vector4(height_m, rock_mask, lava_mask, ejecta_mask).
## `quad` = vertex spacing (m) of the caller (>= 1e8 skips the metre-scale octaves).
func sample(d: Vector3, quad: float) -> Vector4:
	var px := d.x * radius
	var py := d.y * radius
	var pz := d.z * radius
	var rock := 0.0
	var lava := 0.0
	var ejecta := 0.0
	var land := 1.0

	# --- continents (domain-warped fbm) ---
	var c := n_cont.get_noise_3d(px, py, pz) + _cont_bias
	if _isl > 0.0:
		# archipelagos / lagoons / ragged coasts: small-scale noise only near the coastline
		var ca := absf(c)
		if ca < 0.16:
			c += n_isl.get_noise_3d(px, py, pz) * _isl * (1.0 - smoothstep(0.03, 0.16, ca))
	var h := 0.0
	if c >= 0.0:
		h = _cont_h * pow(c * 2.0, 1.4)
	else:
		h = -_ocean_d * smoothstep(0.0, 0.3, -c) - _cont_h * 0.15 * (-c / _coast_w)
	if _ocean:
		land = smoothstep(-_coast_w, _coast_w * 2.0, c)
		if _berm > 0.0 and c > 0.0:
			h += _berm * smoothstep(0.0, 0.007, c)
		if _cliff_h > 0.0 and c > 0.0:
			# regional sea cliffs: a sharp step just behind the coastline (elsewhere: beaches)
			var cl := smoothstep(0.05, 0.4, n_cliff.get_noise_3d(px, py, pz))
			if cl > 0.0:
				var step_k := smoothstep(0.0004, 0.0045, c)
				h += _cliff_h * cl * step_k
				rock = maxf(rock, cl * step_k * (1.0 - step_k) * 3.0)
	if _maria > 0.0:
		# dark low basins on moons: flatten & lower where continents are negative
		var m := smoothstep(0.0, -0.25, c)
		h = lerpf(h, -_ocean_d * 0.8, m * _maria)
		ejecta -= m * _maria

	# --- mountain ranges: ridged noise on a plateau, masked ---
	if _m_h > 0.0:
		var mm := smoothstep(_m_cov - 0.15, _m_cov + 0.35, n_mmask.get_noise_3d(px, py, pz))
		mm *= land
		if _ocean:
			mm *= smoothstep(0.0, 0.18, c)  # ranges rise inland, coasts stay low
		if mm > 0.001:
			var r := (n_ridge.get_noise_3d(px, py, pz) + 1.0) * 0.5
			r = pow(clampf(r, 0.0, 1.0), _m_sharp)
			var g := 0.0
			if _gully > 0.0:
				g = (n_gully.get_noise_3d(px, py, pz) + 1.0) * 0.5
			var mount := r * (1.0 + _gully * (g - 0.5) * 2.0 * r)
			h += mm * _m_h * (_m_plateau + (1.0 - _m_plateau) * mount)
			rock = clampf(mm * (r * 1.6 - 0.15), 0.0, 1.0)

	# --- rolling hills ---
	if _hills_h > 0.0:
		h += n_hills.get_noise_3d(px, py, pz) * _hills_h * (0.25 + 0.75 * land)

	# --- river valleys: warped |noise| channels cut into the land (deeper through mountains),
	# flat channel floor reaching sea level at the coast (estuaries / fjords) ---
	var chan := 0.0
	if _river:
		var rn := absf(n_river.get_noise_3d(px, py, pz))
		var rw := _river_w
		if rn < rw * 6.0 and h > -30.0:
			var dens := smoothstep(-0.35, 0.05, n_river_m.get_noise_3d(px, py, pz))
			var landk := smoothstep(-0.004, 0.03, c) * dens
			if landk > 0.0:
				var valley := smoothstep(rw * 6.0, rw * 0.6, rn)
				valley = valley * valley * (3.0 - 2.0 * valley)
				chan = smoothstep(rw, rw * 0.45, rn) * landk
				var hp := maxf(h, 0.0)
				var cut := minf(hp * 0.97, _river_d * (1.0 + hp / 700.0))
				h -= cut * (valley * 0.8 + chan * 0.2) * landk
				if _water_mask:
					lava = maxf(lava, chan)

	# --- volcanoes (shield cones with calderas) ---
	if _volc:
		var vv := n_volc_v.get_noise_3d(px, py, pz)
		if vv > _volc_thr:
			var vd := n_volc_d.get_noise_3d(px, py, pz) + 1.0
			var vr := vd / 0.75
			var vfade := 0.0
			if vr < 1.0:
				vfade = smoothstep(0.0, BORDER_FADE, n_volc_g.get_noise_3d(px, py, pz) + 1.0)
			if vfade > 0.0:
				var size := 0.55 + 0.45 * fposmod(vv * 13.7, 1.0)
				var cone := pow(1.0 - vr, 1.8) * _volc_h * size
				var cal := smoothstep(0.16, 0.08, vr)
				var rimh := pow(1.0 - 0.16, 1.8) * _volc_h * size
				cone = lerpf(cone, rimh - _volc_h * 0.12 * size, cal)
				h += cone * vfade
				lava = maxf(lava, cal * 0.9 * vfade)
				rock = maxf(rock, smoothstep(0.9, 0.2, vr) * 0.6 * vfade)

	# --- canyons (warped |noise| channels) + strata terraces ---
	if _canyon:
		var cn := absf(n_canyon.get_noise_3d(px, py, pz))
		var k := smoothstep(_canyon_w, _canyon_w * 0.35, cn)
		if _terrace > 0.0:
			h = _terraced(h)
		h -= k * _canyon_d
		lava = maxf(lava, smoothstep(_canyon_w * 0.3, _canyon_w * 0.05, cn))
		rock = maxf(rock, k * (1.0 - k) * 4.0)
	elif _terrace > 0.0:
		h = _terraced(h)

	# --- craters (cellular layers, bowl + raised rim + ejecta) ---
	for i in n_crater_d.size():
		var cv := n_crater_v[i].get_noise_3d(px, py, pz)
		if cv < _crater_thr:
			continue
		var rad := 0.22 + 0.2 * fposmod(cv * 7.31, 1.0)
		var r := (n_crater_d[i].get_noise_3d(px, py, pz) + 1.0) / rad
		if r > 2.6:
			continue
		var fade := smoothstep(0.0, BORDER_FADE, n_crater_g[i].get_noise_3d(px, py, pz) + 1.0)
		if fade <= 0.0:
			continue
		var depth := rad * crater_cell[i] * _crater_depth
		var fresh := fposmod(cv * 3.17, 1.0)
		var ch := 0.0
		if r < 1.0:
			# parabolic bowl, flattened floor, central peak in big craters
			ch = maxf(r * r - 1.0, -0.75) * depth + 0.18 * depth
			if i == 0:
				ch += 0.35 * depth * smoothstep(0.25, 0.0, r)
			rock = maxf(rock, smoothstep(0.6, 0.95, r) * 0.8 * fade)
		else:
			var t := r - 1.0
			ch = 0.18 * depth * exp(-t * t * 9.0)
			# rim rock fades outward (continuous with the bowl's 0.8 at r = 1: the rock mask
			# scales the roughness octaves, a jump here was a ~1 m step)
			rock = maxf(rock, smoothstep(1.35, 1.0, r) * 0.8 * fade)
			ejecta = maxf(ejecta, fresh * smoothstep(2.6, 1.0, r) * fade)
		h += ch * fade

	# --- young ray craters: fresh bowl + bright ejecta blanket + long radial rays ---
	for k in ray_c.size():
		var cc := ray_c[k]
		var cosang := d.dot(cc)
		var rk := ray_r[k]
		if cosang < 0.0:
			continue
		var dist := acos(minf(cosang, 1.0)) * radius
		var t := dist / rk
		if t > 9.0:
			continue
		var v := d - cc * cosang
		var phi := atan2(v.dot(ray_e2[k]), v.dot(ray_e1[k]))
		var fresh_depth := rk * 0.22
		if t < 2.0:
			var cht := 0.0
			if t < 1.0:
				cht = maxf(t * t - 1.0, -0.8) * fresh_depth + 0.2 * fresh_depth
				cht += 0.3 * fresh_depth * smoothstep(0.3, 0.0, t)
				rock = maxf(rock, smoothstep(0.55, 0.95, t) * 0.9)
			else:
				var tt := t - 1.0
				cht = 0.2 * fresh_depth * exp(-tt * tt * 8.0)
				rock = maxf(rock, smoothstep(1.3, 1.0, t) * 0.9)
			h += cht * smoothstep(2.0, 1.7, t)
		if t > 0.8:
			var rn := n_ray.get_noise_3d(cos(phi) * 4.0 + k * 13.0, sin(phi) * 4.0, t * 0.35)
			var ray := smoothstep(0.05, 0.45, rn) * exp(-(t - 1.0) * 0.32)
			var blanket := exp(-(t - 1.0) * (t - 1.0) * 1.2) * 0.9
			ejecta = maxf(ejecta, maxf(ray, blanket) * smoothstep(0.8, 1.05, t) * smoothstep(9.0, 6.0, t))

	# --- flat floors (frozen seas / lava plains) ---
	if h < _floor:
		h = _floor + (h - _floor) * 0.04

	# --- mid roughness & micro relief (LOD dependent) ---
	# Always evaluated (also for coarse chunks): skipping octaves per LOD would make
	# neighbouring levels disagree by metres and expose the skirts. Only callers that
	# never need mesh-consistent values (quad >= 1e8, LOD bounds estimation) skip them.
	if quad < 1e8:
		var calm := 1.0 - chan * 0.85     # flat river beds
		if _rough_h > 0.0:
			h += n_rough.get_noise_3d(px, py, pz) * _rough_h * (0.35 + rock) * calm
		if _detail_h > 0.0:
			h += n_detail.get_noise_3d(px, py, pz) * _detail_h * (0.4 + rock) * calm
	return Vector4(h + base_level, rock, lava, ejecta)


func _terraced(h: float) -> float:
	var t := h / _terrace
	var f := t - floorf(t)
	var s := smoothstep(0.35, 0.65, f)
	return lerpf(h, (floorf(t) + s) * _terrace, _terrace_s)


func moisture(d: Vector3) -> float:
	var m := n_moist.get_noise_3d(d.x * radius, d.y * radius, d.z * radius) * 0.6 + 0.5
	var lat := absf(d.y)
	m -= _desert_belt * exp(-pow((lat - 0.42) / 0.16, 2.0))
	m += 0.15 * (1.0 - smoothstep(0.0, 0.25, lat))  # wet equator
	return clampf(m + _moist_bias, 0.0, 1.0)


# ---------------------------------------------------------------------------
# Cube-sphere mapping
# ---------------------------------------------------------------------------

## Spherified cube: maps a cube point to the unit sphere with near-uniform cell area.
static func cube_to_sphere(p: Vector3) -> Vector3:
	var x2 := p.x * p.x
	var y2 := p.y * p.y
	var z2 := p.z * p.z
	return Vector3(
		p.x * sqrt(maxf(1.0 - y2 * 0.5 - z2 * 0.5 + y2 * z2 / 3.0, 0.0)),
		p.y * sqrt(maxf(1.0 - z2 * 0.5 - x2 * 0.5 + z2 * x2 / 3.0, 0.0)),
		p.z * sqrt(maxf(1.0 - x2 * 0.5 - y2 * 0.5 + x2 * y2 / 3.0, 0.0)))


static func face_point(face: int, u: float, v: float) -> Vector3:
	return cube_to_sphere(FACE_N[face] + FACE_U[face] * u + FACE_V[face] * v)


# ---------------------------------------------------------------------------
# Chunk mesh
# ---------------------------------------------------------------------------

static func _build_indices() -> void:
	var n := GRID
	var idx := PackedInt32Array()
	for j in n - 1:
		for i in n - 1:
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var e := c + 1
			# alternate diagonals for a more isotropic triangulation
			if (i + j) & 1 == 0:
				idx.append_array([a, e, b, a, c, e])
			else:
				idx.append_array([a, c, b, b, c, e])
	_grid_index_count = idx.size()
	# skirts: 4 edges, each N verts duplicated below the edge
	var base := n * n
	var edges := _edge_lists()
	for s in 4:
		var edge: PackedInt32Array = edges[s]
		for k in n - 1:
			var e0 := edge[k]
			var e1 := edge[k + 1]
			var s0 := base + s * n + k
			var s1 := s0 + 1
			idx.append_array([e0, e1, s1, e0, s1, s0])
	_indices = idx


## Edge vertex index lists, ordered so that the skirt quads built in _build_indices
## have the same winding as the surface (walking the border counter-clockwise in u/v).
static func _edge_lists() -> Array[PackedInt32Array]:
	var n := GRID
	var bottom := PackedInt32Array()
	var right := PackedInt32Array()
	var top := PackedInt32Array()
	var left := PackedInt32Array()
	for k in n:
		bottom.append(k)                         # j = 0, i ascending
		right.append(k * n + (n - 1))            # i = n-1, j ascending
		top.append((n - 1) * n + (n - 1 - k))    # j = n-1, i descending
		left.append((n - 1 - k) * n)             # i = 0, j descending
	return [bottom, right, top, left]


## Builds mesh arrays for one quadtree chunk. Runs on worker threads.
## face: cube face; (u0, v0): min corner in face coords [-1,1]; size: extent in face coords.
## Returns a Dictionary with "arrays", "origin", "min_h", "max_h" and optional "faces".
func build_chunk(face: int, u0: float, v0: float, size: float, want_faces: bool,
		skirt_depth: float) -> Dictionary:
	var n := GRID
	var ne := n + 2
	var step := size / float(n - 1)
	var fn := FACE_N[face]
	var fu := FACE_U[face]
	var fv := FACE_V[face]
	var cdir := face_point(face, u0 + size * 0.5, v0 + size * 0.5)
	# origin in float64 scalars (GDScript float is double)
	var ox := float(cdir.x) * radius
	var oy := float(cdir.y) * radius
	var oz := float(cdir.z) * radius
	var quad := size * radius * 0.785 / float(n - 1)

	# --- sample extended grid (1-vertex apron for normals/curvature) ---
	var pos := PackedVector3Array()
	pos.resize(ne * ne)
	var hts := PackedFloat32Array()
	hts.resize(ne * ne)
	var dirs := PackedVector3Array()
	dirs.resize(ne * ne)
	var masks := PackedColorArray()
	masks.resize(n * n)
	var min_h := 1e9
	var max_h := -1e9
	for j in ne:
		var v := v0 + float(j - 1) * step
		for i in ne:
			var u := u0 + float(i - 1) * step
			var d := cube_to_sphere(fn + fu * u + fv * v)
			var s := sample(d, quad)
			var k := j * ne + i
			var rr := radius + s.x
			pos[k] = Vector3(d.x * rr - ox, d.y * rr - oy, d.z * rr - oz)
			hts[k] = s.x
			dirs[k] = d
			if i > 0 and j > 0 and i <= n and j <= n:
				masks[(j - 1) * n + (i - 1)] = Color(s.y, s.z, s.w, 0.5)
				min_h = minf(min_h, s.x)
				max_h = maxf(max_h, s.x)

	# --- interior vertices ---
	var vcount := n * n + 4 * n
	var verts := PackedVector3Array()
	verts.resize(vcount)
	var nrms := PackedVector3Array()
	nrms.resize(vcount)
	var cols := PackedColorArray()
	cols.resize(vcount)
	var c0 := PackedFloat32Array()
	c0.resize(vcount * 4)
	var c1 := PackedFloat32Array()
	c1.resize(vcount * 4)
	var dox := fposmod(ox, DETAIL_PERIOD)
	var doy := fposmod(oy, DETAIL_PERIOD)
	var doz := fposmod(oz, DETAIL_PERIOD)
	var inv_step_m := 1.0 / maxf(quad, 0.001)
	for j in n:
		for i in n:
			var k := (j + 1) * ne + (i + 1)
			var p := pos[k]
			var du := pos[k + 1] - pos[k - 1]
			var dv := pos[k + ne] - pos[k - ne]
			var nr := du.cross(dv).normalized()
			var vi := j * n + i
			verts[vi] = p
			nrms[vi] = nr
			var lap := (hts[k + 1] + hts[k - 1] + hts[k + ne] + hts[k - ne] - 4.0 * hts[k]) * inv_step_m
			var col := masks[vi]
			col.a = clampf(0.5 + lap * 0.25, 0.0, 1.0)
			cols[vi] = col
			var d := dirs[k]
			var q := vi * 4
			c0[q] = dox + p.x
			c0[q + 1] = doy + p.y
			c0[q + 2] = doz + p.z
			c0[q + 3] = hts[k]
			c1[q] = d.x
			c1[q + 1] = d.y
			c1[q + 2] = d.z
			c1[q + 3] = moisture(d)

	# --- edge morph targets: odd edge vertices -> midpoint of their even neighbours.
	# The shader applies them on edges whose neighbour chunk is one level coarser
	# (instance uniform `coarse_edges`), which removes T-junction cracks.
	var edges := _edge_lists()
	var c2 := PackedFloat32Array()
	c2.resize(vcount * 4)
	for s in 4:
		var edge: PackedInt32Array = edges[s]
		for k in range(1, n - 1, 2):
			var src := edge[k]
			var delta := (verts[edge[k - 1]] + verts[edge[k + 1]]) * 0.5 - verts[src]
			var q := src * 4
			c2[q] = delta.x
			c2[q + 1] = delta.y
			c2[q + 2] = delta.z
			c2[q + 3] = float(s + 1)

	# --- skirts: copies of edge vertices pushed toward the planet centre ---
	var base := n * n
	for s in 4:
		var edge: PackedInt32Array = edges[s]
		for k in n:
			var src := edge[k]
			var dst := base + s * n + k
			var q := src * 4
			var d := Vector3(c1[q], c1[q + 1], c1[q + 2])
			verts[dst] = verts[src] - d * skirt_depth
			nrms[dst] = nrms[src]
			cols[dst] = cols[src]
			var qd := dst * 4
			for t in 4:
				c1[qd + t] = c1[q + t]
				c2[qd + t] = c2[q + t]
			c0[qd] = c0[q] - d.x * skirt_depth
			c0[qd + 1] = c0[q + 1] - d.y * skirt_depth
			c0[qd + 2] = c0[q + 2] - d.z * skirt_depth
			c0[qd + 3] = c0[q + 3] - skirt_depth

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = nrms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_CUSTOM2] = c2
	arrays[Mesh.ARRAY_INDEX] = _indices
	var out := {
		"arrays": arrays,
		"origin": Vector3(ox, oy, oz),
		"min_h": min_h,
		"max_h": max_h,
	}
	if want_faces:
		# Collision at half resolution (2x vertex spacing): 4x cheaper BVH, still sub-metre.
		var faces := PackedVector3Array()
		var m := (n - 1) / 2
		faces.resize(m * m * 6)
		var f := 0
		for j in range(0, n - 1, 2):
			for i in range(0, n - 1, 2):
				var a := verts[j * n + i]
				var b := verts[j * n + i + 2]
				var c := verts[(j + 2) * n + i]
				var e := verts[(j + 2) * n + i + 2]
				faces[f] = a
				faces[f + 1] = e
				faces[f + 2] = b
				faces[f + 3] = a
				faces[f + 4] = c
				faces[f + 5] = e
				f += 6
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)   # BVH build happens here, on the worker thread
		shape.backface_collision = true
		out["shape"] = shape
	return out


static func mesh_format_flags() -> int:
	return (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)
