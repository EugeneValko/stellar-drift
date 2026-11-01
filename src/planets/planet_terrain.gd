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

## Split when distance-to-chunk < chunk_edge * lod_factor.
@export var lod_factor := 1.0
## Chunks entirely below the horizon (occluder sphere through the ground under the focus,
## lowered by this margin) are not refined.
@export var horizon_margin := 250.0
## Target vertex spacing at the finest level (m).
@export var finest_quad := 0.4
## Max mesh uploads per frame and per-frame time budget for uploads (ms).
@export var max_uploads_per_frame := 6
@export var upload_budget_ms := 3.0
## Worker tasks in flight (0 = cores - 1).
@export var max_jobs := 0
## Collision for chunks whose level >= max_level - collision_levels + 1 and close to focus.
@export var collision_levels := 2
@export var collision_radius := 300.0
@export var cast_shadows := true
## When true the terrain follows the current viewport camera by itself.
@export var auto_focus_camera := false

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
	var parent: ChunkNode
	var children: Array[ChunkNode] = []
	var mesh: MeshInstance3D
	var body: StaticBody3D
	var built := false
	var pending := false
	var want_split := false
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


func get_stats() -> Dictionary:
	return {
		"nodes": _node_count, "visible": _visible_count, "queued": _queue.size(),
		"jobs": _jobs.size(), "built": _built_total, "max_level": max_level,
		"avg_build_ms": _build_ms_total / maxf(_built_total, 1),
		"max_build_ms": _build_ms_max,
	}


## True when no chunk is waiting to be built for the current focus.
func is_idle() -> bool:
	return _queue.is_empty() and _jobs.is_empty()


## Blocks until the LOD for the current focus is complete (capture / loading screens).
func build_until_stable(max_seconds := 120.0) -> void:
	var t0 := Time.get_ticks_msec()
	while true:
		_update_tree()
		_dispatch(true)
		_collect(1 << 30, 1e9, true)
		_update_tree()
		if is_idle():
			break
		if Time.get_ticks_msec() - t0 > max_seconds * 1000.0:
			push_warning("PlanetTerrain: build_until_stable timed out")
			break
	_update_tree()


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
	_collect(max_uploads_per_frame, upload_budget_ms)
	_update_tree()
	_dispatch(false)


func _update_tree() -> void:
	_visible_count = 0
	_focus_r = focus.length()
	if _focus_r > 1.0:
		var ground := config.radius + generator.sample(focus / _focus_r, 1e9).x
		if config.has_ocean_surface():
			ground = maxf(ground, config.get_ocean_radius())
		_occluder_r = minf(ground, _focus_r) - horizon_margin
	for r in _roots:
		_refine(r)
	for r in _roots:
		_display(r)


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
	n.bound = horiz + (hi - lo) * 0.5 + n.edge_m * 0.05
	_node_count += 1


func _should_split(n: ChunkNode) -> bool:
	if n.level >= max_level:
		return false
	var d := maxf(focus.distance_to(n.center) - n.bound, 0.0)
	var k := lod_factor * (1.1 if n.want_split else 1.0)  # hysteresis
	if d >= n.edge_m * k:
		return false
	return n.level < 3 or not _below_horizon(n)


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
		for c in n.children:
			_refine(c)
		if not _covered_by_children(n):
			_request(n)   # fallback while children build
	else:
		_request(n)
		if n.built and not n.children.is_empty():
			for c in n.children:
				_free_subtree(c, true)
			n.children.clear()


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
	var use_children := (n.want_split or not n.built) and _covered_by_children(n)
	if use_children:
		_set_shown(n, false)
		for c in n.children:
			_display(c)
	else:
		_set_shown(n, n.built)
		for c in n.children:
			_hide_subtree(c)


func _set_shown(n: ChunkNode, on: bool) -> void:
	if n.mesh:
		n.mesh.visible = on
		if on:
			_visible_count += 1
	if n.body:
		var shape := n.body.get_child(0) as CollisionShape3D
		shape.disabled = not on


func _hide_subtree(n: ChunkNode) -> void:
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
	var limit := max_jobs if max_jobs > 0 else maxi(OS.get_processor_count() - 1, 1)
	if all:
		limit = maxi(limit * 4, 16)
	if _jobs.size() >= limit:
		return
	_queue.sort_custom(func(a: ChunkNode, b: ChunkNode) -> bool: return _priority(a) < _priority(b))
	while not _queue.is_empty() and _jobs.size() < limit:
		var n: ChunkNode = _queue.pop_front()
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
		done += 1


func _upload(n: ChunkNode, res: Dictionary) -> void:
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
	add_child(mi)
	n.mesh = mi
	var mid := (float(res["min_h"]) + float(res["max_h"])) * 0.5
	var dir := n.center.normalized()
	n.center = dir * (config.radius + mid)
	n.bound = n.horiz + (float(res["max_h"]) - float(res["min_h"])) * 0.5
	if res.has("faces") and focus.distance_to(n.center) < collision_radius + n.bound:
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(res["faces"])
		shape.backface_collision = true
		var body := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		body.position = res["origin"]
		add_child(body)
		n.body = body
	n.built = true
	chunk_built.emit(n.level)
