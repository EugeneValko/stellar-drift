class_name PlanetTerrain
extends Node3D
## Cube-sphere quadtree terrain (6 faces x quadtree of 33x33 chunks with skirts).
##
## Everything is in this node's local space ("planet-local"), so the planet can be moved
## or rotated by a floating-origin system freely. Call `set_focus(local_pos)` every frame
## (Planet does that from the active camera), or let `auto_focus_camera` do it.
##
## Meshes are generated on WorkerThreadPool; the main thread only uploads finished
## arrays (bounded per frame). Collision (ConcavePolygonShape3D) is created for the
## finest chunks near the focus only.

signal chunk_built(level: int)

## Edge order matches TerrainGenerator._edge_lists(): bottom (-v), right (+u), top (+v), left (-u).
const EDGE_DX: Array[int] = [0, 1, 0, -1]
const EDGE_DY: Array[int] = [-1, 0, 1, 0]

## Split when distance-to-chunk < chunk_edge * lod_factor.
@export var lod_factor := 1.0
## Chunks are always split at least down to this level (orbit-view quality).
@export var min_level := 2
## Chunks entirely below the horizon (occluder sphere through the ground under the focus,
## lowered by this margin) are not refined.
@export var horizon_margin := 250.0
## Target vertex spacing at the finest level (m).
@export var finest_quad := 0.4
## Max mesh uploads per frame and per-frame time budget for uploads (ms).
@export var max_uploads_per_frame := 6
## Max quadtree splits per frame (each split samples 20 heights on the main thread).
@export var max_splits_per_frame := 8
@export var upload_budget_ms := 3.0
## Worker tasks in flight (0 = cores - 2, leaving room for the main and render threads).
@export var max_jobs := 0
## Collision for chunks whose level >= max_level - collision_levels + 1 and close to focus.
@export var collision_levels := 2
@export var collision_radius := 300.0
@export var cast_shadows := true
## When true the terrain follows the current viewport camera by itself.
@export var auto_focus_camera := false
## VisualInstance3D render layers of the chunk meshes (SolarSystem gives each planet group its
## own layer so it can be lit by its own directional light).
@export_flags_3d_render var render_layers := 1

var config: PlanetConfig
var generator: TerrainGenerator
var material: Material
var max_level := 10
var focus := Vector3(0, 0, 1e9)

var _roots: Array[ChunkNode] = []
var _queue: Array[ChunkNode] = []
var _jobs: Array[ChunkJob] = []
var _node_count := 0
var _visible_count := 0
var _built_total := 0
var _build_ms_total := 0.0
var _build_ms_max := 0.0
var _ready_to_run := false
var _focus_r := 0.0
var _tree_dirty := true
var _splits_left := 0
var _body_queue: Array[ChunkNode] = []
var _last_focus := Vector3(INF, INF, INF)
var _last_ground_h := 0.0
var _prof_collect := 0.0
var _prof_update := 0.0
var _prof_dispatch := 0.0
var _prof_body := 0.0
var _prof_mesh := 0.0
var _display_dirty := false
var _shown_list: Array[ChunkNode] = []
var _occluder_r := 0.0


class ChunkNode:
	var face := 0
	var level := 0
	var u0 := 0.0
	var v0 := 0.0
	var size := 2.0
	var edge_m := 0.0
	var center := Vector3.ZERO      # planet-local surface point at chunk centre
	var bound := 0.0
	var horiz := 0.0
	var half_range := 0.0
	var parent: ChunkNode
	var children: Array[ChunkNode] = []
	var mesh: MeshInstance3D
	var body: StaticBody3D
	var shape: ConcavePolygonShape3D
	var built := false
	var pending := false
	var want_split := false
	var cover := false        # this node or its subtree can be displayed (set by _refine)
	var kids_cover := false   # all children can be displayed
	var shown := false
	var edge_flags := 0
	var ix := 0
	var iy := 0
	var job: ChunkJob


## One worker build. The worker writes only `result` / `ms`; the main thread reads them
## after the task completed.
class ChunkJob:
	var node: ChunkNode
	var task := -1
	var result: Dictionary
	var ms := 0.0


## Builds the terrain for `cfg`. `mat` is the terrain ShaderMaterial (Planet creates it).
func setup(cfg: PlanetConfig, mat: Material) -> void:
	clear()
	config = cfg
	material = mat
	generator = TerrainGenerator.new(cfg)
	var edge0 := cfg.radius * PI * 0.5
	var quad0 := edge0 / float(TerrainGenerator.GRID - 1)
	max_level = clampi(ceili(log(quad0 / finest_quad) / log(2.0)), 1, 18)
	for f in 6:
		var n := ChunkNode.new()
		n.face = f
		n.u0 = -1.0
		n.v0 = -1.0
		n.size = 2.0
		_init_node(n)
		_roots.append(n)
	_ready_to_run = true


func clear() -> void:
	_ready_to_run = false
	for j in _jobs:
		WorkerThreadPool.wait_for_task_completion(j.task)
	_jobs.clear()
	_queue.clear()
	for r in _roots:
		_free_subtree(r, true)
	_roots.clear()


func _exit_tree() -> void:
	for j in _jobs:
		WorkerThreadPool.wait_for_task_completion(j.task)
	_jobs.clear()


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Focus point (camera / ship) in planet-local space.
func set_focus(local_pos: Vector3) -> void:
	focus = local_pos


## Terrain height (m above config.radius) along a planet-local direction.
func get_height(dir: Vector3) -> float:
	return generator.get_height(dir)


## Planet-local surface point along a direction.
func get_surface_point(dir: Vector3) -> Vector3:
	var d := dir.normalized()
	return d * (config.radius + generator.get_height(d))


## Altitude of a planet-local point above the terrain surface.
func get_altitude(local_pos: Vector3) -> float:
	return local_pos.length() - config.radius - generator.get_height(local_pos)


## Changes the coarsest displayed level at runtime (far planets: 0 = 6 chunks).
func set_min_level(level: int) -> void:
	if level == min_level:
		return
	min_level = level
	_tree_dirty = true


## Render layers of all existing and future chunk meshes.
func set_render_layers(layers_mask: int) -> void:
	render_layers = layers_mask
	_for_each_mesh(func(mi: MeshInstance3D) -> void: mi.layers = layers_mask)


## Shadow casting of all existing and future chunk meshes (only the focus planet should cast).
func set_cast_shadows(on: bool) -> void:
	if on == cast_shadows:
		return
	cast_shadows = on
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_for_each_mesh(func(mi: MeshInstance3D) -> void: mi.cast_shadow = mode)


func _for_each_mesh(f: Callable) -> void:
	var stack: Array[ChunkNode] = []
	stack.append_array(_roots)
	while not stack.is_empty():
		var n: ChunkNode = stack.pop_back()
		if n.mesh:
			f.call(n.mesh)
		stack.append_array(n.children)


func get_stats() -> Dictionary:
	return {
		"nodes": _node_count, "visible": _visible_count, "queued": _queue.size(),
		"jobs": _jobs.size(), "built": _built_total, "max_level": max_level,
		"avg_build_ms": _build_ms_total / maxf(_built_total, 1),
		"max_build_ms": _build_ms_max,
		"max_ms_collect": _prof_collect, "max_ms_update": _prof_update,
		"max_ms_dispatch": _prof_dispatch, "max_ms_body": _prof_body, "max_ms_mesh": _prof_mesh,
	}


## True when no chunk is waiting to be built for the current focus.
func is_idle() -> bool:
	return _queue.is_empty() and _jobs.is_empty()


## Blocks until the LOD for the current focus is complete (capture / loading screens).
func build_until_stable(max_seconds := 120.0) -> void:
	var t0 := Time.get_ticks_msec()
	while true:
		_update_tree(true)
		_dispatch(true)
		_collect(1 << 30, 1e9, true)
		_update_tree(true)
		if is_idle():
			break
		if Time.get_ticks_msec() - t0 > max_seconds * 1000.0:
			push_warning("PlanetTerrain: build_until_stable timed out")
			break
	_update_tree(true)
	_create_bodies(1 << 30)


# ---------------------------------------------------------------------------
# Frame loop
# ---------------------------------------------------------------------------

func _process(_dt: float) -> void:
	if not _ready_to_run:
		return
	if auto_focus_camera:
		var cam := get_viewport().get_camera_3d()
		if cam:
			focus = to_local(cam.global_position)
	var t0 := Time.get_ticks_usec()
	_collect(max_uploads_per_frame, upload_budget_ms)
	_create_bodies(1)
	var t1 := Time.get_ticks_usec()
	# Re-evaluate the tree only when something changed (focus moved by >2% of altitude,
	# or new chunks arrived): keeps the idle cost near zero.
	var alt := maxf(focus.length() - config.radius - _last_ground_h, 0.0)
	var thr := maxf(0.5, alt * 0.02)
	if _tree_dirty or focus.distance_squared_to(_last_focus) > thr * thr:
		_tree_dirty = false
		_last_focus = focus
		_update_tree()
	var t2 := Time.get_ticks_usec()
	_dispatch(false)
	var t3 := Time.get_ticks_usec()
	_prof_collect = maxf(_prof_collect, (t1 - t0) / 1000.0)
	_prof_update = maxf(_prof_update, (t2 - t1) / 1000.0)
	_prof_dispatch = maxf(_prof_dispatch, (t3 - t2) / 1000.0)


func _update_tree(unlimited := false) -> void:
	_splits_left = 1 << 30 if unlimited else max_splits_per_frame
	_visible_count = 0
	_focus_r = focus.length()
	if _focus_r > 1.0:
		_last_ground_h = generator.sample(focus / _focus_r, 1e9).x
		var ground := config.radius + _last_ground_h
		if config.has_ocean_surface():
			ground = maxf(ground, config.get_ocean_radius())
		_occluder_r = minf(ground, _focus_r) - horizon_margin
	for r in _roots:
		_refine(r)
	_shown_list.clear()
	for r in _roots:
		_display(r)
	if _display_dirty:
		_display_dirty = false
		_update_edge_flags()


func _init_node(n: ChunkNode) -> void:
	# Estimate the chunk's vertical extent from 5 full-detail samples (centre + corners)
	# so the split test is tight; refined with the real min/max once the mesh is built.
	var c := TerrainGenerator.face_point(n.face, n.u0 + n.size * 0.5, n.v0 + n.size * 0.5)
	var hc := generator.sample(c, 1e9).x
	var lo := hc
	var hi := hc
	var horiz := 0.0
	for k in 4:
		var d := TerrainGenerator.face_point(n.face, n.u0 + n.size * float(k & 1), n.v0 + n.size * float(k >> 1))
		var h := generator.sample(d, 1e9).x
		lo = minf(lo, h)
		hi = maxf(hi, h)
		horiz = maxf(horiz, (c - d).length() * config.radius)
	n.horiz = horiz
	n.center = c * (config.radius + (lo + hi) * 0.5)
	n.edge_m = n.size * 0.5 * config.radius * PI * 0.5
	n.ix = int((n.u0 + 1.0) / n.size + 0.5)
	n.iy = int((n.v0 + 1.0) / n.size + 0.5)
	n.half_range = (hi - lo) * 0.5 + n.edge_m * 0.05
	n.bound = horiz + n.half_range
	_node_count += 1


func _should_split(n: ChunkNode) -> bool:
	if n.level >= max_level:
		return false
	if n.level < min_level:
		return true
	var k := lod_factor * (1.1 if n.want_split else 1.0)  # hysteresis
	var lim := n.edge_m * k
	var far := lim + n.bound
	if focus.distance_squared_to(n.center) >= far * far:
		return false   # cheap reject: box distance >= |rel| - bound
	if _distance_to(n) >= lim:
		return false
	return n.level < 3 or not _below_horizon(n)


## Distance from the focus to the chunk's (curved) box: horizontal and vertical parts
## are measured separately so tall mountain chunks are not over-refined.
func _distance_to(n: ChunkNode) -> float:
	var r := n.center.length()
	var up := n.center / r
	var rel := focus - n.center
	var dv := rel.dot(up)
	var dh := (rel - up * dv).length()
	var a := maxf(dh - n.horiz, 0.0)
	var b := maxf(absf(dv) - n.half_range, 0.0)
	return sqrt(a * a + b * b)


## True when the whole chunk is hidden behind the planet's curvature as seen from the focus.
func _below_horizon(n: ChunkNode) -> bool:
	if _focus_r <= _occluder_r:
		return false
	var top_r := n.center.length() + n.bound
	if top_r <= _occluder_r:
		return true
	var ang := acos(clampf(focus.dot(n.center) / (_focus_r * n.center.length()), -1.0, 1.0))
	var chunk_ang := n.horiz / maxf(n.center.length(), 1.0)
	var vis := acos(_occluder_r / _focus_r) + acos(clampf(_occluder_r / top_r, -1.0, 1.0))
	return ang - chunk_ang > vis


func _refine(n: ChunkNode) -> void:
	n.want_split = _should_split(n)
	if n.want_split and n.children.is_empty():
		if _splits_left <= 0:
			n.want_split = false
			_tree_dirty = true   # continue next frame
		else:
			_splits_left -= 1
	if n.want_split:
		if n.children.is_empty():
			var h := n.size * 0.5
			for q in 4:
				var c := ChunkNode.new()
				c.face = n.face
				c.level = n.level + 1
				c.size = h
				c.u0 = n.u0 + h * float(q & 1)
				c.v0 = n.v0 + h * float(q >> 1)
				c.parent = n
				_init_node(c)
				n.children.append(c)
		var all := true
		for c in n.children:
			_refine(c)
			all = all and c.cover
		n.kids_cover = all
		if not all:
			_request(n)   # fallback while children build
	else:
		_request(n)
		if n.built and not n.children.is_empty():
			for c in n.children:
				_free_subtree(c, true)
			n.children.clear()
		n.kids_cover = _covered_by_children(n)
	n.cover = n.built or n.kids_cover


func _covered_by_children(n: ChunkNode) -> bool:
	if n.children.is_empty():
		return false
	for c in n.children:
		if not _can_cover(c):
			return false
	return true


func _can_cover(n: ChunkNode) -> bool:
	return n.built or _covered_by_children(n)


## Shows the leaves of the desired tree (falling back to parents while children build).
func _display(n: ChunkNode) -> void:
	var use_children := (n.want_split or not n.built) and n.kids_cover
	if use_children:
		_set_shown(n, false)
		for c in n.children:
			_display(c)
	else:
		_set_shown(n, n.built)
		for c in n.children:
			_hide_subtree(c)


func _set_shown(n: ChunkNode, on: bool) -> void:
	on = on and n.mesh != null
	if on:
		_visible_count += 1
		_shown_list.append(n)
	if on == n.shown:
		return
	n.shown = on
	_display_dirty = true
	if n.mesh:
		n.mesh.visible = on
	if n.body:
		(n.body.get_child(0) as CollisionShape3D).disabled = not on


## For every shown chunk, flags the edges whose neighbour is shown at a coarser level so
## the shader snaps the odd edge vertices onto the neighbour's edge (no T-junction cracks).
func _update_edge_flags() -> void:
	var shown := {}
	for n in _shown_list:
		shown[_key(n.face, n.level, n.ix, n.iy)] = true
	for n in _shown_list:
		var flags := 0
		var span := 1 << n.level
		for e in 4:
			var nx := n.ix + EDGE_DX[e]
			var ny := n.iy + EDGE_DY[e]
			var coarser := false
			if nx < 0 or ny < 0 or nx >= span or ny >= span:
				# neighbour on another cube face: slower geometric lookup
				var hs := n.size * 0.5
				var eps := n.size * 0.001
				var u := n.u0 + hs + float(EDGE_DX[e]) * (hs + eps)
				var v := n.v0 + hs + float(EDGE_DY[e]) * (hs + eps)
				coarser = _shown_level_at(n.face, u, v) < n.level
			elif not shown.has(_key(n.face, n.level, nx, ny)):
				for up in range(1, 3):
					if n.level - up < 0:
						break
					if shown.has(_key(n.face, n.level - up, nx >> up, ny >> up)):
						coarser = true
						break
			if coarser:
				flags |= 1 << e
		if flags != n.edge_flags:
			n.edge_flags = flags
			n.mesh.set_instance_shader_parameter("coarse_edges", flags)


static func _key(face: int, level: int, x: int, y: int) -> int:
	return face | (level << 3) | (x << 8) | (y << 32)


## Level of the chunk shown at face coords (u, v); coordinates outside [-1, 1] are
## re-projected onto the adjacent cube face. Returns a large value if nothing is shown.
func _shown_level_at(face: int, u: float, v: float) -> int:
	if absf(u) > 1.0 or absf(v) > 1.0:
		var c := TerrainGenerator.FACE_N[face] + TerrainGenerator.FACE_U[face] * u \
			+ TerrainGenerator.FACE_V[face] * v
		var ac := c.abs()
		var axis := 0 if ac.x >= ac.y and ac.x >= ac.z else (1 if ac.y >= ac.z else 2)
		face = axis * 2 + (0 if c[axis] > 0.0 else 1)
		c /= ac[axis]
		u = clampf(c.dot(TerrainGenerator.FACE_U[face]), -1.0, 1.0)
		v = clampf(c.dot(TerrainGenerator.FACE_V[face]), -1.0, 1.0)
	var n: ChunkNode = _roots[face]
	while true:
		if n.shown:
			return n.level
		if n.children.is_empty():
			return 1 << 20
		var h := n.size * 0.5
		var q := (1 if u >= n.u0 + h else 0) + (2 if v >= n.v0 + h else 0)
		n = n.children[q]
	return 1 << 20


func _hide_subtree(n: ChunkNode) -> void:
	if n.shown:
		_set_shown(n, false)
	for c in n.children:
		_hide_subtree(c)


func _free_subtree(n: ChunkNode, recursive: bool) -> void:
	if recursive:
		for c in n.children:
			_free_subtree(c, true)
		n.children.clear()
	n.job = null   # an in-flight job is dropped on completion (see _collect)
	if n.pending:
		_queue.erase(n)
		n.pending = false
	if n.mesh:
		n.mesh.queue_free()
		n.mesh = null
	if n.shown:
		n.shown = false
		_display_dirty = true
	n.shape = null
	if n.body:
		n.body.queue_free()
		n.body = null
	n.built = false
	n.parent = null
	_node_count -= 1


func _request(n: ChunkNode) -> void:
	if n.built or n.pending or n.job != null:
		return
	n.pending = true
	_queue.append(n)


func _priority(n: ChunkNode) -> float:
	# coarse first, then nearest
	return focus.distance_to(n.center) / maxf(n.edge_m, 1.0) + float(n.level) * 0.5


func _dispatch(all: bool) -> void:
	if _queue.is_empty():
		return
	var limit := max_jobs if max_jobs > 0 else maxi(OS.get_processor_count() - 2, 1)
	if all:
		limit = maxi(limit * 4, 16)
	if _jobs.size() >= limit:
		return
	while not _queue.is_empty() and _jobs.size() < limit:
		# pick the most urgent request (linear scan: cheaper than sorting every frame)
		var bi := 0
		var bp := INF
		for qi in _queue.size():
			var pr := _priority(_queue[qi])
			if pr < bp:
				bp = pr
				bi = qi
		var n: ChunkNode = _queue[bi]
		_queue[bi] = _queue[_queue.size() - 1]
		_queue.pop_back()
		n.pending = false
		var want_faces := n.level >= max_level - collision_levels + 1
		var skirt := maxf(n.edge_m / float(TerrainGenerator.GRID - 1) * 2.0, 1.0)
		var job := ChunkJob.new()
		job.node = n
		var gen := generator
		var face := n.face
		var u0 := n.u0
		var v0 := n.v0
		var size := n.size
		job.task = WorkerThreadPool.add_task(func() -> void:
			var t := Time.get_ticks_usec()
			var res := gen.build_chunk(face, u0, v0, size, want_faces, skirt)
			job.ms = float(Time.get_ticks_usec() - t) / 1000.0
			job.result = res, false, "terrain chunk")
		n.job = job
		_jobs.append(job)


func _collect(max_count: int, budget_ms: float, block := false) -> void:
	var t0 := Time.get_ticks_usec()
	var done := 0
	var i := 0
	while i < _jobs.size():
		var job: ChunkJob = _jobs[i]
		if not block and not WorkerThreadPool.is_task_completed(job.task):
			i += 1
			continue
		if done >= max_count or float(Time.get_ticks_usec() - t0) / 1000.0 > budget_ms:
			break
		WorkerThreadPool.wait_for_task_completion(job.task)
		_jobs.remove_at(i)
		var n: ChunkNode = job.node
		_built_total += 1
		_build_ms_total += job.ms
		_build_ms_max = maxf(_build_ms_max, job.ms)
		if n.job != job:
			continue   # node was freed / re-requested meanwhile
		n.job = null
		_upload(n, job.result)
		_tree_dirty = true
		done += 1


## Creates at most `count` collision bodies for queued fine chunks near the focus
## (body creation is the most expensive main-thread step, so it is rate-limited).
func _create_bodies(count: int) -> void:
	var i := 0
	while i < _body_queue.size() and count > 0:
		var n: ChunkNode = _body_queue[i]
		if n.mesh == null or n.shape == null:
			_body_queue.remove_at(i)
			continue
		if focus.distance_to(n.center) > collision_radius + n.bound:
			i += 1
			continue
		_body_queue.remove_at(i)
		var tb := Time.get_ticks_usec()
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = n.shape
		cs.disabled = not n.shown
		body.add_child(cs)
		body.position = n.mesh.position
		add_child(body)
		n.body = body
		n.shape = null
		_prof_body = maxf(_prof_body, (Time.get_ticks_usec() - tb) / 1000.0)
		count -= 1


func _upload(n: ChunkNode, res: Dictionary) -> void:
	var tm := Time.get_ticks_usec()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, res["arrays"], [], {},
		TerrainGenerator.mesh_format_flags())
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = res["origin"]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	mi.layers = render_layers
	add_child(mi)
	n.mesh = mi
	_prof_mesh = maxf(_prof_mesh, (Time.get_ticks_usec() - tm) / 1000.0)
	var mid := (float(res["min_h"]) + float(res["max_h"])) * 0.5
	var dir := n.center.normalized()
	n.center = dir * (config.radius + mid)
	n.half_range = (float(res["max_h"]) - float(res["min_h"])) * 0.5
	n.bound = n.horiz + n.half_range
	if res.has("shape"):
		n.shape = res["shape"]
		_body_queue.append(n)
	n.built = true
	chunk_built.emit(n.level)
