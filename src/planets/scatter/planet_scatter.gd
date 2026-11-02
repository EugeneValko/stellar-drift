class_name PlanetScatter
extends Node3D
## Vegetation / rocks / ground detail around the focus, as a Planet component.
##
##   var scatter := PlanetScatter.new()
##   planet.add_component(scatter)      # -> setup(config) + set_planet(planet)
##
## Rule set: `rules`, or src/planets/scatter/presets/<config file name>.tres (e.g. terra_nova.tres),
## or <planet_name in snake_case>.tres.
##
## How it works
## - Each ScatterLayer places instances deterministically per cell of an equi-angular cube-sphere grid
##   (cell ~ layer.cell_size). A cell samples a small height grid with TerrainGenerator.sample() (the
##   same thread-safe function the terrain meshes use), evaluates the terrain shader's biome logic
##   (ScatterBiome) and accepts jittered candidates by the layer rules.
## - Near ring: one MultiMeshInstance3D patch per cell, mesh LOD switched per patch by distance.
##   Far ring (optional, e.g. trees 0.8-3 km): patches of far_factor^2 cells with a low hull mesh;
##   the two rings cross-fade per instance (dithered) in the shaders (instance uniform fade_range).
## - Patches are children of this node, i.e. planet-local: floating-origin shifts / planet motion are
##   free. Instance transforms are relative to the patch origin (small numbers, float32 safe).
## - Cell generation runs on WorkerThreadPool (max_jobs tasks); the main thread only uploads finished
##   buffers (bounded per frame) and creates collision bodies for trees / big rocks near the focus.
## - Instances are oriented to the local sphere up (optionally blended toward the terrain normal).

const PRESET_DIR := "res://src/planets/scatter/presets/"
const FLOATS := 16    # MultiMesh TRANSFORM_3D (12) + custom data (4)

const FACE_N: Array[Vector3] = [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
const FACE_U: Array[Vector3] = [Vector3(0, 0, -1), Vector3(0, 0, 1), Vector3(1, 0, 0),
		Vector3(1, 0, 0), Vector3(1, 0, 0), Vector3(-1, 0, 0)]
const FACE_V: Array[Vector3] = [Vector3(0, 1, 0), Vector3(0, 1, 0), Vector3(0, 0, -1),
		Vector3(0, 0, 1), Vector3(0, 1, 0), Vector3(0, 1, 0)]

@export var rules: ScatterRuleSet
## Optional focus node (player / ship / camera). Default: the terrain LOD focus (planet.terrain.focus).
@export var focus_node: Node3D
@export var enabled := true
## Worker tasks in flight (shared pool with the terrain).
@export var max_jobs := 2
@export var max_uploads_per_frame := 8
@export var upload_budget_ms := 2.5
@export var collision_enabled := true
## Bodies created per frame (each holds the shapes of one patch).
@export var max_bodies_per_frame := 1
## Max cached cells per layer (cells outside every ring are evicted beyond this).
@export var cache_limit := 4000
## Print progress of build_until_stable().
@export var verbose := false
## 0/1/2: scales layer shadow distances, far-ring reach, mesh LOD distances and ground-cover
## density (QUALITY table). 2 = the rule set as authored. Changing it rebuilds all patches.
@export_range(0, 2) var quality := 1:
	set(v):
		quality = clampi(v, 0, 2)
		if _ready_to_run:
			_init_runtime()

## Per quality level: shadow distance, far-ring max distance, LOD switch distances, density of
## dense small layers (grass/flowers/pebbles: cell_size < 48 m).
const QUALITY := [
	{"shadow": 0.45, "far": 0.6, "lod": 0.7, "cover": 0.6},
	# q1 keeps full shadow distance: from 300 m up, 0.7x already removes every tree shadow
	{"shadow": 1.0, "far": 0.8, "lod": 0.85, "cover": 0.8},
	{"shadow": 1.0, "far": 1.0, "lod": 1.0, "cover": 1.0},
]

var config: PlanetConfig
var planet: Planet
var gen: TerrainGenerator
var biome: ScatterBiome
var assets: ScatterAssets
var radius := 1.0

var _layers: Array[LayerRT] = []
var _patches := {}            # key -> Patch
var _pending := {}            # key -> PatchJob (queued or running)
var _queue: Array[PatchJob] = []
var _jobs: Array[PatchJob] = []
var _focus := Vector3(0, 0, 1e12)
var _active := false
var _ready_to_run := false
var _ground_h := 0.0
var _last_ground_focus := Vector3(INF, INF, INF)
var _body_queue: Array[Patch] = []
var _stat_cells := 0
var _stat_cell_ms := 0.0
var _prof_upload := 0.0
var _last_log := 0
var _prof_scan := 0.0
var _prof_bodies := 0.0
var _manual_focus := false
var _scan_cursor := 0
var _grid_next := 0


class LayerRT:
	var src: ScatterLayer
	var index := 0
	var n_cells := 1
	var cell_m := 64.0
	var far_n := 0
	var has_far := false
	var near_max := 400.0
	var meshes: Array[Mesh] = []
	var far: Mesh
	var rule_attr := PackedInt32Array()
	var tint := false
	var height_jit := 0.0
	var rule_lo := PackedFloat32Array()
	var rule_hi := PackedFloat32Array()
	var rule_soft := PackedFloat32Array()
	var need_attr := PackedInt32Array()
	var cluster: FastNoiseLite
	var cluster_thr := 0.0
	var cluster_soft := 0.2
	var seed := 0
	var density := 0.0
	var grid := 8
	var exact := false
	var scale_lo := 1.0
	var scale_hi := 1.0
	var edge_scale := 0.0
	var tilt := 0.0
	var align := 0.0
	var sink := 0.0
	var cache := {}
	var scan_pos: Array[Vector3] = [Vector3(INF, INF, INF), Vector3(INF, INF, INF)]
	var patch_keys: Array[Dictionary] = [{}, {}]
	var cache_next := 0
	var convex: Shape3D


class CellData:
	var origin := Vector3.ZERO
	var data := PackedFloat32Array()
	var count := 0


class Patch:
	var key := 0
	var layer: LayerRT
	var ring := 0
	var node: MultiMeshInstance3D
	var body: StaticBody3D
	var center := Vector3.ZERO
	var radius := 0.0
	var lod := -1
	var count := 0
	var dist := 0.0
	var body_queued := false
	var buffer := PackedFloat32Array()   # CPU copy (collision layers only)


class PatchJob:
	var key := 0
	var layer: LayerRT
	var ring := 0
	var face := 0
	var i0 := 0
	var j0 := 0
	var span := 1
	var center := Vector3.ZERO
	var radius := 0.0
	var prio := 0.0
	var cached := {}
	var new_cells := {}
	var origin := Vector3.ZERO
	var buffer := PackedFloat32Array()
	var count := 0
	var ms := 0.0
	var task := -1


# ---------------------------------------------------------------------------------------------
# Component interface
# ---------------------------------------------------------------------------------------------

func setup(cfg: PlanetConfig) -> void:
	config = cfg
	if planet:
		_init_runtime()


func set_planet(p: Planet) -> void:
	planet = p
	if config == null:
		config = p.config
	_init_runtime()


func _ready() -> void:
	if name.begins_with("@") or name == "":
		name = "Scatter"


func _exit_tree() -> void:
	_wait_jobs()


## Copy of an authored layer with the QUALITY multipliers applied. Debug overrides on the command
## line (after `--`): --scatter_quality=N, --scatter_shadow=x, --scatter_far=x, --scatter_lod=x,
## --scatter_cover=x.
func _scaled_layer(src: ScatterLayer) -> ScatterLayer:
	var q: Dictionary = QUALITY[quality].duplicate()
	var tree := Engine.get_main_loop() as SceneTree
	var cap: Node = tree.root.get_node_or_null("Capture") if tree else null
	if cap:
		if cap.args.has("scatter_quality"):
			q = QUALITY[clampi(int(cap.args["scatter_quality"]), 0, 2)].duplicate()
		for k: String in ["shadow", "far", "lod", "cover"]:
			if cap.args.has("scatter_" + k):
				q[k] = float(cap.args["scatter_" + k])
	var s: ScatterLayer = src.duplicate()
	s.shadow_distance = src.shadow_distance * q.shadow
	if s.far_mesh != "" and s.max_distance > s.far_start:
		s.max_distance = maxf(src.max_distance * q.far, s.far_start + s.fade_length * 2.0)
	var lods := PackedFloat32Array()
	for d in src.lod_distances:
		lods.append(d * q.lod)
	s.lod_distances = lods
	if src.cell_size < 48.0:
		s.density = src.density * q.cover
	return s


func _init_runtime() -> void:
	_wait_jobs()
	clear()
	if planet == null or planet.terrain == null or config == null:
		return
	if rules == null:
		rules = _find_rules(config)
	if rules == null:
		_ready_to_run = false
		return
	gen = planet.terrain.generator
	radius = config.radius
	biome = ScatterBiome.new(gen, config)
	assets = ScatterAssets.new(config, rules)
	_layers.clear()
	var face_edge := radius * PI * 0.5
	for li in rules.layers.size():
		var s: ScatterLayer = rules.layers[li]
		if s == null or not s.enabled:
			continue
		s = _scaled_layer(s)
		var L := LayerRT.new()
		L.src = s
		L.index = li
		L.has_far = s.far_mesh != "" and s.far_factor > 1 and s.max_distance > s.far_start
		if L.has_far:
			L.far_n = maxi(1, roundi(face_edge / (s.cell_size * s.far_factor)))
			L.n_cells = L.far_n * s.far_factor
			L.near_max = s.far_start
		else:
			L.n_cells = maxi(1, roundi(face_edge / s.cell_size))
			L.near_max = s.max_distance
		L.cell_m = face_edge / float(L.n_cells)
		for mname in s.meshes:
			L.meshes.append(assets.mesh_for(s, mname))
		L.far = assets.mesh_for(s, s.far_mesh) if L.has_far else null
		for attr: String in s.rules:
			var ai := ScatterBiome.ATTRS.find(attr)
			if ai < 0:
				push_warning("PlanetScatter: unknown rule attribute " + attr)
				continue
			var r: Vector3 = s.rules[attr]
			L.rule_attr.append(ai)
			L.rule_lo.append(r.x)
			L.rule_hi.append(r.y)
			L.rule_soft.append(maxf(r.z, 1e-4))
		var need := {ScatterBiome.A_MOIST: true, ScatterBiome.A_SNOW: true}
		for ai in L.rule_attr:
			need[ai] = true
		L.need_attr = PackedInt32Array(need.keys())
		L.seed = hash([config.seed, s.seed, s.name])
		if s.cluster_scale > 0.0:
			L.cluster = FastNoiseLite.new()
			L.cluster.seed = L.seed & 0x7fffffff
			L.cluster.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			L.cluster.frequency = 1.0 / s.cluster_scale
			L.cluster.fractal_octaves = 3
			L.cluster_thr = s.cluster_threshold
			L.cluster_soft = maxf(s.cluster_soft, 1e-3)
		L.density = s.density
		L.grid = maxi(2, s.grid_res + (s.grid_res & 1))
		L.exact = s.exact_height
		L.scale_lo = s.scale_range.x
		L.scale_hi = s.scale_range.y
		L.edge_scale = s.edge_scale
		L.tilt = deg_to_rad(s.max_tilt_deg)
		L.align = s.align_to_normal
		L.sink = s.sink
		L.tint = s.tint_regions
		L.height_jit = s.height_jitter
		if s.collision == 3 and not L.meshes.is_empty():
			L.convex = L.meshes[L.meshes.size() - 1].create_convex_shape(true, true)
		_layers.append(L)
	_ready_to_run = true


static func _find_rules(cfg: PlanetConfig) -> ScatterRuleSet:
	var names: Array[String] = []
	if cfg.resource_path != "":
		names.append(cfg.resource_path.get_file().get_basename())
	names.append(cfg.planet_name.to_snake_case())
	for n in names:
		var p := PRESET_DIR + n + ".tres"
		if ResourceLoader.exists(p):
			return load(p) as ScatterRuleSet
	return null


## Removes every patch (caches are kept unless `drop_cache`).
func clear(drop_cache := true) -> void:
	_wait_jobs()
	for k in _patches:
		var p: Patch = _patches[k]
		if p.node:
			p.node.queue_free()
	_patches.clear()
	_pending.clear()
	_queue.clear()
	_body_queue.clear()
	if drop_cache:
		for L in _layers:
			L.cache.clear()
		_grid_cache.clear()
	for L in _layers:
		L.scan_pos = [Vector3(INF, INF, INF), Vector3(INF, INF, INF)]
		L.patch_keys = [{}, {}]
	_active = false


func _wait_jobs() -> void:
	for j in _jobs:
		WorkerThreadPool.wait_for_task_completion(j.task)
	_jobs.clear()


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

## Focus override in planet-local space (otherwise focus_node / terrain focus is used).
## Stays in effect until clear_focus_override().
func set_focus(local_pos: Vector3) -> void:
	_focus = local_pos
	_manual_focus = true
	focus_node = null


## Back to following focus_node / the terrain focus.
func clear_focus_override() -> void:
	_manual_focus = false


## Synchronously builds everything for the current focus (capture / loading screens).
func build_until_stable(max_seconds := 120.0) -> void:
	if not _ready_to_run:
		return
	var t0 := Time.get_ticks_msec()
	_update_focus()
	_scan(true)
	while not _queue.is_empty() or not _jobs.is_empty():
		_dispatch(maxi(max_jobs, OS.get_processor_count() - 1))
		_collect(1 << 30, 1e9, true)
		if verbose and Time.get_ticks_msec() - _last_log > 2000:
			_last_log = Time.get_ticks_msec()
			print("[scatter] building: %d queued, %d cells, %.1f s" % [_queue.size(), _stat_cells,
				(Time.get_ticks_msec() - t0) / 1000.0])
		if Time.get_ticks_msec() - t0 > max_seconds * 1000.0:
			push_warning("PlanetScatter: build_until_stable timed out")
			break
	_update_lods()
	_create_bodies(1 << 30)


func is_idle() -> bool:
	return _queue.is_empty() and _jobs.is_empty()


func get_stats() -> Dictionary:
	var per := {}
	var inst := 0
	var tris := 0
	var nodes := 0
	for k in _patches:
		var p: Patch = _patches[k]
		if p.node == null:
			continue
		nodes += 1
		inst += p.count
		var m := p.node.multimesh.mesh
		var t := ScatterAssets.triangle_count(m) * p.count
		tris += t
		var nm := p.layer.src.name + ("_far" if p.ring == 1 else "")
		var e: Dictionary = per.get(nm, {"patches": 0, "instances": 0, "tris": 0})
		e["patches"] += 1
		e["instances"] += p.count
		e["tris"] += t
		per[nm] = e
	var bodies := 0
	for k in _patches:
		if (_patches[k] as Patch).body:
			bodies += 1
	return {"patch_nodes": nodes, "instances": inst, "tris_max": tris, "bodies": bodies,
		"cells_built": _stat_cells, "avg_cell_ms": _stat_cell_ms / maxf(_stat_cells, 1),
		"queued": _queue.size(), "jobs": _jobs.size(), "layers": per, "max_upload_ms": _prof_upload,
		"max_scan_ms": _prof_scan, "max_dispatch_bodies_ms": _prof_bodies}


# ---------------------------------------------------------------------------------------------
# Frame loop
# ---------------------------------------------------------------------------------------------

func _process(_dt: float) -> void:
	if not _ready_to_run or not enabled:
		return
	_update_focus()
	var t0 := Time.get_ticks_usec()
	_collect(max_uploads_per_frame, upload_budget_ms)
	_prof_upload = maxf(_prof_upload, (Time.get_ticks_usec() - t0) / 1000.0)
	var t1 := Time.get_ticks_usec()
	_scan(false)
	var t2 := Time.get_ticks_usec()
	_dispatch(max_jobs)
	_create_bodies(max_bodies_per_frame)
	var t3 := Time.get_ticks_usec()
	_prof_scan = maxf(_prof_scan, (t2 - t1) / 1000.0)
	_prof_bodies = maxf(_prof_bodies, (t3 - t2) / 1000.0)


func _update_focus() -> void:
	if _manual_focus:
		pass
	elif focus_node and is_instance_valid(focus_node):
		_focus = planet.to_local(focus_node.global_position)
	elif planet and planet.terrain:
		_focus = planet.terrain.focus
	if _focus.distance_squared_to(_last_ground_focus) > 25.0:
		_last_ground_focus = _focus
		_ground_h = gen.get_height(_focus)


func _altitude() -> float:
	return _focus.length() - radius - _ground_h


## Recomputes wanted patches for every layer/ring whose focus moved enough.
func _scan(force: bool) -> void:
	var alt := _altitude()
	if alt > rules.max_altitude * (1.1 if _active else 1.0):
		if _active:
			clear(false)
		return
	_active = true
	var did := false
	# Non-forced: at most one layer ring per frame (round robin) to spread the main-thread cost.
	var total := 0
	for L in _layers:
		total += 2 if L.has_far else 1
	for step in total:
		var idx := (_scan_cursor + step) % total
		var L: LayerRT
		var ring := 0
		var c := 0
		for LL in _layers:
			var nr := 2 if LL.has_far else 1
			if idx < c + nr:
				L = LL
				ring = idx - c
				break
			c += nr
		var cs := L.cell_m * (L.src.far_factor if ring == 1 else 1)
		if not force and _focus.distance_to(L.scan_pos[ring]) < cs * 0.3:
			continue
		L.scan_pos[ring] = _focus
		_scan_ring(L, ring, alt)
		did = true
		if not force:
			_scan_cursor = (idx + 1) % total
			break
	if did:
		_update_lods()
		_queue.sort_custom(func(a: PatchJob, b: PatchJob) -> bool: return a.prio < b.prio)
		_evict_grids()


func _scan_ring(L: LayerRT, ring: int, alt: float) -> void:
	var s := L.src
	var cs := L.cell_m * (s.far_factor if ring == 1 else 1)
	var n := L.far_n if ring == 1 else L.n_cells
	var rmax := s.max_distance if ring == 1 else (L.near_max + s.fade_length * 0.5 if L.has_far else s.max_distance)
	var cell_r := cs * 0.8
	var fdir := _focus.normalized()
	var ground_r := radius + _ground_h
	var wanted := {}
	var rr := sqrt(maxf(0.0, (rmax + cell_r) * (rmax + cell_r) - alt * alt))
	if rr > 0.0:
		var c0 := dir_to_cell(fdir, n)
		var k := ceili((rr + cell_r) / (cs * 0.7)) + 1
		if c0.y - k >= 0 and c0.y + k < n and c0.z - k >= 0 and c0.z + k < n:
			# common case: the ring stays on one cube face -> enumerate cells directly
			for j in range(c0.z - k, c0.z + k + 1):
				for i in range(c0.y - k, c0.y + k + 1):
					var center := cell_center_dir(c0.x, i, j, n) * ground_r
					if center.distance_to(_focus) <= rmax + cell_r:
						wanted[_key(ring, L.index, c0.x, i, j)] = Vector3i(c0.x, i, j)
		else:
			# near a cube edge: sample the tangent disc and map samples to cells
			var g := fdir * ground_r
			var t1 := fdir.cross(Vector3.UP if absf(fdir.y) < 0.9 else Vector3.RIGHT).normalized()
			var t2 := fdir.cross(t1)
			var step := cs * 0.5
			var ks := ceili(rr / step)
			var lim := (rr / step) * (rr / step)
			for y in range(-ks, ks + 1):
				for x in range(-ks, ks + 1):
					if x * x + y * y > lim + 1.0:
						continue
					var d := (g + t1 * (x * step) + t2 * (y * step)).normalized()
					var c := dir_to_cell(d, n)
					var key := _key(ring, L.index, c.x, c.y, c.z)
					if wanted.has(key):
						continue
					var center := cell_center_dir(c.x, c.y, c.z, n) * ground_r
					if center.distance_to(_focus) > rmax + cell_r:
						continue
					wanted[key] = c
	# drop patches that left the ring (with hysteresis), queue new ones
	var mine: Dictionary = L.patch_keys[ring]
	for key in mine.keys():
		if wanted.has(key):
			continue
		var p: Patch = _patches.get(key)
		if p == null:
			mine.erase(key)
		elif p.center.distance_to(_focus) > rmax + cell_r + cs * 0.5:
			_free_patch(p)
	for key in _pending.keys():
		var jb: PatchJob = _pending[key]
		if jb.layer == L and jb.ring == ring and jb.task < 0 and not wanted.has(key):
			_queue.erase(jb)
			_pending.erase(key)
	for key in wanted:
		if _patches.has(key):
			continue
		var c: Vector3i = wanted[key]
		var center := cell_center_dir(c.x, c.y, c.z, n) * ground_r
		var dist := center.distance_to(_focus)
		if _pending.has(key):
			(_pending[key] as PatchJob).prio = dist / maxf(rmax, 1.0) + ring * 0.5
			continue
		var job := PatchJob.new()
		job.key = key
		job.layer = L
		job.ring = ring
		job.face = c.x
		job.span = s.far_factor if ring == 1 else 1
		job.i0 = c.y * job.span
		job.j0 = c.z * job.span
		job.center = center
		job.radius = cell_r
		job.prio = dist / maxf(rmax, 1.0) + ring * 0.5
		_pending[key] = job
		_queue.append(job)
	_evict_cache(L)


func _evict_cache(L: LayerRT) -> void:
	if L.cache.size() <= maxi(cache_limit, L.cache_next):
		return
	var keep := L.src.max_distance + L.cell_m * 4.0
	for ck in L.cache.keys():
		var cd: CellData = L.cache[ck]
		if cd.origin.distance_to(_focus) > keep:
			L.cache.erase(ck)
	L.cache_next = int(L.cache.size() * 1.5)


func _update_lods() -> void:
	for key in _patches:
		var p: Patch = _patches[key]
		p.dist = maxf(0.0, p.center.distance_to(_focus) - p.radius)
		if p.node == null or p.ring == 1:
			continue
		var s := p.layer.src
		var lod := 0
		for d in s.lod_distances:
			if p.dist > d * (0.92 if p.lod > lod else 1.08):
				lod += 1
		lod = mini(lod, p.layer.meshes.size() - 1)
		if lod != p.lod:
			p.lod = lod
			p.node.multimesh.mesh = p.layer.meshes[lod]
		var shadow := s.cast_shadows and p.dist < s.shadow_distance
		p.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if collision_enabled and s.collision > 0:
			if p.body == null and not p.body_queued and p.dist < s.collision_distance and p.count > 0:
				p.body_queued = true
				_body_queue.append(p)
			elif p.body and p.dist > s.collision_distance * 1.3 + p.radius:
				p.body.queue_free()
				p.body = null


func _dispatch(limit: int) -> void:
	while _jobs.size() < limit and not _queue.is_empty():
		var job: PatchJob = _queue.pop_front()
		var L := job.layer
		for cj in job.span:
			for ci in job.span:
				var ck := _key(0, L.index, job.face, job.i0 + ci, job.j0 + cj)
				if L.cache.has(ck):
					job.cached[ck] = L.cache[ck]
		job.task = WorkerThreadPool.add_task(_run_job.bind(job), false, "scatter")
		_jobs.append(job)


## Uploads finished jobs. `block` waits for every running job (never call is_task_completed()
## on a task that was already waited for: its id is invalid afterwards).
func _collect(max_count: int, budget_ms: float, block := false) -> void:
	var t0 := Time.get_ticks_usec()
	var done := 0
	var i := 0
	while i < _jobs.size():
		var job := _jobs[i]
		if not block and not WorkerThreadPool.is_task_completed(job.task):
			i += 1
			continue
		if done >= max_count or (Time.get_ticks_usec() - t0) / 1000.0 > budget_ms:
			break
		WorkerThreadPool.wait_for_task_completion(job.task)
		_jobs.remove_at(i)
		_pending.erase(job.key)
		for ck in job.new_cells:
			job.layer.cache[ck] = job.new_cells[ck]
			_stat_cells += 1
		_stat_cell_ms += job.ms
		_upload(job)
		done += 1


func _upload(job: PatchJob) -> void:
	var L := job.layer
	var s := L.src
	var p := Patch.new()
	p.key = job.key
	p.layer = L
	p.ring = job.ring
	p.center = job.center
	p.radius = job.radius
	p.count = job.count
	if s.collision > 0 and job.ring == 0:
		p.buffer = job.buffer
	_patches[job.key] = p
	L.patch_keys[job.ring][job.key] = true
	if job.count == 0:
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = L.far if job.ring == 1 else L.meshes[0]
	mm.instance_count = job.count
	mm.buffer = job.buffer
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.position = job.origin
	mmi.name = "%s_%d_%d_%d_%d" % [s.name, job.ring, job.face, job.i0, job.j0]
	var fl := s.fade_length
	var fade: Vector4
	if job.ring == 1:
		fade = Vector4(s.far_start - fl, s.far_start, s.max_distance - fl, s.max_distance)
	elif L.has_far:
		fade = Vector4(0, 0, s.far_start - fl, s.far_start)
	else:
		fade = Vector4(0, 0, s.max_distance - fl, s.max_distance)
	mmi.set_instance_shader_parameter("fade_range", fade)
	if s.thin_start >= 0.0:
		mmi.set_instance_shader_parameter("thin_range", Vector3(s.thin_start, s.max_distance, s.thin_keep))
	mmi.set_instance_shader_parameter("patch_origin", Vector3(fposmod(job.origin.x, 4096.0),
		fposmod(job.origin.y, 4096.0), fposmod(job.origin.z, 4096.0)))
	mmi.set_instance_shader_parameter("sway_height", s.sway_height)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = s.max_distance + job.radius * 2.0
	mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mmi)
	p.node = mmi
	p.dist = maxf(0.0, p.center.distance_to(_focus) - p.radius)
	if job.ring == 0:
		p.lod = -1
		_update_lods_one(p)


func _update_lods_one(p: Patch) -> void:
	var s := p.layer.src
	var lod := 0
	for d in s.lod_distances:
		if p.dist > d:
			lod += 1
	lod = mini(lod, p.layer.meshes.size() - 1)
	p.lod = lod
	p.node.multimesh.mesh = p.layer.meshes[lod]
	if s.cast_shadows and p.dist < s.shadow_distance:
		p.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if collision_enabled and s.collision > 0 and p.dist < s.collision_distance and not p.body_queued:
		p.body_queued = true
		_body_queue.append(p)


func _free_patch(p: Patch) -> void:
	if p.node:
		p.node.queue_free()
		p.node = null
	p.body = null
	_patches.erase(p.key)
	p.layer.patch_keys[p.ring].erase(p.key)
	_body_queue.erase(p)


# ---------------------------------------------------------------------------------------------
# Collision
# ---------------------------------------------------------------------------------------------

func _create_bodies(limit: int) -> void:
	var made := 0
	while made < limit and not _body_queue.is_empty():
		var p: Patch = _body_queue.pop_front()
		p.body_queued = false
		if p.node == null or p.body != null or not _patches.has(p.key):
			continue
		var s := p.layer.src
		if p.dist > s.collision_distance * 1.3 + p.radius:
			continue
		# Shape owners on one StaticBody3D (no CollisionShape3D nodes: much cheaper to create).
		var body := StaticBody3D.new()
		body.name = "Collision"
		var buf := p.buffer
		for i in p.count:
			var q := i * FLOATS
			var bx := Vector3(buf[q], buf[q + 4], buf[q + 8])
			var by := Vector3(buf[q + 1], buf[q + 5], buf[q + 9])
			var bz := Vector3(buf[q + 2], buf[q + 6], buf[q + 10])
			var o := Vector3(buf[q + 3], buf[q + 7], buf[q + 11])
			var sc := by.length()
			var basis := Basis(bx / sc, by / sc, bz / sc)
			var shape: Shape3D
			var xf: Transform3D
			match s.collision:
				1:
					var cap := CapsuleShape3D.new()
					cap.radius = s.collision_size.x * sc
					cap.height = maxf(s.collision_size.y * sc, cap.radius * 2.0 + 0.01)
					shape = cap
					xf = Transform3D(basis, o + by * (s.collision_size.y * 0.5))
				2:
					var sp := SphereShape3D.new()
					sp.radius = s.collision_size.x * sc
					shape = sp
					xf = Transform3D(basis, o + by * s.collision_size.y)
				_:
					shape = p.layer.convex
					xf = Transform3D(Basis(bx, by, bz), o)
			if shape == null:
				continue
			var owner := body.create_shape_owner(body)
			body.shape_owner_add_shape(owner, shape)
			body.shape_owner_set_transform(owner, xf)
		p.node.add_child(body)
		p.body = body
		made += 1


# ---------------------------------------------------------------------------------------------
# Grid helpers (equi-angular cube map: near-uniform cells, analytic both ways)
# ---------------------------------------------------------------------------------------------

static func _key(ring: int, layer: int, face: int, i: int, j: int) -> int:
	return ((((ring * 64 + layer) * 8 + face) << 21 | i) << 21) | j


static func face_dir(face: int, a: float, b: float) -> Vector3:
	return (FACE_N[face] + FACE_U[face] * tan(a * PI * 0.25) + FACE_V[face] * tan(b * PI * 0.25)).normalized()


## Vector3i(face, i, j) of the cell containing direction d on an n x n grid per face.
static func dir_to_cell(d: Vector3, n: int) -> Vector3i:
	var ax := absf(d.x)
	var ay := absf(d.y)
	var az := absf(d.z)
	var face := 0
	if ax >= ay and ax >= az:
		face = 0 if d.x > 0.0 else 1
	elif ay >= az:
		face = 2 if d.y > 0.0 else 3
	else:
		face = 4 if d.z > 0.0 else 5
	var dn := d.dot(FACE_N[face])
	var a := atan(d.dot(FACE_U[face]) / dn) * 4.0 / PI
	var b := atan(d.dot(FACE_V[face]) / dn) * 4.0 / PI
	var i := clampi(int(floorf((a + 1.0) * 0.5 * n)), 0, n - 1)
	var j := clampi(int(floorf((b + 1.0) * 0.5 * n)), 0, n - 1)
	return Vector3i(face, i, j)


static func cell_center_dir(face: int, i: int, j: int, n: int) -> Vector3:
	var da := 2.0 / n
	return face_dir(face, -1.0 + (i + 0.5) * da, -1.0 + (j + 0.5) * da)


# ---------------------------------------------------------------------------------------------
# Worker side
# ---------------------------------------------------------------------------------------------

func _run_job(job: PatchJob) -> void:
	var t0 := Time.get_ticks_usec()
	var L := job.layer
	var cells: Array[CellData] = []
	for cj in job.span:
		for ci in job.span:
			var ck := _key(0, L.index, job.face, job.i0 + ci, job.j0 + cj)
			var cd: CellData = job.cached.get(ck)
			if cd == null:
				cd = _build_cell(L, job.face, job.i0 + ci, job.j0 + cj)
				job.new_cells[ck] = cd
			cells.append(cd)
	var total := 0
	for cd in cells:
		total += cd.count
	job.count = total
	if job.span == 1:
		job.origin = cells[0].origin
		job.buffer = cells[0].data
	else:
		var cdir := cell_center_dir(job.face, job.i0 / job.span, job.j0 / job.span, L.far_n)
		job.origin = cdir * (radius + gen.get_height(cdir))
		var buf := PackedFloat32Array()
		for cd in cells:
			if cd.count == 0:
				continue
			var w := buf.size()
			buf.append_array(cd.data)
			var sh := cd.origin - job.origin
			for k in cd.count:
				var q := w + k * FLOATS
				buf[q + 3] += sh.x
				buf[q + 7] += sh.y
				buf[q + 11] += sh.z
		job.buffer = buf
	job.ms = (Time.get_ticks_usec() - t0) / 1000.0 / maxf(job.new_cells.size(), 1)


## Terrain + biome samples of one cell, shared by every layer on the same cell grid.
class CellGrid:
	var g := 4                 # height grid quads per side
	var bs := 1                # biome stride (in height-grid steps)
	var bg := 5                # biome grid points per side
	var hts := PackedFloat32Array()
	var nrm := PackedVector3Array()
	var bio := PackedFloat32Array()   # bg*bg*ScatterBiome.COUNT
	var origin := Vector3.ZERO
	var area := 0.0


var _grid_cache := {}
var _grid_mutex := Mutex.new()


static func _grid_key(n: int, g: int, face: int, i: int, j: int) -> int:
	return (((n * 16 + g) * 8 + face) << 42) | (i << 21) | j


func _get_grid(L: LayerRT, face: int, i: int, j: int) -> CellGrid:
	var key := _grid_key(L.n_cells, L.grid, face, i, j)
	_grid_mutex.lock()
	var cg: CellGrid = _grid_cache.get(key)
	_grid_mutex.unlock()
	if cg:
		return cg
	cg = _sample_grid(L.n_cells, L.grid, face, i, j)
	_grid_mutex.lock()
	_grid_cache[key] = cg
	_grid_mutex.unlock()
	return cg


func _sample_grid(n: int, G: int, face: int, i: int, j: int) -> CellGrid:
	var cg := CellGrid.new()
	cg.g = G
	var da := 2.0 / n
	var a0 := -1.0 + i * da
	var b0 := -1.0 + j * da
	var g1 := G + 1
	var R := radius
	var hts := PackedFloat32Array()
	hts.resize(g1 * g1)
	var rks := PackedFloat32Array()
	rks.resize(g1 * g1)
	var lvs := PackedFloat32Array()
	lvs.resize(g1 * g1)
	var dirs := PackedVector3Array()
	dirs.resize(g1 * g1)
	var pos := PackedVector3Array()
	pos.resize(g1 * g1)
	for gj in g1:
		for gi in g1:
			var d := face_dir(face, a0 + da * gi / G, b0 + da * gj / G)
			var sm := gen.sample(d, 0.4)
			var k := gj * g1 + gi
			hts[k] = sm.x
			rks[k] = sm.y
			lvs[k] = sm.z
			dirs[k] = d
			pos[k] = d * (R + sm.x)
	var nrm := PackedVector3Array()
	nrm.resize(g1 * g1)
	for gj in g1:
		for gi in g1:
			var k := gj * g1 + gi
			var xa := k - 1 if gi > 0 else k
			var xb := k + 1 if gi < G else k
			var ya := k - g1 if gj > 0 else k
			var yb := k + g1 if gj < G else k
			var nn := (pos[xb] - pos[xa]).cross(pos[yb] - pos[ya]).normalized()
			if nn.dot(dirs[k]) < 0.0:
				nn = -nn
			nrm[k] = nn
	cg.hts = hts
	cg.nrm = nrm
	cg.origin = pos[(G / 2) * g1 + G / 2]
	cg.area = (pos[G] - pos[0]).length() * (pos[G * g1] - pos[0]).length()
	# biome on a coarser grid (~24 m): the attributes are smooth at that scale
	var sp := sqrt(cg.area) / G
	var bs := clampi(int(24.0 / maxf(sp, 0.01)), 1, G)
	while G % bs != 0:
		bs -= 1
	cg.bs = bs
	cg.bg = G / bs + 1
	var C := ScatterBiome.COUNT
	cg.bio.resize(cg.bg * cg.bg * C)
	for bj in cg.bg:
		for bi in cg.bg:
			var k := (bj * bs) * g1 + bi * bs
			biome.evaluate_into(cg.bio, (bj * cg.bg + bi) * C, dirs[k], hts[k], rks[k], lvs[k], nrm[k])
	return cg


## Main thread: drop shared grids far from the focus.
func _evict_grids() -> void:
	if _grid_cache.size() < maxi(cache_limit * 2, _grid_next):
		return
	var keep := 0.0
	for L in _layers:
		keep = maxf(keep, L.src.max_distance)
	keep += 600.0
	_grid_mutex.lock()
	for k in _grid_cache.keys():
		var cg: CellGrid = _grid_cache[k]
		if cg.origin.distance_to(_focus) > keep:
			_grid_cache.erase(k)
	_grid_next = int(_grid_cache.size() * 1.5)
	_grid_mutex.unlock()


## Deterministic instances of one near cell. Runs on worker threads (read-only shared state).
func _build_cell(L: LayerRT, face: int, i: int, j: int) -> CellData:
	var cd := CellData.new()
	var cg := _get_grid(L, face, i, j)
	cd.origin = cg.origin
	var expected := L.density * cg.area
	if expected <= 0.0:
		return cd
	var C := ScatterBiome.COUNT
	var bg := cg.bg
	# rule weight + moisture + snow + alien canopy regions on the biome grid (interpolated per candidate)
	const WS := 5
	var wgt := PackedFloat32Array()
	wgt.resize(bg * bg * WS)
	var nr := L.rule_attr.size()
	var any := false
	for q in bg * bg:
		var o := q * C
		var w := 1.0
		for r in nr:
			var v := cg.bio[o + L.rule_attr[r]]
			var sft := L.rule_soft[r]
			w *= clampf((v - L.rule_lo[r]) / sft + 0.5, 0.0, 1.0) * clampf((L.rule_hi[r] - v) / sft + 0.5, 0.0, 1.0)
		wgt[q * WS] = w
		wgt[q * WS + 1] = cg.bio[o + ScatterBiome.A_MOIST]
		wgt[q * WS + 2] = cg.bio[o + ScatterBiome.A_SNOW]
		wgt[q * WS + 3] = cg.bio[o + ScatterBiome.A_ALIEN_B]
		wgt[q * WS + 4] = cg.bio[o + ScatterBiome.A_ALIEN_C]
		any = any or w > 0.001
	if not any:
		return cd
	var n := L.n_cells
	var da := 2.0 / n
	var a0 := -1.0 + i * da
	var b0 := -1.0 + j * da
	var G := cg.g
	var g1 := G + 1
	var R := radius
	var hts := cg.hts
	var nrm := cg.nrm
	var ks := maxi(1, ceili(sqrt(expected)))
	var p0 := expected / float(ks * ks)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([L.seed, face, i, j])
	var out := PackedFloat32Array()
	var cnt := 0
	var inv_k := 1.0 / ks
	for sb in ks:
		for sa in ks:
			if rng.randf() >= p0:
				continue
			var fa := (sa + rng.randf()) * inv_k
			var fb := (sb + rng.randf()) * inv_k
			var bx := fa * (bg - 1)
			var by := fb * (bg - 1)
			var bix := mini(int(bx), bg - 2)
			var biy := mini(int(by), bg - 2)
			var tx := bx - bix
			var ty := by - biy
			var q00 := (biy * bg + bix) * WS
			var q10 := q00 + WS
			var q01 := q00 + bg * WS
			var q11 := q01 + WS
			var w := lerpf(lerpf(wgt[q00], wgt[q10], tx), lerpf(wgt[q01], wgt[q11], tx), ty)
			if w <= 0.001:
				continue
			var wb := w
			var d := face_dir(face, a0 + da * fa, b0 + da * fb)
			if L.cluster:
				var pc := d * R
				var cn := L.cluster.get_noise_3d(pc.x, pc.y, pc.z)
				w *= clampf((cn - L.cluster_thr) / L.cluster_soft + 0.5, 0.0, 1.0)
			if rng.randf() >= w:
				continue
			var moist := lerpf(lerpf(wgt[q00 + 1], wgt[q10 + 1], tx), lerpf(wgt[q01 + 1], wgt[q11 + 1], tx), ty)
			var snow := lerpf(lerpf(wgt[q00 + 2], wgt[q10 + 2], tx), lerpf(wgt[q01 + 2], wgt[q11 + 2], tx), ty)
			# height / normal (bilinear on the height grid, or exact)
			var gx := fa * G
			var gy := fb * G
			var gix := mini(int(gx), G - 1)
			var giy := mini(int(gy), G - 1)
			var ux := gx - gix
			var uy := gy - giy
			var k00 := giy * g1 + gix
			var h := 0.0
			if L.exact:
				h = gen.sample(d, 0.4).x
			else:
				h = lerpf(lerpf(hts[k00], hts[k00 + 1], ux), lerpf(hts[k00 + g1], hts[k00 + g1 + 1], ux), uy)
			var up := d
			if L.align > 0.0:
				var nn := (nrm[k00].lerp(nrm[k00 + 1], ux)).lerp(nrm[k00 + g1].lerp(nrm[k00 + g1 + 1], ux), uy)
				up = d.lerp(nn.normalized(), L.align).normalized()
			var sc := lerpf(L.scale_lo, L.scale_hi, rng.randf()) * (1.0 - L.edge_scale * (1.0 - clampf(wb * 1.6, 0.0, 1.0)))
			var ref := Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT
			var bxv := ref.cross(up).normalized()
			var bzv := bxv.cross(up)
			var yaw := rng.randf() * TAU
			var cy := cos(yaw)
			var sy := sin(yaw)
			var x2 := bxv * cy + bzv * sy
			var z2 := bzv * cy - bxv * sy
			var basis := Basis(x2, up, z2)
			if L.tilt > 0.0:
				var ta := rng.randf() * TAU
				var axis := x2 * cos(ta) + z2 * sin(ta)
				basis = Basis(axis, rng.randf() * L.tilt) * basis
			var c0 := basis.x * sc
			var c1 := basis.y * sc
			var c2 := basis.z * sc
			if L.height_jit > 0.0:
				c1 *= 1.0 + (rng.randf() * 2.0 - 1.0) * L.height_jit
			var cw := snow
			if L.tint:
				# canopy region code for flora shaders: w = snow + 2 * region (1 purple, 2 teal)
				var ab := lerpf(lerpf(wgt[q00 + 3], wgt[q10 + 3], tx), lerpf(wgt[q01 + 3], wgt[q11 + 3], tx), ty)
				var ac := lerpf(lerpf(wgt[q00 + 4], wgt[q10 + 4], tx), lerpf(wgt[q01 + 4], wgt[q11 + 4], tx), ty)
				var rr := rng.randf()
				var reg := 1.0 if rr < ab * 0.65 else (2.0 if rr < (ab + ac) * 0.65 else 0.0)
				cw = minf(snow, 0.99) + 2.0 * reg
			var o := d * (R + h) - up * (L.sink * sc) - cd.origin
			out.append_array([c0.x, c1.x, c2.x, o.x, c0.y, c1.y, c2.y, o.y, c0.z, c1.z, c2.z, o.z,
				rng.randf(), rng.randf(), moist, cw])
			cnt += 1
	cd.data = out
	cd.count = cnt
	return cd
