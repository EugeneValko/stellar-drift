extends Node
## Universe (autoload): celestial-body registry, gravity, atmosphere density, floating origin.
##
## CONTRACT (see docs/ARCHITECTURE.md "Контракт Universe"):
##  * All floating content (bodies, ship, player, effects) lives under `world_root` (a Node3D the
##    main scene registers with `set_world_root()`). Camera/HUD may live outside.
##  * Celestial bodies join group "celestial_body" and implement (duck-typed):
##      get_body_name() -> String
##      get_body_radius() -> float                 # mean surface radius, m
##      get_soi_radius() -> float                  # sphere of influence, m
##      get_surface_gravity() -> float             # m/s^2 at radius
##      get_atmosphere_height() -> float           # 0 if none
##      get_altitude_global(world_pos) -> float    # above terrain/ocean surface
##  * Floating origin: when the focus node is farther than `shift_threshold` from (0,0,0),
##    every child of world_root is translated by -focus_pos (in _physics_process) and
##    `origin_shifted(delta)` is emitted. Nodes caching world positions must subtract `delta`.
##  * `origin` keeps the accumulated offset in 64-bit floats (true position = local + origin).

signal origin_shifted(delta: Vector3)
signal bodies_changed

var world_root: Node3D
var focus: Node3D
var shift_threshold := 2000.0
## Accumulated origin offset (64-bit components; Vector3 would be float32).
var origin_x := 0.0
var origin_y := 0.0
var origin_z := 0.0

var _bodies: Array[Node3D] = []


func set_world_root(root: Node3D) -> void:
	world_root = root


func set_focus(node: Node3D) -> void:
	focus = node


func register_body(b: Node3D) -> void:
	if b in _bodies:
		return
	_bodies.append(b)
	if not b.is_in_group("celestial_body"):
		b.add_to_group("celestial_body")
	b.tree_exiting.connect(func() -> void: _bodies.erase(b); bodies_changed.emit(), CONNECT_ONE_SHOT)
	bodies_changed.emit()


func get_bodies() -> Array[Node3D]:
	for n in get_tree().get_nodes_in_group("celestial_body"):
		if n is Node3D and not (n in _bodies):
			register_body(n)
	return _bodies


## Body whose sphere of influence contains the point (smallest SOI wins); null if none.
func get_dominant_body(world_pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_soi := INF
	for b in get_bodies():
		var soi: float = b.get_soi_radius()
		if soi < best_soi and b.global_position.distance_to(world_pos) < soi:
			best = b
			best_soi = soi
	return best


## Nearest body by distance to its surface.
func get_nearest_body(world_pos: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for b in get_bodies():
		var d: float = b.global_position.distance_to(world_pos) - b.get_body_radius()
		if d < best_d:
			best = b
			best_d = d
	return best


## Gravity acceleration (m/s^2, world space) from the dominant body: g0 * (R/r)^2 toward centre.
func get_gravity(world_pos: Vector3) -> Vector3:
	var b := get_dominant_body(world_pos)
	if b == null:
		return Vector3.ZERO
	var to_c: Vector3 = b.global_position - world_pos
	var r := maxf(to_c.length(), 1.0)
	var R: float = b.get_body_radius()
	return to_c / r * b.get_surface_gravity() * pow(R / maxf(r, R * 0.5), 2.0)


## Local "up" (away from the dominant body centre); Vector3.UP if in deep space.
func get_up(world_pos: Vector3) -> Vector3:
	var b := get_dominant_body(world_pos)
	if b == null:
		return Vector3.UP
	return (world_pos - b.global_position).normalized()


## 0..1 relative air density (1 at the surface, exponential falloff, 0 above the atmosphere).
func get_atmosphere_density(world_pos: Vector3) -> float:
	var b := get_dominant_body(world_pos)
	if b == null:
		return 0.0
	var h: float = b.get_atmosphere_height()
	if h <= 0.0:
		return 0.0
	var alt: float = b.global_position.distance_to(world_pos) - b.get_body_radius()
	if alt >= h:
		return 0.0
	return exp(-maxf(alt, 0.0) / (h * 0.18))


func get_true_position(local_pos: Vector3) -> Array[float]:
	return [local_pos.x + origin_x, local_pos.y + origin_y, local_pos.z + origin_z]


## Local (scene) position of a true system-frame point given as 64-bit components.
## Precise near the origin even when the true coordinates are ~1e8 m.
func true_to_local(x: float, y: float, z: float) -> Vector3:
	return Vector3(x - origin_x, y - origin_y, z - origin_z)


## Moves the floating origin to the true point (x, y, z) (teleport / capture presets).
## Like shift_origin(): every child of world_root is moved by -delta, `origin_shifted` fires.
func teleport_origin(x: float, y: float, z: float) -> void:
	var delta := Vector3(x - origin_x, y - origin_y, z - origin_z)
	if world_root:
		for c in world_root.get_children():
			if c is Node3D:
				(c as Node3D).global_position -= delta
	origin_x = x
	origin_y = y
	origin_z = z
	origin_shifted.emit(delta)


func _physics_process(_dt: float) -> void:
	if world_root == null or focus == null or not is_instance_valid(focus):
		return
	var p := focus.global_position
	if p.length() < shift_threshold:
		return
	shift_origin(p)


## Moves every child of world_root by -delta so that `delta` becomes the new origin.
func shift_origin(delta: Vector3) -> void:
	for c in world_root.get_children():
		if c is Node3D:
			(c as Node3D).global_position -= delta
	origin_x += delta.x
	origin_y += delta.y
	origin_z += delta.z
	origin_shifted.emit(delta)
