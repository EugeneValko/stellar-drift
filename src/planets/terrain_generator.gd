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
##   COLOR    r = rock exposure, g = lava mask, b = crater ejecta, a = curvature (0.5 = flat)
##   CUSTOM0  xyz = detail coords (planet-local position mod DETAIL_PERIOD, continuous inside
##            a chunk and periodic across chunks), w = height above radius (m)
##   CUSTOM1  xyz = unit direction from planet centre, w = moisture (0..1)

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
var crater_cell: PackedFloat64Array = []

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


func _init(config: PlanetConfig) -> void:
	cfg = config
	radius = cfg.radius
	base_level = cfg.get_base_level()
	var s := cfg.seed
	n_cont = _mk(s + 1, cfg.continent_scale, cfg.continent_octaves)
	n_cont.domain_warp_enabled = cfg.warp_strength > 0.0
	n_cont.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
	n_cont.domain_warp_amplitude = cfg.warp_strength
	n_cont.domain_warp_frequency = 1.0 / cfg.warp_scale
	n_cont.domain_warp_fractal_type = FastNoiseLite.DOMAIN_WARP_FRACTAL_PROGRESSIVE
	n_cont.domain_warp_fractal_octaves = 3
	n_mmask = _mk(s + 2, cfg.mountain_mask_scale, 3)
	n_ridge = _mk(s + 3, cfg.mountain_scale, cfg.mountain_octaves, FastNoiseLite.FRACTAL_RIDGED)
	n_ridge.fractal_gain = 0.48
	n_ridge.fractal_weighted_strength = 0.6
	n_ridge.domain_warp_enabled = cfg.warp_strength > 0.0
	n_ridge.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
	n_ridge.domain_warp_amplitude = cfg.mountain_scale * 0.35
	n_ridge.domain_warp_frequency = 1.0 / (cfg.mountain_scale * 2.0)
	n_gully = _mk(s + 4, cfg.gully_scale, 4, FastNoiseLite.FRACTAL_RIDGED)
	n_hills = _mk(s + 5, cfg.hills_scale, 5)
	n_rough = _mk(s + 6, cfg.rough_scale, 4)
	n_detail = _mk(s + 7, cfg.detail_scale, 3)
	n_moist = _mk(s + 8, cfg.moisture_scale, 4)
	if cfg.canyon_scale > 0.0:
		n_canyon = _mk(s + 9, cfg.canyon_scale, 4)
		n_canyon.fractal_gain = 0.45
		n_canyon.domain_warp_enabled = true
		n_canyon.domain_warp_type = FastNoiseLite.DOMAIN_WARP_SIMPLEX
		n_canyon.domain_warp_amplitude = cfg.canyon_scale * 0.25
		n_canyon.domain_warp_frequency = 1.0 / cfg.canyon_scale
	if cfg.volcano_scale > 0.0:
		n_volc_d = _mk_cell(s + 10, cfg.volcano_scale, FastNoiseLite.RETURN_DISTANCE)
		n_volc_v = _mk_cell(s + 10, cfg.volcano_scale, FastNoiseLite.RETURN_CELL_VALUE)
	for i in cfg.crater_layers:
		var cell := cfg.crater_scale / pow(2.6, i)
		crater_cell.append(cell)
		n_crater_d.append(_mk_cell(s + 20 + i, cell, FastNoiseLite.RETURN_DISTANCE))
		n_crater_v.append(_mk_cell(s + 20 + i, cell, FastNoiseLite.RETURN_CELL_VALUE))

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
## `quad` = vertex spacing (m) of the caller; detail octaves far below it are skipped.
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
	var h := 0.0
	if c >= 0.0:
		h = _cont_h * pow(c * 2.0, 1.4)
	else:
		h = -_ocean_d * smoothstep(0.0, 0.3, -c) - _cont_h * 0.15 * (-c / _coast_w)
	if _ocean:
		land = smoothstep(-_coast_w, _coast_w * 2.0, c)
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

	# --- volcanoes (shield cones with calderas) ---
	if _volc:
		var vv := n_volc_v.get_noise_3d(px, py, pz)
		if vv > _volc_thr:
			var vd := n_volc_d.get_noise_3d(px, py, pz) + 1.0
			var vr := vd / 0.75
			if vr < 1.0:
				var size := 0.55 + 0.45 * fposmod(vv * 13.7, 1.0)
				var cone := pow(1.0 - vr, 1.8) * _volc_h * size
				var cal := smoothstep(0.16, 0.08, vr)
				var rimh := pow(1.0 - 0.16, 1.8) * _volc_h * size
				cone = lerpf(cone, rimh - _volc_h * 0.12 * size, cal)
				h += cone
				lava = maxf(lava, cal * 0.9)
				rock = maxf(rock, smoothstep(0.9, 0.2, vr) * 0.6)

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
		var depth := rad * crater_cell[i] * _crater_depth
		var fresh := fposmod(cv * 3.17, 1.0)
		var ch := 0.0
		if r < 1.0:
			# parabolic bowl, flattened floor, central peak in big craters
			ch = maxf(r * r - 1.0, -0.75) * depth + 0.18 * depth
			if i == 0:
				ch += 0.35 * depth * smoothstep(0.25, 0.0, r)
			rock = maxf(rock, smoothstep(0.6, 0.95, r) * 0.8)
		else:
			var t := r - 1.0
			ch = 0.18 * depth * exp(-t * t * 9.0)
			ejecta = maxf(ejecta, fresh * smoothstep(2.6, 1.0, r))
		h += ch

	# --- flat floors (frozen seas / lava plains) ---
	if h < _floor:
		h = _floor + (h - _floor) * 0.04

	# --- mid roughness & micro relief (LOD dependent) ---
	if _rough_h > 0.0 and quad < _rough_scale * 0.6:
		var rr := n_rough.get_noise_3d(px, py, pz)
		h += rr * _rough_h * (0.35 + rock)
	if _detail_h > 0.0 and quad < _detail_scale * 0.6:
		h += n_detail.get_noise_3d(px, py, pz) * _detail_h * (0.4 + rock)
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

	# --- skirts: copies of edge vertices pushed toward the planet centre ---
	var edges := _edge_lists()
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
	arrays[Mesh.ARRAY_INDEX] = _indices
	var out := {
		"arrays": arrays,
		"origin": Vector3(ox, oy, oz),
		"min_h": min_h,
		"max_h": max_h,
	}
	if want_faces:
		var faces := PackedVector3Array()
		faces.resize(_grid_index_count)
		for t in _grid_index_count:
			faces[t] = verts[_indices[t]]
		out["faces"] = faces
	return out


static func mesh_format_flags() -> int:
	return (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
